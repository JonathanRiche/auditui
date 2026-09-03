import type { KeyEvent } from "@opentui/core";
import type { EngineClient } from "../engine/client";
import type { EngineSupervisor } from "../engine/process";
import {
  mergeCompletedDownloads,
  normalizeDownloads,
  normalizeLibrary,
  normalizePlayer,
} from "../engine/models";
import { RpcRequestError } from "../engine/protocol";
import type { AppState, DownloadJob, LibraryItem, PlayerState, Screen } from "./types";
import { libraryColumnCount } from "./state";
import { commandEntries, type CommandId } from "./commands";

export interface AppHost {
  getState(): AppState;
  dispatch(action: import("./types").Action): void;
  runInteractiveRefresh?(profile: string): Promise<boolean>;
  runInteractiveConnect?(provider: string): Promise<boolean>;
  quit(): void | Promise<void>;
}

export class AppController {
  private client: EngineClient | null = null;
  private accountRefresh: Promise<void> | null = null;
  private lastAccountRefreshAt = 0;
  private playerPoll: ReturnType<typeof setInterval> | null = null;
  private playerStatusInFlight = false;
  private downloadPoll: ReturnType<typeof setInterval> | null = null;
  private downloadStatusInFlight = false;

  constructor(
    private readonly host: AppHost,
    private readonly supervisor: EngineSupervisor,
  ) {}

  start(): void {
    this.supervisor.on("status", (status, message) =>
      this.host.dispatch({ type: "engine.status", status, message }),
    );
    this.supervisor.on("ready", (client) => {
      this.client = client;
      this.startPlayerPolling();
      this.startDownloadPolling();
      void this.initialize();
    });
    this.supervisor.on("event", (event, data) => this.onEngineEvent(String(event), data));
    this.supervisor.on("protocolError", () =>
      this.host.dispatch({ type: "message", message: "Ignored a malformed engine message" }),
    );
    this.supervisor.start();
  }

  async stop(): Promise<void> {
    if (this.playerPoll) clearInterval(this.playerPoll);
    this.playerPoll = null;
    if (this.downloadPoll) clearInterval(this.downloadPoll);
    this.downloadPoll = null;
    await this.supervisor.stop();
  }

  private startPlayerPolling(): void {
    if (this.playerPoll) return;
    this.playerPoll = setInterval(() => {
      if (!this.client || this.playerStatusInFlight || this.host.getState().player.itemId === null)
        return;
      this.playerStatusInFlight = true;
      void this.loadPlayer(false).finally(() => {
        this.playerStatusInFlight = false;
      });
    }, 500);
    this.playerPoll.unref?.();
  }

  private startDownloadPolling(): void {
    if (this.downloadPoll) return;
    this.downloadPoll = setInterval(() => {
      const state = this.host.getState();
      const unfinished = state.downloads.some(
        (job) => job.state === "queued" || job.state === "active",
      );
      if (
        !this.client ||
        this.downloadStatusInFlight ||
        (!unfinished && state.screen !== "downloads")
      )
        return;
      this.downloadStatusInFlight = true;
      void this.loadDownloads().finally(() => {
        this.downloadStatusInFlight = false;
      });
    }, 500);
    this.downloadPoll.unref?.();
  }

  private async initialize(): Promise<void> {
    // Paint the local cache immediately, then reconcile it with Audible. This
    // keeps startup fast while ensuring purchases made since the prior launch
    // appear without requiring the user to know about the refresh shortcut.
    await this.refresh();
    if (this.host.getState().profileName) await this.refreshAccountLibrary(false);
  }

  refreshAccountLibraryIfStale(maxAgeMs = 15_000): Promise<void> {
    if (Date.now() - this.lastAccountRefreshAt < maxAgeMs) return Promise.resolve();
    return this.refreshAccountLibrary(false);
  }

  seekTo(positionSeconds: number): void {
    const player = this.host.getState().player;
    if (player.itemId === null || player.durationSeconds <= 0 || !Number.isFinite(positionSeconds))
      return;
    const value = Math.max(0, Math.min(player.durationSeconds, positionSeconds));
    void this.playerCommand("seek-absolute", { value });
  }

  togglePlayback(): void {
    if (this.host.getState().player.itemId === null) return;
    void this.playerCommand("toggle");
  }

  openSearch(): void {
    if (this.host.getState().screen !== "library")
      this.host.dispatch({ type: "navigate", screen: "library" });
    this.host.dispatch({ type: "search.open" });
  }

