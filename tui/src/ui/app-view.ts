import {
  BoxRenderable,
  ImageRenderable,
  ScrollBoxRenderable,
  TextRenderable,
  bold,
  dim,
  fg,
  t,
} from "@opentui/core";
import type { ImageRenderProtocol, RenderContext, StyledText } from "@opentui/core";
import type { AppState, DownloadJob, LibraryItem, Screen } from "../app/types";
import { libraryColumnCount } from "../app/state";
import { commandEntries } from "../app/commands";
import { selectedCoverSource, trustedCoverSource } from "../screens/cover";
import { formatTime } from "../screens/layout";
import { palette } from "../theme/palette";
import { concat, panel, progress, sectionTitle, statusCopy, text } from "./components";

const truncate = (value: string, width: number): string =>
  value.length <= width
    ? value
    : width <= 1
      ? value.slice(0, width)
      : `${value.slice(0, width - 1)}…`;

const listeningPercent = (item: LibraryItem): number =>
  item.durationSeconds > 0
    ? Math.max(0, Math.min(100, Math.round((item.positionSeconds / item.durationSeconds) * 100)))
    : 0;

const listeningState = (item: LibraryItem): string => {
  const percent = listeningPercent(item);
  if (percent >= 100) return "Finished";
  if (percent === 0) return "Not started";
  return `${percent}% listened`;
};

const providerLabel = (provider?: string): string =>
  provider?.toLowerCase() === "yoto" ? "YOTO" : provider?.toUpperCase() || "AUDIBLE";

const itemDownload = (state: AppState, item: LibraryItem): DownloadJob | undefined =>
  state.downloads.find((job) => job.itemId === item.id || job.itemId === item.asin);

const downloadPercent = (job: DownloadJob): number =>
  job.total ? Math.max(0, Math.min(100, Math.round((job.received / job.total) * 100))) : 0;

const libraryCoverHeight = (cardWidth: number): number =>
  Math.max(7, Math.min(12, Math.floor((cardWidth - 4) / 2)));
const libraryCardHeight = (cardWidth: number): number => libraryCoverHeight(cardWidth) + 9;

