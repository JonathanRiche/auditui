import { createCliRenderer } from "@opentui/core";
import type { ImageRenderProtocol } from "@opentui/core";
import { AppController } from "./app/controller";
import { initialState, reducer } from "./app/state";
import type { Action, AppState } from "./app/types";
import { EngineSupervisor } from "./engine/process";
import { palette, watchActiveTheme } from "./theme/palette";
import { AppView } from "./ui/app-view";
import type { AppViewOptions } from "./ui/app-view";

const renderer = await createCliRenderer({
  exitOnCtrlC: false,
  useMouse: true,
  backgroundColor: palette.background,
  clearOnShutdown: true,
  // Negotiate a local file-backed Kitty transfer and let OpenTUI own ACKs,
  // cleanup, serialization, and fallback. This keeps large base64 pixel
  // streams out of Ghostty's terminal parser.
  kittyImageTransport: "file",
});

let state: AppState = initialState(renderer.terminalWidth, renderer.terminalHeight);
const requestedImageProtocol = process.env.AUDIBLE_TUI_IMAGE_PROTOCOL;
const imageProtocol: ImageRenderProtocol =
  requestedImageProtocol === "auto" ||
  requestedImageProtocol === "kitty" ||
  requestedImageProtocol === "sixel" ||
  requestedImageProtocol === "blocks"
    ? requestedImageProtocol
    : "auto";
let controller: AppController | null = null;
const viewOptions: AppViewOptions = {
  imageProtocol,
  onResize(width, height) {
    if (width !== state.width || height !== state.height)
      dispatch({ type: "resize", width, height });
  },
  onSeek(positionSeconds) {
    controller?.seekTo(positionSeconds);
  },
  onTogglePlayback() {
    controller?.togglePlayback();
  },
  onNavigate(screen) {
    controller?.navigateTo(screen);
  },
  onOpenSearch() {
    controller?.openSearch();
  },
  onOpenItem(itemId) {
    controller?.openItem(itemId);
  },
  onActivateItem(itemId) {
    controller?.activateItem(itemId);
  },
  onSelectDownload(jobId) {
    controller?.selectDownload(jobId);
  },
  onDownloadAction(jobId) {
    controller?.activateDownload(jobId);
  },
  onSelectWishlist(itemId) {
    controller?.selectWishlist(itemId);
  },
  onRemoveWishlist(itemId) {
    controller?.removeWishlist(itemId);
  },
  onSelectProfile(name) {
    controller?.selectProfile(name);
  },
  onRemoveProfile() {
    controller?.requestProfileRemoval();
  },
  onSelectBookmark(bookmarkId) {
    controller?.selectBookmark(bookmarkId);
  },
  onSelectChapter(index) {
    controller?.selectChapter(index);
  },
  onPlayerCommand(command) {
    controller?.playerMouseCommand(command);
  },
  onRefresh() {
    controller?.refreshLibrary();
  },
  onToggleHelp() {
    controller?.toggleHelp();
  },
  onBack() {
    controller?.backOrQuit();
  },
};
let view = new AppView(renderer, viewOptions);
renderer.root.add(view.root);

function dispatch(action: Action): void {
  state = reducer(state, action);
  view.render(state);
}

let quitting = false;
const stopWatchingTheme = watchActiveTheme(() => {
  renderer.setBackgroundColor(palette.background);
  renderer.root.remove(view.root);
  view.root.destroyRecursively();
  view = new AppView(renderer, viewOptions);
  renderer.root.add(view.root);
  view.render(state);
});
const supervisor = new EngineSupervisor();
controller = new AppController(
  {
    getState: () => state,
    dispatch,
    runInteractiveRefresh: (profile) =>
      runSecureEngineCommand(["library", "refresh", "--profile", profile]),
    runInteractiveConnect: (provider) =>
      provider === "yoto"
        ? runSecureEngineCommand(["auth", "login", "--provider", "yoto"])
        : runSecureEngineCommand([
            "quickstart",
            "--profile",
            process.env.AUDITUI_PROFILE ?? "default",
            "--country-code",
            process.env.AUDITUI_COUNTRY_CODE ?? "us",
          ]),
    quit: shutdown,
  },
  supervisor,
);
renderer.on("focus", () => void controller.refreshAccountLibraryIfStale());

async function shutdown(): Promise<void> {
  if (quitting) return;
  quitting = true;
  stopWatchingTheme();
  await controller?.stop();
  renderer.destroy();
}

async function runSecureEngineCommand(args: string[]): Promise<boolean> {
  // OpenTUI releases raw mode and the alternate screen while the native CLI
  // owns the controlling terminal. The CLI reads passphrases directly from
  // the TTY with echo disabled; they never cross RPC, argv, logs, or app state.
  renderer.suspend();
  try {
    const executable = process.env.AUDIBLE_ENGINE ?? "audible-zig";
    const child = Bun.spawn([executable, ...args], {
      stdin: "inherit",
      stdout: "inherit",
      stderr: "inherit",
      env: { ...process.env },
    });
    return (await child.exited) === 0;
  } finally {
    renderer.resume();
    view.render(state);
  }
}

renderer.keyInput.on("keypress", (key) => {
  if (key.ctrl && key.name === "c") void shutdown();
  else controller?.handleKey(key);
});
process.once("SIGTERM", () => void shutdown());
process.once("SIGHUP", () => void shutdown());
view.render(state);
controller.start();