  navigateTo(screen: Screen): void {
    if (this.host.getState().searchMode) this.host.dispatch({ type: "search.close" });
    this.host.dispatch({ type: "navigate", screen });
    if (screen === "downloads") void this.loadDownloads();
    if (screen === "now-playing") void this.loadPlayer();
    if (screen === "wishlist") void this.loadWishlist();
  }

  openItem(itemId: string): void {
    const state = this.host.getState();
    const index = state.visibleItems.findIndex((item) => item.id === itemId);
    if (index < 0) return;
    this.host.dispatch({ type: "move", amount: index - state.selectedIndex });
    this.host.dispatch({ type: "navigate", screen: "detail" });
  }

  activateItem(itemId: string): void {
    const state = this.host.getState();
    const item = state.visibleItems.find((candidate) => candidate.id === itemId);
    if (!item) return;
    if (item.localPath || item.streamable) {
      void this.playItem(item);
      return;
    }
    if (item.downloadable !== false) {
      void this.downloadItem(item);
      return;
    }
    this.host.dispatch({
      type: "message",
      message: `${item.title} is not currently available for playback or download`,
    });
  }

  selectDownload(jobId: string): void {
    const state = this.host.getState();
    const index = state.downloads.findIndex((job) => job.jobId === jobId);
    if (index >= 0) this.host.dispatch({ type: "move", amount: index - state.selectedIndex });
  }

  activateDownload(jobId: string): void {
    const job = this.host.getState().downloads.find((candidate) => candidate.jobId === jobId);
    if (!job) return;
    this.selectDownload(jobId);
    if (job.state === "queued" || job.state === "active") void this.cancelDownload(job);
    else if (job.state === "failed" || job.state === "cancelled") void this.retryDownload(job);
  }

  selectWishlist(itemId: string): void {
    const state = this.host.getState();
    const index = state.wishlist.findIndex((item) => item.id === itemId);
    if (index >= 0) this.host.dispatch({ type: "move", amount: index - state.selectedIndex });
  }

  removeWishlist(itemId: string): void {
    this.selectWishlist(itemId);
    const item = this.host.getState().wishlist.find((candidate) => candidate.id === itemId);
    const asin = item?.asin ?? item?.id;
    if (!item || !asin) return;
    this.host.dispatch({
      type: "confirmation.open",
      confirmation: { kind: "wishlist.remove", asin, title: item.title },
    });
  }

  selectProfile(name: string): void {
    const state = this.host.getState();
    const index = state.profiles.findIndex((profile) => profile.name === name);
    if (index >= 0) this.host.dispatch({ type: "move", amount: index - state.selectedIndex });
    const profile = state.profiles[index];
    if (profile) void this.applyProfile(profile);
  }

  requestProfileRemoval(): void {
    const state = this.host.getState();
    const profile =
      state.profiles.find((candidate) => candidate.name === state.profileName) ??
      state.profiles[state.selectedIndex];
    if (!profile) return;
    this.host.dispatch({
      type: "confirmation.open",
      confirmation: { kind: "profile.remove", profile: profile.name, title: profile.name },
    });
  }

  selectBookmark(bookmarkId: string): void {
    const state = this.host.getState();
    const index = state.player.bookmarks.findIndex((bookmark) => bookmark.id === bookmarkId);
    const bookmark = state.player.bookmarks[index];
    if (!bookmark) return;
    this.host.dispatch({ type: "move", amount: index - state.selectedIndex });
    void this.playerCommand("seek-absolute", { value: bookmark.positionSeconds });
  }

  selectChapter(index: number): void {
    if (!Number.isInteger(index) || index < 0) return;
    void this.playerCommand("chapter-set", { value: index });
  }

  playerMouseCommand(
    command: "toggle" | "seek-back" | "seek-forward" | "chapter-previous" | "chapter-next",
  ): void {
    if (command === "seek-back") void this.playerCommand("seek-relative", { value: -10 });
    else if (command === "seek-forward") void this.playerCommand("seek-relative", { value: 10 });
    else void this.playerCommand(command);
  }

  toggleHelp(): void {
    this.host.dispatch({ type: "help.toggle" });
  }

  refreshLibrary(): void {
    void this.refreshAccountLibrary(true);
  }

  beginOnboarding(): void {
    void this.startOnboarding("audible");
  }

  beginProviderOnboarding(provider: "audible" | "yoto"): void {
    void this.startOnboarding(provider);
  }

  backOrQuit(): void {
    const state = this.host.getState();
    if (state.screen === "detail")
      this.host.dispatch({ type: "navigate", screen: state.previousScreen });
    else if (state.screen !== "library")
      this.host.dispatch({ type: "navigate", screen: "library" });
    else void this.host.quit();
  }