const plainDescription = (value?: string): string => {
  if (!value) return "No description available.";
  return (
    value
      .replace(/<br\s*\/?\s*>/gi, "\n")
      .replace(/<\/(p|div|li|h[1-6])\s*>/gi, "\n")
      .replace(/<[^>]+>/g, "")
      .replace(/&nbsp;/gi, " ")
      .replace(/&amp;/gi, "&")
      .replace(/&quot;/gi, '"')
      .replace(/&#(?:39|x27);/gi, "'")
      .replace(/&lt;/gi, "<")
      .replace(/&gt;/gi, ">")
      .replace(/[ \t]+/g, " ")
      .replace(/\s*\n\s*/g, "\n")
      .trim() || "No description available."
  );
};

export interface AppViewOptions {
  imageProtocol: ImageRenderProtocol;
  onResize(width: number, height: number): void;
  onSeek(positionSeconds: number): void;
  onTogglePlayback(): void;
  onNavigate(screen: Screen): void;
  onOpenSearch(): void;
  onOpenItem?(itemId: string): void;
  onActivateItem?(itemId: string): void;
  onSelectDownload?(jobId: string): void;
  onDownloadAction?(jobId: string): void;
  onSelectWishlist?(itemId: string): void;
  onRemoveWishlist?(itemId: string): void;
  onSelectProfile?(name: string): void;
  onRemoveProfile?(): void;
  onSelectBookmark?(bookmarkId: string): void;
  onSelectChapter?(index: number): void;
  onPlayerCommand?(
    command: "toggle" | "seek-back" | "seek-forward" | "chapter-previous" | "chapter-next",
  ): void;
  onRefresh?(): void;
  onToggleHelp?(): void;
  onBack?(): void;
}

/** A retained OpenTUI view. State remains owned by the reducer/controller. */
export class AppView {
  readonly root: BoxRenderable;
  private readonly header: BoxRenderable;
  private readonly nav: BoxRenderable;
  private readonly navBrand: TextRenderable;
  private readonly navLibrary: TextRenderable;
  private readonly navWishlist: TextRenderable;
  private readonly navDownloads: TextRenderable;
  private readonly navNowPlaying: TextRenderable;
  private readonly navSettings: TextRenderable;
  private readonly navSearch: TextRenderable;
  private readonly engineStatus: TextRenderable;
  private readonly body: ScrollBoxRenderable;
  private readonly dock: BoxRenderable;
  private readonly dockTitle: TextRenderable;
  private readonly dockProgress: TextRenderable;
  private readonly dockHelp: TextRenderable;
  private readonly helpModal: BoxRenderable;
  private readonly helpText: TextRenderable;
  private readonly commandModal: BoxRenderable;
  private readonly commandText: TextRenderable;
  private readonly confirmationModal: BoxRenderable;
  private readonly confirmationText: TextRenderable;
  private bodyKey = "";
  // Live lines of the now-playing screen, updated in place every tick so the
  // controls keep their hover state and never miss a click mid-rebuild.
  private nowPlayingProgress: TextRenderable | null = null;
  private nowPlayingSettings: TextRenderable | null = null;
  private dockBarStart = 0;
  private dockBarWidth = 0;
  private playerDuration = 0;
  private hasActivePlayer = false;
  private lastDragSeekAt = 0;
  private pendingSelectionScroll: ReturnType<typeof setTimeout> | null = null;

  constructor(
    private readonly ctx: RenderContext,
    private readonly options: AppViewOptions,
  ) {
    this.root = new BoxRenderable(ctx, {
      id: "audible-app",
      width: "100%",
      height: "100%",
      flexDirection: "column",
      backgroundColor: palette.background,
      shouldFill: true,
      onSizeChange: () => options.onResize(this.root.width, this.root.height),
    });

    this.header = panel(ctx, "app-header");
    this.header.height = 3;
    this.header.flexDirection = "row";
    this.header.alignItems = "center";
    this.header.paddingX = 2;
    this.header.border = ["bottom"];
    this.header.borderColor = palette.border;
    this.nav = new BoxRenderable(ctx, {
      id: "app-navigation",
      flexGrow: 1,
      height: 1,
      flexDirection: "row",
      backgroundColor: palette.surface,
    });
    this.navBrand = text(ctx, "nav-brand", "", { width: 11, bg: palette.surface });
    this.navLibrary = this.navTarget("nav-library", 12, () => options.onNavigate("library"));
    this.navWishlist = this.navTarget("nav-wishlist", 12, () => options.onNavigate("wishlist"));
    this.navDownloads = this.navTarget("nav-downloads", 13, () => options.onNavigate("downloads"));
    this.navNowPlaying = this.navTarget("nav-now-playing", 15, () =>
      options.onNavigate("now-playing"),
    );
    this.navSettings = this.navTarget("nav-settings", 11, () => options.onNavigate("settings"));
    this.navSearch = this.navTarget("nav-search", 12, options.onOpenSearch);
    this.nav.add(this.navBrand);
    this.nav.add(this.navLibrary);
    this.nav.add(this.navWishlist);
    this.nav.add(this.navDownloads);
    this.nav.add(this.navNowPlaying);
    this.nav.add(this.navSettings);
    this.nav.add(this.navSearch);
    this.engineStatus = text(ctx, "engine-status", "", { width: 18, bg: palette.surface });
    this.header.add(this.nav);
    this.header.add(this.engineStatus);

    this.body = new ScrollBoxRenderable(ctx, {
      id: "app-content",
      width: "100%",
      flexGrow: 1,
      scrollY: true,
      scrollX: false,
      viewportCulling: true,
      backgroundColor: palette.background,
      shouldFill: true,
      paddingX: 2,
      paddingY: 1,
      contentOptions: { flexDirection: "column", gap: 1, backgroundColor: palette.background },
      viewportOptions: { backgroundColor: palette.background },
      wrapperOptions: { backgroundColor: palette.background },
      verticalScrollbarOptions: { trackOptions: { backgroundColor: palette.background } },
    });

    this.dock = panel(ctx, "player-dock");
    this.dock.height = 5;
    this.dock.paddingX = 2;
    this.dock.paddingTop = 1;
    this.dock.border = ["top"];
    this.dock.borderColor = palette.border;
    this.dockTitle = text(ctx, "dock-title", "", {
      width: "100%",
      bg: palette.surface,
      onMouseDown: (event) => this.toggleFromMouse(event.x, event),
      onMouseOver: () => ctx.setMousePointer("pointer"),
      onMouseOut: () => ctx.setMousePointer("default"),
    });
    this.dockProgress = text(ctx, "dock-progress", "", {
      width: "100%",
      bg: palette.surface,
      onMouseDown: (event) => this.seekFromMouse(event.x, true, event),
      onMouseDrag: (event) => this.seekFromMouse(event.x, false, event),
      onMouseDragEnd: (event) => this.seekFromMouse(event.x, true, event),
      onMouseOver: () => ctx.setMousePointer("crosshair"),
      onMouseOut: () => ctx.setMousePointer("default"),
    });
    this.dockHelp = text(ctx, "dock-help", "", {
      width: "100%",
      bg: palette.surface,
      onMouseDown: (event) => this.dockHelpFromMouse(event.x, event),
      onMouseOver: () => ctx.setMousePointer("pointer"),
      onMouseOut: () => ctx.setMousePointer("default"),
    });
    this.dock.add(this.dockTitle);
    this.dock.add(this.dockProgress);
    this.dock.add(this.dockHelp);

    this.helpModal = new BoxRenderable(ctx, {
      id: "help-modal",
      position: "absolute",
      zIndex: 50,
      border: true,
      borderStyle: "rounded",
      borderColor: palette.accent,
      backgroundColor: palette.surfaceRaised,
      shouldFill: true,
      padding: 1,
      visible: false,
      onMouseDown: (event) => {
        if (event.button !== 0) return;
        event.preventDefault();
        event.stopPropagation();
        this.options.onToggleHelp?.();
      },
      onMouseOver: () => ctx.setMousePointer("pointer"),
      onMouseOut: () => ctx.setMousePointer("default"),
    });
    this.helpText = text(ctx, "help-copy", "", {
      width: "100%",
      height: "100%",
      bg: palette.surfaceRaised,
      wrapMode: "word",
    });
    this.helpModal.add(this.helpText);

    this.commandModal = new BoxRenderable(ctx, {
      id: "command-palette",
      position: "absolute",
      zIndex: 60,
      width: 52,
      height: commandEntries.length + 4,
      border: true,
      borderStyle: "rounded",
      borderColor: palette.accent,
      backgroundColor: palette.surfaceRaised,
      shouldFill: true,
      padding: 1,
      visible: false,
    });
    this.commandText = text(ctx, "command-palette-copy", "", {
      width: "100%",
      height: "100%",
      bg: palette.surfaceRaised,
    });
    this.commandModal.add(this.commandText);

    this.confirmationModal = new BoxRenderable(ctx, {
      id: "confirmation-modal",
      position: "absolute",
      zIndex: 70,
      width: 58,
      height: 7,
      border: true,
      borderStyle: "rounded",
      borderColor: palette.danger,
      backgroundColor: palette.surfaceRaised,
      shouldFill: true,
      padding: 1,
      visible: false,
    });
    this.confirmationText = text(ctx, "confirmation-copy", "", {
      width: "100%",
      height: "100%",
      bg: palette.surfaceRaised,
      wrapMode: "word",
    });
    this.confirmationModal.add(this.confirmationText);

    this.root.add(this.header);
    this.root.add(this.body);
    this.root.add(this.dock);
    this.root.add(this.helpModal);
    this.root.add(this.commandModal);
    this.root.add(this.confirmationModal);
  }

  render(state: AppState): void {
    this.renderHeader(state);
    this.renderDock(state);
    this.renderHelp(state);
    this.renderCommandPalette(state);
    this.renderConfirmation(state);
    const nextBodyKey = this.getBodyKey(state);
    if (nextBodyKey !== this.bodyKey) {
      this.bodyKey = nextBodyKey;
      this.clearBody();
      this.renderBody(state);
      this.scheduleSelectionScroll(state);
    } else if (state.screen === "now-playing") {
      this.updateNowPlayingLive(state);
    }
    this.ctx.requestRender();
  }

  private scheduleSelectionScroll(state: AppState): void {
    if (this.pendingSelectionScroll) clearTimeout(this.pendingSelectionScroll);
    this.pendingSelectionScroll = null;
    const target = (() => {
      if (state.screen === "library") {
        const selected = state.visibleItems[state.selectedIndex];
        if (!selected) return null;
        const continuing =
          selected.positionSeconds > 0 && selected.positionSeconds < selected.durationSeconds;
        return continuing ? `book-continue-${selected.id}` : `book-${selected.id}`;
      }
      if (state.screen === "downloads")
        return state.downloads[state.selectedIndex]
          ? `download-${state.downloads[state.selectedIndex]!.jobId}`
          : null;
      if (state.screen === "wishlist")
        return state.wishlist[state.selectedIndex]
          ? `wishlist-${state.wishlist[state.selectedIndex]!.id}`
          : null;
      if (state.screen === "settings")
        return state.profiles[state.selectedIndex]
          ? `profile-${state.profiles[state.selectedIndex]!.name}`
          : null;
      if (state.screen === "now-playing")
        return state.player.bookmarks[state.selectedIndex]
          ? `bookmark-${state.player.bookmarks[state.selectedIndex]!.id}`
          : null;
      return null;
    })();
    if (!target) return;
    // The retained tree needs one layout pass before child coordinates are
    // valid. Scrolling synchronously here used stale y=0 values.
    this.pendingSelectionScroll = setTimeout(() => {
      this.pendingSelectionScroll = null;
      const child = this.body.findDescendantById(target);
      if (!child) return;
      const viewportTop = this.body.screenY + 1;
      const viewportBottom = this.body.screenY + this.body.height - 1;
      const childTop = child.screenY;
      const childBottom = child.screenY + child.height;
      if (child.height >= viewportBottom - viewportTop) {
        this.body.scrollBy(childTop - viewportTop);
      } else if (childTop < viewportTop) {
        this.body.scrollBy(childTop - viewportTop);
      } else if (childBottom > viewportBottom) {
        this.body.scrollBy(childBottom - viewportBottom);
      }
      this.ctx.requestRender();
    }, 0);
  }

  private renderHeader(state: AppState): void {
    const tab = (screen: string, label: string): StyledText | string =>
      state.screen === screen
        ? t`${bold(fg(palette.accent)(label))}`
        : t`${fg(palette.muted)(label)}`;
    const compact = state.width < 104;
    this.navBrand.width = compact ? 5 : 11;
    this.navBrand.content = t`${bold(fg(palette.foreground)(compact ? "AUDIT" : "AUDITUI"))}`;
    this.navLibrary.width = compact ? 6 : 12;
    this.navWishlist.width = compact ? 6 : 12;
    this.navDownloads.width = compact ? 6 : 13;
    this.navNowPlaying.width = compact ? 7 : 15;
    this.navSettings.width = compact ? 6 : 11;
    this.navSearch.width = compact ? 4 : 12;
    this.engineStatus.width = compact ? 3 : 18;
    this.navLibrary.content = tab("library", compact ? "Lib" : "Library");
    this.navWishlist.content = tab("wishlist", compact ? "Wish" : "Wishlist");
    this.navDownloads.content = tab("downloads", compact ? "DL" : "Downloads");
    this.navNowPlaying.content = tab("now-playing", compact ? "Play" : "Now playing");
    this.navSettings.content = tab("settings", compact ? "Set" : "Settings");
    this.navSearch.content = t`${fg(palette.subtle)(compact ? "/" : "/ Search")}`;
    this.engineStatus.content = statusCopy(state.engineStatus === "online", state.engineStatus);
  }

  private renderCommandPalette(state: AppState): void {
    this.commandModal.visible = state.commandPaletteVisible;
    if (!state.commandPaletteVisible) return;
    this.commandModal.width = Math.max(38, Math.min(58, state.width - 4));
    this.commandModal.left = Math.max(0, Math.floor((state.width - this.commandModal.width) / 2));
    this.commandModal.top = Math.max(1, Math.floor((state.height - this.commandModal.height) / 3));
    this.commandText.content = [
      "COMMAND PALETTE",
      "",
      ...commandEntries.map(
        (entry, index) =>
          `${index === state.commandIndex ? "▶" : " "} ${entry.label.padEnd(32)} ${entry.shortcut}`,
      ),
      "",
      "Enter run · Esc close",
    ].join("\n");
  }

  private renderConfirmation(state: AppState): void {
    this.confirmationModal.visible = state.confirmation !== null;
    if (!state.confirmation) return;
    this.confirmationModal.width = Math.max(38, Math.min(62, state.width - 4));
    this.confirmationModal.left = Math.max(
      0,
      Math.floor((state.width - this.confirmationModal.width) / 2),
    );
    this.confirmationModal.top = Math.max(
      1,
      Math.floor((state.height - this.confirmationModal.height) / 2),
    );
    const action =
      state.confirmation.kind === "wishlist.add"
        ? "Add to wishlist?"
        : state.confirmation.kind === "wishlist.remove"
          ? "Remove from wishlist?"
          : "Remove local profile?";
    const safety =
      state.confirmation.kind === "profile.remove"
        ? "\nThis only removes local credentials; it does not change your Audible account."
        : "";
    this.confirmationText.content = `${action}\n\n${state.confirmation.title}${safety}\n\ny / Enter confirm · n / Esc cancel`;
  }

  private navTarget(id: string, width: number, activate: () => void): TextRenderable {
    const target = text(this.ctx, id, "", {
      width,
      bg: palette.surface,
      onMouseDown: (event) => {
        if (event.button !== 0) return;
        event.preventDefault();
        event.stopPropagation();
        activate();
      },
    });
    target.onMouseOver = () => {
      target.bg = palette.surfaceRaised;
      this.ctx.setMousePointer("pointer");
    };
    target.onMouseOut = () => {
      target.bg = palette.surface;
      this.ctx.setMousePointer("default");
    };
    return target;
  }

  private renderDock(state: AppState): void {
    const player = state.player;
    const hasTitle = player.itemId !== null;
    this.hasActivePlayer = hasTitle;
    this.dockTitle.content = hasTitle
      ? t`${fg(palette.accent)(player.paused ? "▶" : "❚❚")}  ${bold(player.title)}${player.chapter ? dim(fg(palette.muted)(`  ·  ${player.chapter}`)) : ""}`
      : t`${fg(palette.subtle)("▶")}  ${fg(palette.muted)("Nothing playing")}`;
    const barWidth = Math.max(10, Math.min(36, state.width - 42));
    const elapsed = formatTime(player.positionSeconds);
    this.dockBarStart = elapsed.length + 2;
    this.dockBarWidth = barWidth;
    this.playerDuration = player.durationSeconds;
    this.dockProgress.content = concat(
      t`${fg(palette.muted)(elapsed)}  `,
      progress(player.positionSeconds, player.durationSeconds, barWidth),
      t`  ${fg(palette.muted)(formatTime(player.durationSeconds))}   ${fg(palette.subtle)(`${player.speed.toFixed(2)}×  vol ${player.volume}%`)}`,
    );
    const mouseHelp = state.width >= 92 ? "    mouse: play/pause · seek" : "";
    this.dockHelp.content = t`${fg(palette.subtle)(`? help    / search    r refresh    q back/quit${mouseHelp}`)}`;
  }

  private toggleFromMouse(
    x: number,
    event: { button: number; preventDefault(): void; stopPropagation(): void },
  ): void {
    // Only the leading play/pause glyph is a control; the title remains inert.
    if (event.button !== 0 || !this.hasActivePlayer || x > this.dockTitle.screenX + 2) return;
    event.preventDefault();
    event.stopPropagation();
    this.options.onTogglePlayback();
  }

  private dockHelpFromMouse(
    x: number,
    event: { button: number; preventDefault(): void; stopPropagation(): void },
  ): void {
    if (event.button !== 0) return;
    const relative = x - this.dockHelp.screenX;
    const action =
      relative < 8
        ? this.options.onToggleHelp
        : relative < 20
          ? this.options.onOpenSearch
          : relative < 33
            ? this.options.onRefresh
            : relative < 49
              ? this.options.onBack
              : undefined;
    if (!action) return;
    event.preventDefault();
    event.stopPropagation();
    action();
  }

  private seekFromMouse(
    x: number,
    force: boolean,
    event: { button: number; preventDefault(): void; stopPropagation(): void },
  ): void {
    if (event.button !== 0 || this.playerDuration <= 0 || this.dockBarWidth <= 1) return;
    const now = Date.now();
    if (!force && now - this.lastDragSeekAt < 80) return;
    this.lastDragSeekAt = now;
    const start = this.dockProgress.screenX + this.dockBarStart;
    const ratio = Math.max(0, Math.min(1, (x - start) / (this.dockBarWidth - 1)));
    event.preventDefault();
    event.stopPropagation();
    this.options.onSeek(ratio * this.playerDuration);
  }

  private renderHelp(state: AppState): void {
    this.helpModal.visible = state.helpVisible;
    if (!state.helpVisible) return;
    const width = Math.max(48, Math.min(86, state.width - 2));
    const height = Math.max(10, Math.min(29, state.height - 2));
    this.helpModal.width = width;
    this.helpModal.height = height;
    this.helpModal.left = Math.max(0, Math.floor((state.width - width) / 2));
    this.helpModal.top = Math.max(0, Math.floor((state.height - height) / 2));
    this.helpText.content = t`${bold(fg(palette.accent)("Keyboard shortcuts & mouse — click/drag timeline"))}

${bold(fg(palette.foreground)("LIBRARY GRID"))}
${bold("h / ←")}      Move left             ${bold("l / →")}      Move right
${bold("k / ↑")}      Move up               ${bold("j / ↓")}      Move down
${bold("Enter")}      Open selected title   ${bold("d")}          Download title

${bold(fg(palette.foreground)("SCREENS & SEARCH"))}
${bold("Ctrl+p")}     Command palette        ${bold("1–5")}        Jump between screens
${bold("1 Library")}  ${bold("2 Wishlist")}  ${bold("3 Downloads")}  ${bold("4 Now playing")}  ${bold("5 Settings")}
${bold("Shift+h/l")}  Previous/next tab      ${bold("/")}          Search library

${bold(fg(palette.foreground)("PLAYBACK · DETAIL / NOW PLAYING"))}
${bold("Space")}      Play/pause             ${bold("h / l")}      Seek −10s / +10s
${bold("[ / ]")}      Previous/next chapter  ${bold(", / .")}      Slower/faster
${bold("+ / −")}      Volume                 ${bold("s")}          Cycle sleep timer
${bold("b")}          Add bookmark           ${bold("x")}          Delete selected bookmark

${bold(fg(palette.foreground)("WISHLIST, DOWNLOADS & GLOBAL"))}
${bold("a / x")}      Add/remove wishlist    ${bold("c / r")}      Cancel/retry download
${bold("a / y")}      Connect Audible/Yoto   ${bold("r")}          Refresh library
${bold("Settings Enter")} Use profile        ${bold("Settings x")} Remove local profile
${bold("Esc")}        Back/close
${bold("q")}          Back or quit           ${bold("?")}          Toggle this help
${bold(fg(palette.foreground)("MOUSE"))}  Click cards/actions/tabs · wheel to scroll · click/drag timeline
${fg(palette.subtle)("Profile removal is local-only and always asks for confirmation.")}

${dim(fg(palette.muted)("Press ? or click to close"))}`;
  }

  private getBodyKey(state: AppState): string {
    const screenData =
      state.screen === "downloads"
        ? state.downloads
        : state.screen === "wishlist"
          ? state.wishlist
          : state.screen === "settings"
            ? state.profiles
            : state.screen === "now-playing"
              ? [
                  // Position and sleep countdown change every second; they are
                  // patched in place by updateNowPlayingLive instead of
                  // rebuilding (and un-hovering) the whole screen.
                  { ...state.player, positionSeconds: 0, sleepTimerSeconds: null },
                  state.library.find((item) => item.id === state.player.itemId)?.coverUrl,
                ]
              : [state.visibleItems, state.downloads];
    return JSON.stringify([
      state.screen,
      state.selectedIndex,
      state.width,
      state.height,
      state.loading,
      state.query,
      state.searchMode,
      state.wishlistInputMode,
      state.wishlistInput,
      state.authInputMode,
      state.authInput,
      state.message,
      state.profileName,
      state.profileSecure,
      screenData,
    ]);
  }

  private clearBody(): void {
    this.nowPlayingProgress = null;
    this.nowPlayingSettings = null;
    for (const child of [...this.body.getChildren()]) {
      this.body.remove(child);
      child.destroyRecursively();
    }
  }

  private renderBody(state: AppState): void {
    if (state.searchMode)
      this.addNotice(
        "Search",
        `› ${state.query}▌   Enter to accept · Esc to clear`,
        palette.accent,
      );
    if (state.wishlistInputMode)
      this.addNotice(
        "Add to wishlist",
        `ASIN: ${state.wishlistInput}▌   Enter to review · Esc cancel`,
        palette.accent,
      );
    if (state.authInputMode)
      this.addNotice(
        "Connect account",
        `Paste final browser URL: ${state.authInput ? "••••••••" : ""}▌   Enter to finish · Esc cancel`,
        palette.accent,
      );
    if (state.message) this.addNotice("Status", state.message, palette.muted);
    if (state.screen === "detail") this.renderDetail(state);
    else if (state.screen === "wishlist") this.renderWishlist(state);
    else if (state.screen === "downloads") this.renderDownloads(state);
    else if (state.screen === "now-playing") this.renderNowPlaying(state);
    else if (state.screen === "settings") this.renderSettings(state);
    else this.renderLibrary(state);
  }

  private addNotice(label: string, message: string, color: string): void {
    const box = new BoxRenderable(this.ctx, {
      id: `notice-${label}`,
      width: "100%",
      height: 3,
      paddingX: 1,
      backgroundColor: palette.surface,
      border: ["left"],
      borderColor: color,
      shouldFill: true,
    });
    box.add(
      text(
        this.ctx,
        `notice-${label}-copy`,
        t`${bold(fg(color)(label))}  ${fg(palette.foreground)(message)}`,
        { width: "100%", bg: palette.surface },
      ),
    );
    this.body.add(box);
  }

  private renderLibrary(state: AppState): void {
    if (state.loading) {
      this.addEmpty("Warming up your library…", "Fetching your listening history and purchases.");
      return;
    }
    if (!state.visibleItems.length && !state.query) {
      if (!state.profileName)
        this.addEmpty(
          "Welcome to Auditui",
          "No account found. Audible: press a. Yoto: run auditui auth login --provider yoto --client-id YOUR_CLIENT_ID once.",
        );
      else if (!state.profileSecure)
        this.addEmpty(
          "Profile needs attention",
          `Protect “${state.profileName}” with chmod 600 before opening its library.`,
        );
      else
        this.addEmpty(
          "Your library is ready",
          "The local cache is empty. Press r to refresh it from Audible.",
        );
      return;
    }
    if (state.query) {
      this.addSection(`Search results for “${state.query}”`, state.visibleItems, state);
      return;
    }
    const continuing = state.visibleItems.filter(
      (item) => item.positionSeconds > 0 && item.positionSeconds < item.durationSeconds,
    );
    if (continuing.length)
      this.addSection(
        "Continue listening",
        continuing.slice(0, Math.min(5, libraryColumnCount(state.width))),
        state,
      );
    // Continue listening is a shortcut shelf. The complete ownership grid must
    // still contain those same titles so "Your library" always means all books.
    this.addSection("Your library", state.visibleItems, state);
  }

  private addSection(title: string, items: LibraryItem[], state: AppState): void {
    const section = new BoxRenderable(this.ctx, {
      id: `section-${title}`,
      width: "100%",
      flexDirection: "column",
      gap: 1,
      backgroundColor: palette.background,
      shouldFill: true,
    });
    section.add(
      text(this.ctx, `section-${title}-title`, sectionTitle(title, items.length), {
        width: "100%",
      }),
    );
    // Keep tiles readable while using wide terminals well. Additional books
    // wrap into subsequent rows instead of stretching cards horizontally.
    const columns = libraryColumnCount(state.width);
    const available = Math.max(28, state.width - 6);
    const cardWidth = Math.floor((available - (columns - 1) * 2) / columns);
    const cardHeight = libraryCardHeight(cardWidth);
    // Keep retained renderables bounded for very large Audible libraries. The
    // window follows keyboard selection, while the full item set remains in
    // reducer state for search and navigation.
    const maxCards = 60;
    const selectedId = state.visibleItems[state.selectedIndex]?.id;
    const selectedInSection = Math.max(
      0,
      items.findIndex((item) => item.id === selectedId),
    );
    const maxStart = Math.max(0, items.length - maxCards);
    const windowStart =
      items.length > maxCards
        ? Math.floor(
            Math.max(0, Math.min(maxStart, selectedInSection - Math.floor(maxCards / 2))) / columns,
          ) * columns
        : 0;
    const windowItems = items.slice(windowStart, windowStart + maxCards);
    if (items.length > maxCards)
      section.add(
        text(
          this.ctx,
          `section-${title}-window`,
          t`${fg(palette.subtle)(`Showing ${windowStart + 1}–${windowStart + windowItems.length} of ${items.length}`)}`,
          { width: "100%" },
        ),
      );
    for (let start = 0; start < windowItems.length; start += columns) {
      const rowItems = windowItems.slice(start, start + columns);
      const selectedId = state.visibleItems[state.selectedIndex]?.id;
      const rowSelected = rowItems.some((item) => item.id === selectedId);
      const row = new BoxRenderable(this.ctx, {
        id: `row-${title}-${windowStart + start}`,
        width: "100%",
        height: cardHeight,
        flexDirection: "row",
        gap: 2,
        backgroundColor: rowSelected ? palette.surface : palette.background,
        border: rowSelected ? ["left"] : false,
        borderStyle: "heavy",
        borderColor: rowSelected ? palette.accent : palette.border,
        shouldFill: true,
      });
      const prefix = title === "Continue listening" ? "book-continue" : "book";
      for (const item of rowItems) {
        row.add(this.bookCard(item, state, cardWidth, `${prefix}-${item.id}`));
      }
      section.add(row);
    }
    if (!items.length)
      section.add(
        text(this.ctx, `section-${title}-empty`, "No titles in this section.", {
          fg: palette.muted,
        }),
      );
    this.body.add(section);
  }

  private bookCard(
    item: LibraryItem,
    state: AppState,
    width: number,
    cardId: string,
  ): BoxRenderable {
    const selected = state.visibleItems[state.selectedIndex]?.id === item.id;
    const coverHeight = libraryCoverHeight(width);
    const coverWidth = coverHeight * 2;
    const cardBackground = selected ? palette.surfaceRaised : palette.surface;
    const card = new BoxRenderable(this.ctx, {
      id: cardId,
      width,
      height: libraryCardHeight(width),
      flexDirection: "column",
      paddingX: 1,
      paddingY: 1,
      backgroundColor: selected ? palette.surfaceRaised : palette.surface,
      border: selected ? ["left"] : ["bottom"],
      borderStyle: "heavy",
      borderColor: selected ? palette.accent : palette.border,
      shouldFill: true,
      onMouseDown: (event) => {
        if (event.button !== 0) return;
        event.preventDefault();
        event.stopPropagation();
        this.options.onOpenItem?.(item.id);
      },
    });
    card.onMouseOver = () => {
      card.backgroundColor = palette.surfaceRaised;
      card.borderColor = palette.accent;
      this.ctx.setMousePointer("pointer");
    };
    card.onMouseOut = () => {
      card.backgroundColor = cardBackground;
      card.borderColor = selected ? palette.accent : palette.border;
      this.ctx.setMousePointer("default");
    };
    const inner = Math.max(12, width - 4);
    const author = item.authors.join(", ") || "Unknown author";
    const transfer = itemDownload(state, item);
    const artwork = new BoxRenderable(this.ctx, {
      id: `${cardId}-artwork`,
      width: "100%",
      height: coverHeight,
      justifyContent: "center",
      alignItems: "center",
      backgroundColor: cardBackground,
    });
    const source = trustedCoverSource(item.coverUrl);
    if (source)
      artwork.add(
        new ImageRenderable(this.ctx, {
          id: `${cardId}-cover`,
          width: coverWidth,
          height: coverHeight,
          source,
          fit: "fit",
          protocol: this.options.imageProtocol,
        }),
      );
    else
      artwork.add(
        text(
          this.ctx,
          `${cardId}-cover-placeholder`,
          t`${dim(fg(palette.muted)(truncate(item.title.toUpperCase(), coverWidth - 2)))}`,
          {
            width: coverWidth,
            height: coverHeight,
            bg: cardBackground,
            wrapMode: "word",
          },
        ),
      );
    card.add(artwork);
    card.add(
      text(
        this.ctx,
        `${cardId}-title`,
        t`${selected ? fg(palette.accent)("▶ ") : "  "}${bold(item.title)}`,
        { width: "100%", height: 2, wrapMode: "word", bg: cardBackground },
      ),
    );
    card.add(
      text(
        this.ctx,
        `${cardId}-author`,
        t`${bold(fg(palette.accent)(providerLabel(item.provider)))} ${dim(fg(palette.muted)(truncate(author, Math.max(4, inner - providerLabel(item.provider).length - 1))))}`,
        {
          width: "100%",
          bg: cardBackground,
        },
      ),
    );
    card.add(
      text(
        this.ctx,
        `${cardId}-progress`,
        progress(item.positionSeconds, item.durationSeconds, Math.max(6, Math.min(14, inner - 12))),
        { width: "100%", bg: cardBackground },
      ),
    );
    card.add(
      text(
        this.ctx,
        `${cardId}-state`,
        concat(
          t`${fg(palette.muted)(listeningState(item))}`,
          transfer?.state === "active"
            ? t`${fg(palette.subtle)("  ·  ")}${fg(palette.accent)(`Downloading ${downloadPercent(transfer)}%`)}`
            : transfer?.state === "queued"
              ? t`${fg(palette.subtle)("  ·  ")}${fg(palette.accent)("Queued")}`
              : transfer?.state === "failed"
                ? t`${fg(palette.subtle)("  ·  ")}${fg(palette.danger)("Download failed")}`
                : item.downloaded || transfer?.state === "completed"
                  ? t`${fg(palette.subtle)("  ·  ")}${fg(palette.success)("✓ Offline")}`
                  : item.streamable
                    ? t`${fg(palette.subtle)("  ·  Stream")}`
                    : t`${fg(palette.subtle)("  ·  Online only")}`,
        ),
        { width: "100%", bg: cardBackground },
      ),
    );
    return card;
  }

  private renderDetail(state: AppState): void {
    const item = state.visibleItems[state.selectedIndex];
    if (!item)
      return this.addEmpty("No book selected", "Return to the library and choose a title.");
    const wide = state.width >= 82;
    const coverHeight = Math.max(10, Math.min(18, state.height - 14));
    const coverWidth = coverHeight * 2;
    const row = new BoxRenderable(this.ctx, {
      id: "detail-layout",
      width: "100%",
      flexDirection: wide ? "row" : "column",
      gap: 3,
      backgroundColor: palette.background,
      shouldFill: true,
    });
    const art = new BoxRenderable(this.ctx, {
      id: "detail-art-frame",
      width: coverWidth + 4,
      height: coverHeight + 4,
      padding: 1,
      border: true,
      borderStyle: "rounded",
      borderColor: palette.borderStrong,
      backgroundColor: palette.surface,
      shouldFill: true,
    });
    const source = selectedCoverSource(state);
    if (source)
      art.add(
        new ImageRenderable(this.ctx, {
          id: "audible-cover",
          width: coverWidth,
          height: coverHeight,
          source,
          fit: "fit",
          protocol: this.options.imageProtocol,
        }),
      );
    else
      art.add(
        text(
          this.ctx,
          "cover-placeholder",
          t`${dim(fg(palette.muted)(truncate(item.title.toUpperCase(), Math.max(8, coverWidth - 2))))}`,
          {
            width: coverWidth,
            height: coverHeight,
            bg: palette.surface,
            wrapMode: "word",
          },
        ),
      );

    const metadata = new BoxRenderable(this.ctx, {
      id: "detail-metadata",
      flexGrow: 1,
      minWidth: 28,
      flexDirection: "column",
      gap: 1,
      backgroundColor: palette.background,
      shouldFill: true,
    });
    const percentage = listeningPercent(item);
    const transfer = itemDownload(state, item);
    metadata.add(
      text(
        this.ctx,
        "detail-kicker",
        t`${fg(palette.accent)(`${providerLabel(item.provider)}  ·  ${item.downloaded ? "AVAILABLE OFFLINE" : item.streamable ? "READY TO STREAM" : "IN YOUR LIBRARY"}`)}`,
        { width: "100%" },
      ),
    );
    metadata.add(
      text(this.ctx, "detail-title", t`${bold(item.title)}`, {
        width: "100%",
        height: 2,
        wrapMode: "word",
      }),
    );
    metadata.add(
      text(
        this.ctx,
        "detail-author",
        t`${fg(palette.muted)(`by ${item.authors.join(", ") || "Unknown author"}`)}`,
        { width: "100%" },
      ),
    );
    metadata.add(
      text(
        this.ctx,
        "detail-narrator",
        t`${fg(palette.muted)(`Narrated by ${item.narrators.join(", ") || "Unknown narrator"}`)}`,
        { width: "100%" },
      ),
    );
    metadata.add(
      text(
        this.ctx,
        "detail-time",
        t`${fg(palette.subtle)(`${formatTime(item.durationSeconds)}  ·  ${item.releaseDate ?? "Release date unavailable"}`)}`,
        { width: "100%" },
      ),
    );
    metadata.add(
      text(
        this.ctx,
        "detail-progress-label",
        t`${fg(palette.muted)("Listening progress")}  ${bold(fg(palette.accent)(`${percentage}% listened`))}`,
        { width: "100%" },
      ),
    );
    metadata.add(
      text(
        this.ctx,
        "detail-progress",
        progress(
          item.positionSeconds,
          item.durationSeconds,
          Math.max(12, Math.min(32, state.width - coverWidth - 18)),
        ),
        { width: "100%" },
      ),
    );
    metadata.add(
      text(
        this.ctx,
        "detail-progress-time",
        t`${fg(palette.subtle)(`${formatTime(item.positionSeconds)} of ${formatTime(item.durationSeconds)}`)}`,
        { width: "100%" },
      ),
    );
    if (transfer?.state === "queued" || transfer?.state === "active") {
      const percentage = downloadPercent(transfer);
      metadata.add(
        text(
          this.ctx,
          "detail-download-progress",
          concat(
            progress(
              transfer.received,
              transfer.total ?? 0,
              Math.max(12, Math.min(32, state.width - coverWidth - 18)),
            ),
            t`  ${bold(fg(palette.accent)(transfer.state === "queued" ? "Queued" : `Downloading ${percentage}%`))}`,
          ),
          { width: "100%" },
        ),
      );
    }
    const detailAction = text(
      this.ctx,
      "detail-action",
      transfer?.state === "queued" || transfer?.state === "active"
        ? t`${bold(fg(palette.accent)(transfer.state === "queued" ? "Queued for download" : `Downloading ${downloadPercent(transfer)}%`))}    ${fg(palette.muted)("3 / click  Monitor or cancel")}`
        : transfer?.state === "failed"
          ? t`${bold(fg(palette.danger)("Download failed"))}    ${fg(palette.muted)("Open Downloads to retry")}`
          : item.downloaded || transfer?.state === "completed"
            ? t`${fg(palette.success)("✓ Available offline")}    ${bold(fg(palette.accent)("Enter  Resume / play"))}`
            : item.streamable
              ? t`${bold(fg(palette.accent)("Enter  Stream / play"))}    ${fg(palette.muted)(`${providerLabel(item.provider)} streaming`)}`
              : item.downloadable !== false
                ? t`${bold(fg(palette.accent)("d  Download"))}    ${fg(palette.muted)("Playback available after download")}`
                : t`${fg(palette.muted)("Unavailable for playback on this account")}`,
      {
        width: "100%",
        onMouseDown: (event) => {
          if (event.button !== 0) return;
          event.preventDefault();
          event.stopPropagation();
          if (
            transfer?.state === "queued" ||
            transfer?.state === "active" ||
            transfer?.state === "failed"
          )
            this.options.onNavigate("downloads");
          else this.options.onActivateItem?.(item.id);
        },
      },
    );
    detailAction.onMouseOver = () => {
      detailAction.bg = palette.surfaceRaised;
      this.ctx.setMousePointer("pointer");
    };
    detailAction.onMouseOut = () => {
      detailAction.bg = palette.background;
      this.ctx.setMousePointer("default");
    };
    metadata.add(detailAction);
    row.add(art);
    row.add(metadata);
    this.body.add(row);
    const description = panel(this.ctx, "detail-description");
    description.padding = 1;
    description.add(
      text(
        this.ctx,
        "detail-description-copy",
        t`${bold("About")}
${fg(palette.muted)(plainDescription(item.description))}`,
        {
          width: "100%",
          height: Math.max(3, Math.min(8, state.height - coverHeight - 10)),
          bg: palette.surface,
          wrapMode: "word",
        },
      ),
    );
    this.body.add(description);
  }

  private renderDownloads(state: AppState): void {
    this.body.add(
      text(this.ctx, "downloads-heading", sectionTitle("Downloads", state.downloads.length), {
        width: "100%",
      }),
    );
    if (!state.downloads.length) {
      const hasStreamOnlyTitles = state.library.some(
        (item) => item.streamable && item.downloadable === false,
      );
      return this.addEmpty(
        "No offline downloads",
        hasStreamOnlyTitles
          ? "Yoto titles stream directly and do not need an Audible-style download."
          : "Press d on a downloadable library title to save it for offline playback.",
      );
    }
    state.downloads.forEach((job, index) =>
      this.body.add(this.downloadCard(job, index === state.selectedIndex, state.width)),
    );
  }

  private renderWishlist(state: AppState): void {
    this.body.add(
      text(this.ctx, "wishlist-heading", sectionTitle("Wishlist", state.wishlist.length), {
        width: "100%",
      }),
    );
    this.body.add(
      text(
        this.ctx,
        "wishlist-help",
        t`${fg(palette.subtle)("a add by ASIN  ·  x remove selected  ·  changes always ask for confirmation")}`,
        { width: "100%" },
      ),
    );
    if (!state.wishlist.length)
      return this.addEmpty("Your wishlist is empty", "Press a to add an Audible title by ASIN.");
    state.wishlist.forEach((item, index) => {
      const selected = index === state.selectedIndex;
      const card = panel(this.ctx, `wishlist-${item.id}`, selected);
      card.height = 5;
      card.padding = 1;
      card.border = ["left"];
      card.borderStyle = "heavy";
      card.borderColor = selected ? palette.accent : palette.border;
      card.onMouseDown = (event) => {
        if (event.button !== 0) return;
        event.preventDefault();
        event.stopPropagation();
        this.options.onSelectWishlist?.(item.id);
      };
      card.onMouseOver = () => {
        card.backgroundColor = palette.surfaceRaised;
        card.borderColor = palette.accent;
        this.ctx.setMousePointer("pointer");
      };
      card.onMouseOut = () => {
        card.backgroundColor = selected ? palette.surfaceRaised : palette.surface;
        card.borderColor = selected ? palette.accent : palette.border;
        this.ctx.setMousePointer("default");
      };
      const bg = selected ? palette.surfaceRaised : palette.surface;
      card.add(
        text(
          this.ctx,
          `wishlist-${item.id}-title`,
          t`${selected ? fg(palette.accent)("▶ ") : "  "}${bold(item.title)}`,
          { width: "100%", bg },
        ),
      );
      card.add(
        text(
          this.ctx,
          `wishlist-${item.id}-author`,
          t`${fg(palette.muted)(item.authors.join(", ") || "Unknown author")}`,
          { width: "100%", bg },
        ),
      );
      const remove = text(
        this.ctx,
        `wishlist-${item.id}-action`,
        t`${fg(palette.subtle)("x  Remove from wishlist")}`,
        {
          width: "100%",
          bg,
          onMouseDown: (event) => {
            if (event.button !== 0) return;
            event.preventDefault();
            event.stopPropagation();
            this.options.onRemoveWishlist?.(item.id);
          },
        },
      );
      remove.onMouseOver = () => this.ctx.setMousePointer("pointer");
      remove.onMouseOut = () => this.ctx.setMousePointer("default");
      card.add(remove);
      this.body.add(card);
    });
  }

  private renderSettings(state: AppState): void {
    this.body.add(
      text(this.ctx, "settings-heading", sectionTitle("Settings & profiles"), { width: "100%" }),
    );
    const account = panel(this.ctx, "settings-account");
    account.padding = 1;
    account.minHeight = 9;
    account.add(
      text(
        this.ctx,
        "settings-profile-label",
        t`${bold("Active profile")}  ${fg(palette.accent)(state.profileName ?? "Not connected")}`,
        { width: "100%", bg: palette.surface },
      ),
    );
    account.add(
      text(
        this.ctx,
        "settings-diagnostics",
        t`${bold("Diagnostics")}  engine ${fg(state.engineStatus === "online" ? palette.success : palette.danger)(state.engineStatus)}  ·  ${state.library.length} cached titles  ·  ${state.downloads.filter((job) => job.state === "active" || job.state === "queued").length} transfers  ·  ${state.width}×${state.height}`,
        { width: "100%", bg: palette.surface },
      ),
    );
    account.add(
      text(
        this.ctx,
        "settings-security",
        t`${fg(state.profileSecure ? palette.success : palette.danger)(state.profileSecure ? "✓ Credential permissions are private" : "! Credential permissions need attention")}`,
        { width: "100%", bg: palette.surface },
      ),
    );
    account.add(
      text(
        this.ctx,
        "settings-onboarding",
        t`${fg(palette.muted)(state.profileName ? "Select an account and press Enter to use it." : "Audible: press a. Yoto: run the one-line --provider yoto --client-id setup command.")}`,
        { width: "100%", bg: palette.surface },
      ),
    );
    this.body.add(account);
    this.body.add(
      text(
        this.ctx,
        "profiles-heading",
        sectionTitle("Discovered profiles", state.profiles.length),
        { width: "100%" },
      ),
    );
    if (!state.profiles.length)
      return this.addEmpty(
        "No profiles found",
        "Audible: press a. Yoto: run auditui auth login --provider yoto --client-id YOUR_CLIENT_ID once.",
      );
    state.profiles.forEach((profile, index) => {
      const selected = index === state.selectedIndex;
      const card = panel(this.ctx, `profile-${profile.name}`, selected);
      card.height = 3;
      card.padding = 1;
      card.border = ["left"];
      card.borderColor = selected ? palette.accent : palette.border;
      card.onMouseDown = (event) => {
        if (event.button !== 0) return;
        event.preventDefault();
        event.stopPropagation();
        this.options.onSelectProfile?.(profile.name);
      };
      card.onMouseOver = () => {
        card.backgroundColor = palette.surfaceRaised;
        card.borderColor = palette.accent;
        this.ctx.setMousePointer("pointer");
      };
      card.onMouseOut = () => {
        card.backgroundColor = selected ? palette.surfaceRaised : palette.surface;
        card.borderColor = selected ? palette.accent : palette.border;
        this.ctx.setMousePointer("default");
      };
      card.add(
        text(
          this.ctx,
          `profile-${profile.name}-copy`,
          t`${selected ? fg(palette.accent)("▶ ") : "  "}${bold(profile.account ?? profile.name)}  ${fg(palette.accent)(providerLabel(profile.provider))}  ${fg(profile.secure ? palette.success : palette.danger)(profile.secure ? "secure" : "unsafe permissions")}`,
          { width: "100%", bg: selected ? palette.surfaceRaised : palette.surface },
        ),
      );
      this.body.add(card);
    });
    if (state.profileName) {
      const remove = text(
        this.ctx,
        "profile-remove-action",
        t`${fg(palette.danger)("x  Remove selected profile from this computer")}`,
        {
          width: "100%",
          onMouseDown: (event) => {
            if (event.button !== 0) return;
            event.preventDefault();
            event.stopPropagation();
            this.options.onRemoveProfile?.();
          },
        },
      );
      remove.onMouseOver = () => {
        remove.bg = palette.surfaceRaised;
        this.ctx.setMousePointer("pointer");
      };
      remove.onMouseOut = () => {
        remove.bg = palette.background;
        this.ctx.setMousePointer("default");
      };
      this.body.add(remove);
    }
  }

  private downloadCard(job: DownloadJob, selected: boolean, width: number): BoxRenderable {
    const card = panel(this.ctx, `download-${job.jobId}`, selected);
    card.height = 5;
    card.padding = 1;
    card.border = ["left"];
    card.borderColor = selected ? palette.accent : palette.border;
    card.onMouseDown = (event) => {
      if (event.button !== 0) return;
      event.preventDefault();
      event.stopPropagation();
      this.options.onSelectDownload?.(job.jobId);
    };
    card.onMouseOver = () => {
      card.backgroundColor = palette.surfaceRaised;
      card.borderColor = palette.accent;
      this.ctx.setMousePointer("pointer");
    };
    card.onMouseOut = () => {
      card.backgroundColor = selected ? palette.surfaceRaised : palette.surface;
      card.borderColor = selected ? palette.accent : palette.border;
      this.ctx.setMousePointer("default");
    };
    const percentage = job.total
      ? Math.max(0, Math.min(100, Math.round((job.received / job.total) * 100)))
      : 0;
    const transferState =
      job.state === "completed"
        ? "Downloaded 100%"
        : job.state === "active"
          ? `Downloading ${percentage}%  ·  c cancel`
          : job.state === "queued"
            ? "Queued  ·  c cancel"
            : job.state === "failed"
              ? `Failed  ·  r retry${job.error ? `  ·  ${truncate(job.error, 34)}` : ""}`
              : "Cancelled  ·  r retry";
    card.add(
      text(
        this.ctx,
        `download-${job.jobId}-title`,
        t`${selected ? fg(palette.accent)("▶ ") : "  "}${bold(job.title)}`,
        { width: "100%", bg: selected ? palette.surfaceRaised : palette.surface },
      ),
    );
    const transfer = text(
      this.ctx,
      `download-${job.jobId}-progress`,
      concat(
        progress(job.received, job.total ?? 0, Math.max(10, Math.min(38, width - 30))),
        t`  ${fg(job.state === "completed" ? palette.success : job.state === "failed" ? palette.danger : palette.muted)(transferState)}`,
      ),
      {
        width: "100%",
        bg: selected ? palette.surfaceRaised : palette.surface,
        onMouseDown: (event) => {
          if (event.button !== 0 || job.state === "completed") return;
          event.preventDefault();
          event.stopPropagation();
          this.options.onDownloadAction?.(job.jobId);
        },
      },
    );
    if (job.state !== "completed") {
      transfer.onMouseOver = () => this.ctx.setMousePointer("pointer");
      transfer.onMouseOut = () => this.ctx.setMousePointer("default");
    }
    card.add(transfer);
    return card;
  }

  private renderNowPlaying(state: AppState): void {
    const player = state.player;
    if (player.itemId === null)
      return this.addEmpty(
        "Nothing playing",
        "Choose a downloaded title from your Library, then press Enter to start listening.",
      );
    const card = new BoxRenderable(this.ctx, {
      id: "now-playing-card",
      width: "100%",
      minHeight: 15,
      flexDirection: "column",
      alignItems: "center",
      gap: 1,
      padding: 2,
      border: true,
      borderStyle: "rounded",
      borderColor: palette.border,
      backgroundColor: palette.surface,
      shouldFill: true,
    });
    card.add(
      text(this.ctx, "now-playing-kicker", t`${fg(palette.accent)("NOW PLAYING")}`, {
        width: "100%",
        bg: palette.surface,
      }),
    );
    const playingItem = state.library.find(
      (item) => item.id === player.itemId || item.asin === player.itemId,
    );
    const coverSource = trustedCoverSource(playingItem?.coverUrl);
    const content = new BoxRenderable(this.ctx, {
      id: "now-playing-layout",
      width: "100%",
      flexDirection: "row",
      gap: 2,
      backgroundColor: palette.surface,
      shouldFill: true,
    });
    const details = new BoxRenderable(this.ctx, {
      id: "now-playing-details",
      flexGrow: 1,
      minWidth: 28,
      flexDirection: "column",
      gap: 1,
      backgroundColor: palette.surface,
      shouldFill: true,
    });
    if (coverSource) {
      const coverHeight = Math.max(8, Math.min(14, state.height - 18));
      const coverWidth = coverHeight * 2;
      const artwork = new BoxRenderable(this.ctx, {
        id: "now-playing-artwork",
        width: coverWidth,
        height: coverHeight,
        justifyContent: "center",
        alignItems: "center",
        backgroundColor: palette.surface,
      });
      artwork.add(
        new ImageRenderable(this.ctx, {
          id: "now-playing-cover",
          width: coverWidth,
          height: coverHeight,
          source: coverSource,
          fit: "fit",
          protocol: this.options.imageProtocol,
        }),
      );
      content.add(artwork);
    }
    content.add(details);
    card.add(content);
    details.add(
      text(this.ctx, "now-playing-title", t`${bold(player.title)}`, {
        width: "100%",
        height: 2,
        bg: palette.surface,
        wrapMode: "word",
      }),
    );
    details.add(
      text(
        this.ctx,
        "now-playing-chapter",
        t`${fg(palette.muted)(player.chapters[Number(player.chapter)]?.title ?? (player.ended ? "Completed" : `Chapter ${Number(player.chapter) + 1}`))}`,
        { width: "100%", bg: palette.surface },
      ),
    );
    if (player.chapters.length) {
      const current = Math.max(
        0,
        Math.min(player.chapters.length - 1, Number(player.chapter) || 0),
      );
      const start = Math.max(0, Math.min(current - 2, player.chapters.length - 6));
      const chapterRow = new BoxRenderable(this.ctx, {
        id: "now-playing-chapters",
        width: "100%",
        height: Math.min(6, player.chapters.length),
        flexDirection: "column",
        backgroundColor: palette.surface,
      });
      for (const chapter of player.chapters.slice(start, start + 6)) {
        const selected = chapter.index === current;
        const entry = text(
          this.ctx,
          `now-playing-chapter-${chapter.index}`,
          t`${selected ? fg(palette.accent)("▶ ") : "  "}${selected ? bold(chapter.title) : fg(palette.muted)(chapter.title)}  ${fg(palette.subtle)(formatTime(chapter.startSeconds))}`,
          {
            width: "100%",
            bg: selected ? palette.surfaceRaised : palette.surface,
            onMouseDown: (event) => {
              if (event.button !== 0) return;
              event.preventDefault();
              event.stopPropagation();
              this.options.onSelectChapter?.(chapter.index);
            },
          },
        );
        entry.onMouseOver = () => {
          entry.bg = palette.surfaceRaised;
          this.ctx.setMousePointer("pointer");
        };
        entry.onMouseOut = () => {
          entry.bg = selected ? palette.surfaceRaised : palette.surface;
          this.ctx.setMousePointer("default");
        };
        chapterRow.add(entry);
      }
      details.add(chapterRow);
    }
    this.nowPlayingProgress = text(
      this.ctx,
      "now-playing-progress",
      this.nowPlayingProgressContent(state),
      { width: "100%", bg: palette.surface },
    );
    details.add(this.nowPlayingProgress);
    const controls = new BoxRenderable(this.ctx, {
      id: "now-playing-controls",
      width: "100%",
      height: 1,
      flexDirection: "row",
      justifyContent: "center",
      backgroundColor: palette.surface,
    });
    controls.add(
      this.playerControl("now-playing-previous", "[ previous ]", 15, "chapter-previous"),
    );
    controls.add(this.playerControl("now-playing-back", "−10s", 9, "seek-back"));
    controls.add(
      this.playerControl(
        "now-playing-toggle",
        player.paused ? "▶ play" : "❚❚ pause",
        12,
        "toggle",
        true,
      ),
    );
    controls.add(this.playerControl("now-playing-forward", "+10s", 9, "seek-forward"));
    controls.add(this.playerControl("now-playing-next", "[ next ]", 12, "chapter-next"));
    details.add(controls);
    this.nowPlayingSettings = text(
      this.ctx,
      "now-playing-settings",
      this.nowPlayingSettingsContent(state),
      { width: "100%", bg: palette.surface },
    );
    details.add(this.nowPlayingSettings);
    this.body.add(card);
    this.body.add(
      text(this.ctx, "bookmarks-heading", sectionTitle("Bookmarks", player.bookmarks.length), {
        width: "100%",
      }),
    );
    if (!player.bookmarks.length) {
      this.body.add(
        text(
          this.ctx,
          "bookmarks-empty",
          t`${fg(palette.muted)("Press b to bookmark the current position.")}`,
          { width: "100%" },
        ),
      );
    } else {
      player.bookmarks.forEach((bookmark, index) => {
        const selected = index === state.selectedIndex;
        const bg = selected ? palette.surfaceRaised : palette.surface;
        const row = panel(this.ctx, `bookmark-${bookmark.id}`, selected);
        row.height = 3;
        row.padding = 1;
        row.border = ["left"];
        row.borderColor = selected ? palette.accent : palette.border;
        row.onMouseDown = (event) => {
          if (event.button !== 0) return;
          event.preventDefault();
          event.stopPropagation();
          this.options.onSelectBookmark?.(bookmark.id);
        };
        row.onMouseOver = () => {
          row.backgroundColor = palette.surfaceRaised;
          row.borderColor = palette.accent;
          this.ctx.setMousePointer("pointer");
        };
        row.onMouseOut = () => {
          row.backgroundColor = selected ? palette.surfaceRaised : palette.surface;
          row.borderColor = selected ? palette.accent : palette.border;
          this.ctx.setMousePointer("default");
        };
        row.add(
          text(
            this.ctx,
            `bookmark-${bookmark.id}-copy`,
            t`${selected ? fg(palette.accent)("▶ ") : "  "}${bold(formatTime(bookmark.positionSeconds))}  ${fg(palette.muted)(bookmark.label)}  ${fg(palette.subtle)("Enter jump · x delete")}`,
            { width: "100%", bg },
          ),
        );
        this.body.add(row);
      });
    }
  }

  private nowPlayingProgressContent(state: AppState) {
    const player = state.player;
    return concat(
      t`${fg(palette.muted)(formatTime(player.positionSeconds))}  `,
      progress(
        player.positionSeconds,
        player.durationSeconds,
        Math.max(12, Math.min(48, state.width - 30)),
      ),
      t`  ${fg(palette.muted)(formatTime(player.durationSeconds))}`,
    );
  }

  private nowPlayingSettingsContent(state: AppState) {
    const player = state.player;
    const sleep =
      player.sleepTimerMode === "chapter"
        ? "end of chapter"
        : player.sleepTimerSeconds !== null
          ? formatTime(player.sleepTimerSeconds)
          : (player.sleepTimer ?? "off");
    return t`${fg(palette.subtle)(`Speed ${player.speed.toFixed(2)}×   Volume ${player.volume}% (+/−)   Sleep ${sleep} (s)`)} `;
  }

  private updateNowPlayingLive(state: AppState): void {
    if (this.nowPlayingProgress)
      this.nowPlayingProgress.content = this.nowPlayingProgressContent(state);
    if (this.nowPlayingSettings)
      this.nowPlayingSettings.content = this.nowPlayingSettingsContent(state);
  }

  private playerControl(
    id: string,
    label: string,
    width: number,
    command: "toggle" | "seek-back" | "seek-forward" | "chapter-previous" | "chapter-next",
    accent = false,
  ): TextRenderable {
    const control = text(
      this.ctx,
      id,
      accent ? t`${bold(fg(palette.accent)(label))}` : t`${fg(palette.muted)(label)}`,
      {
        width,
        bg: palette.surface,
        onMouseDown: (event) => {
          if (event.button !== 0) return;
          event.preventDefault();
          event.stopPropagation();
          this.options.onPlayerCommand?.(command);
        },
      },
    );
    control.onMouseOver = () => {
      control.bg = palette.surfaceRaised;
      this.ctx.setMousePointer("pointer");
    };
    control.onMouseOut = () => {
      control.bg = palette.surface;
      this.ctx.setMousePointer("default");
    };
    return control;
  }

  private addEmpty(title: string, copy: string): void {
    const card = new BoxRenderable(this.ctx, {
      id: "empty-state",
      width: "100%",
      minHeight: 8,
      flexDirection: "column",
      justifyContent: "center",
      alignItems: "center",
      gap: 1,
      border: true,
      borderStyle: "rounded",
      borderColor: palette.border,
      backgroundColor: palette.surface,
      shouldFill: true,
    });
    card.add(
      text(this.ctx, "empty-title", t`${bold(fg(palette.foreground)(title))}`, {
        width: "100%",
        bg: palette.surface,
      }),
    );
    card.add(
      text(this.ctx, "empty-copy", t`${fg(palette.muted)(copy)}`, {
        width: "100%",
        height: 2,
        bg: palette.surface,
        wrapMode: "word",
      }),
    );
    this.body.add(card);
  }
}