  handleKey(key: KeyEvent): void {
    if (key.eventType === "release") return;
    const state = this.host.getState();
    if (key.ctrl && key.name.toLowerCase() === "p") {
      this.host.dispatch({ type: "command.toggle" });
      return;
    }
    if (state.confirmation) {
      if (key.name === "escape" || key.name.toLowerCase() === "n")
        this.host.dispatch({ type: "confirmation.close" });
      else if (key.name.toLowerCase() === "y" || key.name === "return") void this.confirmMutation();
      return;
    }
    if (state.commandPaletteVisible) {
      if (key.name === "escape") this.host.dispatch({ type: "command.toggle" });
      else if (key.name === "up" || key.name === "k")
        this.host.dispatch({ type: "command.move", amount: -1, count: commandEntries.length });
      else if (key.name === "down" || key.name === "j")
        this.host.dispatch({ type: "command.move", amount: 1, count: commandEntries.length });
      else if (key.name === "return") this.executeCommand(commandEntries[state.commandIndex]?.id);
      return;
    }
    if (state.authInputMode) {
      if (key.name === "escape") this.host.dispatch({ type: "auth.input.close" });
      else if (key.name === "return") void this.completeOnboarding();
      else if (key.name === "backspace")
        this.host.dispatch({ type: "auth.input.change", value: state.authInput.slice(0, -1) });
      else if (!key.ctrl && !key.meta && key.sequence && key.sequence >= " ")
        this.host.dispatch({ type: "auth.input.change", value: state.authInput + key.sequence });
      return;
    }
    if (state.wishlistInputMode) {
      if (key.name === "escape") this.host.dispatch({ type: "wishlist.input.close" });
      else if (key.name === "return") {
        const asin = state.wishlistInput.trim();
        if (/^[A-Za-z0-9]{10}$/.test(asin))
          this.host.dispatch({
            type: "confirmation.open",
            confirmation: { kind: "wishlist.add", asin, title: asin },
          });
        else
          this.host.dispatch({
            type: "message",
            message: "Enter a valid 10-character Audible ASIN",
          });
      } else if (key.name === "backspace")
        this.host.dispatch({
          type: "wishlist.input.change",
          value: state.wishlistInput.slice(0, -1),
        });
      else if (!key.ctrl && !key.meta && key.sequence && key.sequence >= " ")
        this.host.dispatch({
          type: "wishlist.input.change",
          value: state.wishlistInput + key.sequence,
        });
      return;
    }
    if (key.shift && (key.name.toLowerCase() === "h" || key.name.toLowerCase() === "l")) {
      this.cycleTopLevelScreen(key.name.toLowerCase() === "h" ? -1 : 1);
      return;
    }
    if (state.searchMode) {
      if (key.name === "escape") this.host.dispatch({ type: "search.change", query: "" });
      if (key.name === "return") void this.searchAccountLibrary(state.query);
      if (key.name === "escape" || key.name === "return")
        this.host.dispatch({ type: "search.close" });
      else if (key.name === "backspace")
        this.host.dispatch({ type: "search.change", query: state.query.slice(0, -1) });
      else if (!key.ctrl && !key.meta && key.sequence.length === 1 && key.sequence >= " ") {
        this.host.dispatch({ type: "search.change", query: state.query + key.sequence });
      }
      return;
    }
    if (key.name === "?" || key.sequence === "?")
      return void this.host.dispatch({ type: "help.toggle" });
    if (state.helpVisible) {
      if (key.name === "escape" || key.name === "q") this.host.dispatch({ type: "help.toggle" });
      return;
    }
    const name = key.name;
    if (name === "escape") {
      if (state.screen === "detail")
        this.host.dispatch({ type: "navigate", screen: state.previousScreen });
      else if (state.screen !== "library")
        this.host.dispatch({ type: "navigate", screen: "library" });
    } else if (name === "q") {
      if (state.screen === "detail")
        this.host.dispatch({ type: "navigate", screen: state.previousScreen });
      else void this.host.quit();
    } else if (name === "/" || key.sequence === "/") {
      this.openSearch();
    } else if (state.screen === "library" && (name === "up" || name === "k"))
      this.moveLibraryGrid(0, -1);
    else if (state.screen === "library" && (name === "down" || name === "j"))
      this.moveLibraryGrid(0, 1);
    else if (state.screen === "library" && (name === "left" || name === "h"))
      this.moveLibraryGrid(-1, 0);
    else if (state.screen === "library" && (name === "right" || name === "l"))
      this.moveLibraryGrid(1, 0);
    else if (
      (state.screen === "downloads" ||
        state.screen === "wishlist" ||
        state.screen === "settings") &&
      (name === "up" || name === "k")
    )
      this.host.dispatch({ type: "move", amount: -1 });
    else if (
      (state.screen === "downloads" ||
        state.screen === "wishlist" ||
        state.screen === "settings") &&
      (name === "down" || name === "j")
    )
      this.host.dispatch({ type: "move", amount: 1 });
    else if (state.screen === "now-playing" && (name === "up" || name === "k"))
      this.host.dispatch({ type: "move", amount: -1 });
    else if (state.screen === "now-playing" && (name === "down" || name === "j"))
      this.host.dispatch({ type: "move", amount: 1 });
    else if (name === "return") this.activate();
    else if (name === "d") void this.downloadSelected();
    else if (name === "c" && state.screen === "downloads") void this.cancelSelectedDownload();
    else if (name === "r" && state.screen === "downloads") void this.retrySelectedDownload();
    else if (name === "a" && state.screen === "wishlist")
      this.host.dispatch({ type: "wishlist.input.open" });
    else if ((name === "x" || name === "delete") && state.screen === "wishlist")
      this.requestWishlistRemoval();
    else if ((name === "x" || name === "delete") && state.screen === "settings")
      this.requestProfileRemoval();
    else if (name === "a" && state.screen === "library") void this.startOnboarding("audible");
    else if (name === "y" && state.screen === "library") void this.startOnboarding("yoto");
    else if (name === "b" && state.screen === "now-playing")
      void this.playerCommand("bookmark-add", {
        label: `Bookmark at ${Math.floor(state.player.positionSeconds)}s`,
      });
    else if ((name === "x" || name === "delete") && state.screen === "now-playing")
      void this.deleteSelectedBookmark();
    else if (name === "s" && state.screen === "now-playing") void this.cycleSleepTimer();
    else if ((name === "+" || name === "=") && state.screen === "now-playing")
      void this.playerCommand("set-volume", { value: Math.min(100, state.player.volume + 5) });
    else if (name === "-" && state.screen === "now-playing")
      void this.playerCommand("set-volume", { value: Math.max(0, state.player.volume - 5) });
    else if (name === "space") void this.playerCommand("toggle");
    else if (
      (state.screen === "detail" || state.screen === "now-playing") &&
      (name === "h" || name === "left")
    )
      void this.playerCommand("seek-relative", { value: -10 });
    else if (
      (state.screen === "detail" || state.screen === "now-playing") &&
      (name === "l" || name === "right")
    )
      void this.playerCommand("seek-relative", { value: 10 });
    else if (name === "[") void this.playerCommand("chapter-previous");
    else if (name === "]") void this.playerCommand("chapter-next");
    else if (name === ",")
      void this.playerCommand("set-speed", { value: Math.max(0.5, state.player.speed - 0.05) });
    else if (name === ".")
      void this.playerCommand("set-speed", { value: Math.min(3, state.player.speed + 0.05) });
    else if (name === "r") void this.refreshAccountLibrary(true);
    else if (name === "1") this.navigateTo("library");
    else if (name === "2") this.navigateTo("wishlist");
    else if (name === "3") this.navigateTo("downloads");
    else if (name === "4") this.navigateTo("now-playing");
    else if (name === "5") this.navigateTo("settings");
  }

  private moveLibraryGrid(horizontal: -1 | 0 | 1, vertical: -1 | 0 | 1): void {
    const state = this.host.getState();
    const count = state.visibleItems.length;
    if (!count) return;
    const columns = libraryColumnCount(state.width);
    const current = state.selectedIndex;
    let target = current;
    if (horizontal < 0 && current % columns > 0) target = current - 1;
    else if (horizontal > 0 && current % columns < columns - 1 && current + 1 < count)
      target = current + 1;
    else if (vertical < 0 && current >= columns) target = current - columns;
    else if (vertical > 0 && current + columns < count) target = current + columns;
    else if (vertical > 0 && Math.floor(current / columns) < Math.floor((count - 1) / columns))
      target = count - 1;
    if (target !== current) this.host.dispatch({ type: "move", amount: target - current });
  }

  private cycleTopLevelScreen(direction: -1 | 1): void {
    const state = this.host.getState();
    const destinations = [
      "library",
      "wishlist",
      "downloads",
      "now-playing",
      "settings",
      "search",
    ] as const;
    const current = state.searchMode
      ? "search"
      : state.screen === "detail"
        ? "library"
        : state.screen;
    const index = Math.max(0, destinations.indexOf(current));
    const next = destinations[(index + direction + destinations.length) % destinations.length]!;
    if (next === "search") this.openSearch();
    else this.navigateTo(next);
  }

  private executeCommand(id: CommandId | undefined): void {
    if (!id) return;
    this.host.dispatch({ type: "command.toggle" });
    const entry = commandEntries.find((value) => value.id === id);
    if (entry?.screen) this.navigateTo(entry.screen);
    else if (id === "search") this.openSearch();
    else if (id === "refresh") this.refreshLibrary();
    else if (id === "help") this.toggleHelp();
  }

  private activate(): void {
    const state = this.host.getState();
    if (state.screen === "library") this.host.dispatch({ type: "navigate", screen: "detail" });
    else if (state.screen === "detail") {
      const item = state.visibleItems[state.selectedIndex];
      if (!item) return;
      if (!item.localPath && !item.streamable) {
        this.host.dispatch({ type: "message", message: "Download this title before playing it" });
        return;
      }
      void this.playItem(item);
    } else if (state.screen === "settings") {
      const profile = state.profiles[state.selectedIndex];
      if (!profile) return;
      void this.applyProfile(profile);
    } else if (state.screen === "now-playing") {
      const bookmark = state.player.bookmarks[state.selectedIndex];
      if (bookmark) void this.playerCommand("seek-absolute", { value: bookmark.positionSeconds });
    }
  }

  private async refresh(): Promise<void> {
    const client = this.client;
    if (!client) return;
    this.host.dispatch({ type: "library.loading" });
    try {
      await client.request("health", {}, { timeoutMs: 5_000 });
      const profiles = await client.request<unknown>("profile.list");
      const profileItems =
        profiles &&
        typeof profiles === "object" &&
        Array.isArray((profiles as { items?: unknown }).items)
          ? (profiles as { items: unknown[] }).items
          : [];
      const savedProfile =
        profiles &&
        typeof profiles === "object" &&
        typeof (profiles as { selectedProfile?: unknown }).selectedProfile === "string"
          ? (profiles as { selectedProfile: string }).selectedProfile
          : null;
      const preferredProfile = savedProfile ?? this.host.getState().profileName;
      const profile = (profileItems.find(
        (value) =>
          preferredProfile &&
          value &&
          typeof value === "object" &&
          (value as { name?: unknown }).name === preferredProfile,
      ) ??
        profileItems.find(
          (value) =>
            value && typeof value === "object" && (value as { name?: unknown }).name === "default",
        ) ??
        profileItems.find((value) => value && typeof value === "object")) as
        | {
            name?: unknown;
            securePermissions?: unknown;
            provider?: unknown;
            account?: unknown;
          }
        | undefined;
      this.host.dispatch({
        type: "profiles.loaded",
        profiles: profileItems.flatMap((value) => {
          if (
            !value ||
            typeof value !== "object" ||
            typeof (value as { name?: unknown }).name !== "string"
          )
            return [];
          return [
            {
              name: (value as { name: string }).name,
              secure: (value as { securePermissions?: unknown }).securePermissions !== false,
              ...(typeof (value as { provider?: unknown }).provider === "string"
                ? { provider: (value as { provider: string }).provider }
                : {}),
              ...(typeof (value as { account?: unknown }).account === "string"
                ? { account: (value as { account: string }).account }
                : {}),
            },
          ];
        }),
      });
      this.host.dispatch({
        type: "profile.loaded",
        name: typeof profile?.name === "string" ? profile.name : null,
        secure: profile?.securePermissions !== false,
        ...(typeof profile?.provider === "string" ? { provider: profile.provider } : {}),
        ...(typeof profile?.account === "string" ? { account: profile.account } : {}),
      });
      const result = await client.request<unknown>("library.list", this.accountParams());
      const items = normalizeLibrary(result);
      this.host.dispatch({ type: "library.loaded", items });
      await Promise.allSettled([this.loadDownloads(), this.loadPlayer()]);
    } catch (error) {
      this.host.dispatch({ type: "library.failed", message: friendlyError(error) });
    }
  }

  private async applyProfile(profile: AppState["profiles"][number]): Promise<void> {
    const client = this.client;
    if (!client) return;
    const { name, secure, provider, account } = profile;
    try {
      await client.request("profile.select", {
        profile: name,
        ...(provider ? { provider } : {}),
        ...(account ? { account } : {}),
      });
      // Make the chosen account identity active before refresh so the very
      // first provider request cannot accidentally target the old account.
      this.host.dispatch({
        type: "profile.loaded",
        name,
        secure,
        ...(provider ? { provider } : {}),
        ...(account ? { account } : {}),
      });
      await this.refreshAccountLibrary(true);
      // The refresh reloads profile metadata. Reassert the user's explicit
      // selection last so a stale/malformed profile.list response cannot make
      // the Settings screen appear to ignore a successful selection.
      this.host.dispatch({
        type: "profile.loaded",
        name,
        secure,
        ...(provider ? { provider } : {}),
        ...(account ? { account } : {}),
      });
      const selectedIndex = this.host
        .getState()
        .profiles.findIndex((profile) => profile.name === name);
      if (selectedIndex >= 0)
        this.host.dispatch({
          type: "move",
          amount: selectedIndex - this.host.getState().selectedIndex,
        });
      this.host.dispatch({ type: "message", message: `Using profile ${name}` });
    } catch (error) {
      this.host.dispatch({ type: "message", message: friendlyError(error) });
    }
  }

  refreshAccountLibrary(manual = true): Promise<void> {
    if (this.accountRefresh) return this.accountRefresh;
    this.accountRefresh = this.performAccountRefresh(manual).finally(() => {
      this.accountRefresh = null;
    });
    return this.accountRefresh;
  }

  private async performAccountRefresh(manual: boolean): Promise<void> {
    const client = this.client;
    const state = this.host.getState();
    const profile = state.profileName;
    const providerLabel = state.activeProvider === "yoto" ? "Yoto" : "Audible";
    if (!client || !profile) {
      this.host.dispatch({
        type: "message",
        message: "Connect an Audible or Yoto account first from Settings",
      });
      return;
    }
    this.host.dispatch({ type: "library.loading" });
    try {
      const result = await client.request<unknown>("library.refresh", this.accountParams(), {
        timeoutMs: 120_000,
      });
      const count =
        result &&
        typeof result === "object" &&
        typeof (result as { itemCount?: unknown }).itemCount === "number"
          ? (result as { itemCount: number }).itemCount
          : null;
      await this.refresh();
      this.lastAccountRefreshAt = Date.now();
      this.host.dispatch({
        type: "message",
        message:
          count === null
            ? `${providerLabel} library refreshed`
            : `Refreshed ${count} ${providerLabel} titles`,
      });
    } catch (error) {
      if (
        manual &&
        error instanceof RpcRequestError &&
        error.code === "PASSWORD_REQUIRED" &&
        this.host.runInteractiveRefresh
      ) {
        this.host.dispatch({
          type: "message",
          message: "Secure prompt active — enter the profile passphrase in this terminal",
        });
        const refreshed = await this.host.runInteractiveRefresh(profile);
        if (refreshed) {
          await this.refresh();
          this.lastAccountRefreshAt = Date.now();
          this.host.dispatch({ type: "message", message: `${providerLabel} library refreshed` });
        } else {
          this.host.dispatch({
            type: "library.failed",
            message:
              "Secure profile unlock was cancelled or failed; the cached library is unchanged",
          });
        }
        return;
      }
      const message =
        error instanceof RpcRequestError && error.code === "PASSWORD_REQUIRED"
          ? "This encrypted profile needs a secure interactive unlock; press r to try again"
          : friendlyError(error);
      // Automatic reconciliation must never hide a usable cached library just
      // because an encrypted profile needs interactive unlocking.
      if (manual || !(error instanceof RpcRequestError && error.code === "PASSWORD_REQUIRED")) {
        this.host.dispatch({ type: "library.failed", message });
      }
    }
  }

  private async loadDownloads(): Promise<void> {
    if (!this.client) return;
    try {
      const result = await this.client.request<unknown>("downloads.list");
      const state = this.host.getState();
      this.host.dispatch({
        type: "download.list",
        jobs: mergeCompletedDownloads(normalizeDownloads(result), state.library),
      });
    } catch (error) {
      this.host.dispatch({ type: "message", message: friendlyError(error) });
    }
  }

  private async loadWishlist(): Promise<void> {
    if (!this.client) return;
    try {
      const result = await this.client.request<unknown>(
        "wishlist.list",
        this.host.getState().profileName ? { profile: this.host.getState().profileName } : {},
      );
      this.host.dispatch({ type: "wishlist.loaded", items: normalizeLibrary(result) });
    } catch (error) {
      this.host.dispatch({ type: "message", message: friendlyError(error) });
    }
  }

  private async loadPlayer(reportErrors = true): Promise<void> {
    if (!this.client) return;
    try {
      const result = await this.client.request<unknown>("player.status");
      this.host.dispatch({ type: "player.status", player: normalizePlayer(result) });
    } catch (error) {
      if (reportErrors) this.host.dispatch({ type: "message", message: friendlyError(error) });
    }
  }

  private async downloadSelected(): Promise<void> {
    const item = this.host.getState().visibleItems[this.host.getState().selectedIndex];
    if (!item) return;
    await this.downloadItem(item);
  }

  private async downloadItem(item: LibraryItem): Promise<void> {
    if (!this.client) return;
    if (item.downloadable === false) {
      this.host.dispatch({
        type: "message",
        message: `${item.title} is stream-only and does not support offline downloads`,
      });
      return;
    }
    if (item.downloaded && item.localPath) {
      this.host.dispatch({ type: "message", message: `${item.title} is already downloaded` });
      return;
    }
    try {
      await this.client.request("downloads.start", {
        asin: item.asin ?? item.id,
        itemId: item.id,
        ...this.accountParams(item),
      });
      this.host.dispatch({ type: "message", message: `Queued ${item.title}` });
      await this.loadDownloads();
    } catch (error) {
      this.host.dispatch({ type: "message", message: friendlyError(error) });
    }
  }

  private async playItem(item: LibraryItem): Promise<void> {
    if (!item.localPath && !item.streamable) return;
    await this.playerCommand("play", {
      ...(item.localPath ? { path: item.localPath } : {}),
      itemId: item.id,
      title: item.title,
      ...this.accountParams(item),
    });
  }

  private accountParams(item?: LibraryItem): Record<string, unknown> {
    const state = this.host.getState();
    const provider = (item?.provider ?? state.activeProvider).toLowerCase();
    const account = item?.account ?? state.activeAccount;
    return {
      provider,
      ...(account ? { account } : {}),
      ...(provider === "audible" && state.profileName ? { profile: state.profileName } : {}),
    };
  }

  private async searchAccountLibrary(query: string): Promise<void> {
    if (!this.client || !query.trim()) return;
    try {
      const result = await this.client.request<unknown>("library.search", {
        query: query.trim(),
        ...this.accountParams(),
      });
      this.host.dispatch({ type: "search.results", items: normalizeLibrary(result) });
    } catch (error) {
      this.host.dispatch({ type: "message", message: friendlyError(error) });
    }
  }

  private async cancelSelectedDownload(): Promise<void> {
    const state = this.host.getState();
    const job = state.downloads[state.selectedIndex];
    if (!job) return;
    await this.cancelDownload(job);
  }

  private async cancelDownload(job: DownloadJob): Promise<void> {
    if (!this.client) return;
    try {
      await this.client.request("downloads.cancel", { jobId: job.jobId });
      await this.loadDownloads();
    } catch (error) {
      this.host.dispatch({ type: "message", message: friendlyError(error) });
    }
  }

  private async retrySelectedDownload(): Promise<void> {
    const state = this.host.getState();
    const job = state.downloads[state.selectedIndex];
    if (!job || (job.state !== "failed" && job.state !== "cancelled")) {
      this.host.dispatch({
        type: "message",
        message: "Select a failed or cancelled download to retry",
      });
      return;
    }
    await this.retryDownload(job);
  }

  private async retryDownload(job: DownloadJob): Promise<void> {
    const state = this.host.getState();
    const item = state.library.find(
      (candidate) => candidate.id === job.itemId || candidate.asin === job.itemId,
    );
    if (!item) {
      this.host.dispatch({
        type: "message",
        message: "This title is no longer in the local library cache",
      });
      return;
    }
    await this.downloadItem(item);
  }

  private requestWishlistRemoval(): void {
    const state = this.host.getState();
    const item = state.wishlist[state.selectedIndex];
    const asin = item?.asin ?? item?.id;
    if (!item || !asin) return;
    this.host.dispatch({
      type: "confirmation.open",
      confirmation: { kind: "wishlist.remove", asin, title: item.title },
    });
  }

  private async confirmMutation(): Promise<void> {
    const confirmation = this.host.getState().confirmation;
    if (!confirmation || !this.client) return;
    this.host.dispatch({ type: "confirmation.close" });
    if (confirmation.kind === "profile.remove") {
      try {
        await this.client.request("profile.remove", {
          profile: confirmation.profile,
          confirm: true,
        });
        await this.refresh();
        this.host.dispatch({
          type: "message",
          message: `Removed local account ${confirmation.profile}; the provider account itself was not changed`,
        });
      } catch (error) {
        this.host.dispatch({ type: "message", message: friendlyError(error) });
      }
      return;
    }
    try {
      await this.client.request(confirmation.kind, {
        asin: confirmation.asin,
        ...(this.host.getState().profileName ? { profile: this.host.getState().profileName } : {}),
      });
      this.host.dispatch({
        type: "message",
        message:
          confirmation.kind === "wishlist.add"
            ? `Added ${confirmation.title} to your wishlist`
            : `Removed ${confirmation.title} from your wishlist`,
      });
      await this.loadWishlist();
    } catch (error) {
      this.host.dispatch({ type: "message", message: friendlyError(error) });
    }
  }

  private async startOnboarding(provider: "audible" | "yoto"): Promise<void> {
    if (!this.host.runInteractiveConnect) {
      this.host.dispatch({
        type: "message",
        message: "Secure account setup is unavailable in this terminal session",
      });
      return;
    }
    this.host.dispatch({
      type: "message",
      message: `Secure ${provider === "yoto" ? "Yoto" : "Audible"} account setup active in this terminal`,
    });
    const connected = await this.host.runInteractiveConnect(provider);
    if (!connected) {
      this.host.dispatch({
        type: "message",
        message: `${provider === "yoto" ? "Yoto" : "Audible"} account setup was cancelled or failed`,
      });
      return;
    }
    await this.refresh();
    const connectedProfile = this.host
      .getState()
      .profiles.find((profile) => (profile.provider ?? "audible") === provider);
    if (connectedProfile) await this.applyProfile(connectedProfile);
    this.host.dispatch({
      type: "message",
      message: `${provider === "yoto" ? "Yoto" : "Audible"} account connected securely`,
    });
  }

  private async completeOnboarding(): Promise<void> {
    const callbackUrl = this.host.getState().authInput.trim();
    if (!this.client || !callbackUrl) return;
    try {
      await this.client.request("auth.complete", { callbackUrl });
      this.host.dispatch({ type: "auth.input.close" });
      this.host.dispatch({ type: "message", message: "Account connected securely" });
      await this.refresh();
      await this.refreshAccountLibrary(true);
    } catch (error) {
      this.host.dispatch({ type: "auth.input.close" });
      const message =
        error instanceof RpcRequestError && error.code === "INTERACTIVE_REQUIRED"
          ? "Encrypted profiles require the secure terminal prompt: mise run account:connect"
          : friendlyError(error);
      this.host.dispatch({ type: "message", message });
    }
  }

  private async deleteSelectedBookmark(): Promise<void> {
    const state = this.host.getState();
    const bookmark = state.player.bookmarks[state.selectedIndex];
    if (!bookmark) {
      this.host.dispatch({ type: "message", message: "No bookmark selected" });
      return;
    }
    const bookmarkId = Number(bookmark.id);
    if (!Number.isInteger(bookmarkId) || bookmarkId <= 0) {
      this.host.dispatch({ type: "message", message: "This bookmark cannot be removed" });
      return;
    }
    await this.playerCommand("bookmark-delete", { bookmarkId });
  }

  private async cycleSleepTimer(): Promise<void> {
    const player = this.host.getState().player;
    if (player.sleepTimerMode === null)
      await this.playerCommand("set-sleep-timer", { value: 15 * 60 });
    else if (player.sleepTimerMode === "duration" && (player.sleepTimerSeconds ?? 0) <= 15 * 60)
      await this.playerCommand("set-sleep-timer", { value: 30 * 60 });
    else if (player.sleepTimerMode === "duration" && (player.sleepTimerSeconds ?? 0) <= 30 * 60)
      await this.playerCommand("set-sleep-timer", { value: 60 * 60 });
    else if (player.sleepTimerMode === "duration") await this.playerCommand("sleep-end-chapter");
    else await this.playerCommand("cancel-sleep-timer");
  }

  private async playerCommand(
    command: string,
    params: Record<string, unknown> = {},
  ): Promise<void> {
    if (!this.client) return;
    try {
      const result = await this.client.request<unknown>("player.command", { command, ...params });
      if (result && typeof result === "object")
        this.host.dispatch({ type: "player.status", player: normalizePlayer(result) });
    } catch (error) {
      this.host.dispatch({ type: "message", message: friendlyError(error) });
    }
  }

  private onEngineEvent(event: string, data: unknown): void {
    if (event === "download.progress" && data && typeof data === "object") {
      this.host.dispatch({
        type: "download.progress",
        job: data as Partial<DownloadJob> & Pick<DownloadJob, "jobId">,
      });
    } else if (event === "download.state" && data && typeof data === "object") {
      this.host.dispatch({
        type: "download.progress",
        job: data as Partial<DownloadJob> & Pick<DownloadJob, "jobId">,
      });
    } else if (event.startsWith("player.") && data && typeof data === "object") {
      this.host.dispatch({ type: "player.status", player: normalizePlayer(data) });
    } else if (event === "library.changed") {
      void this.refresh();
    }
  }
}

function friendlyError(error: unknown): string {
  return error instanceof Error ? error.message : "The engine could not complete the request";
}
