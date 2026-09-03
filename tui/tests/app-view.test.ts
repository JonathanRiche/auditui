import { afterEach, describe, expect, test } from "bun:test";
import { createMockMouse, createTestRenderer, MouseButtons } from "@opentui/core/testing";
import { initialState, reducer } from "../src/app/state";
import { AppView, nextSpeedPreset } from "../src/ui/app-view";

const renderers: Array<{ destroy(): void }> = [];
afterEach(() => {
  for (const renderer of renderers.splice(0)) renderer.destroy();
});

const item = {
  id: "dune",
  title: "Dune",
  authors: ["Frank Herbert"],
  narrators: ["Simon Vance"],
  durationSeconds: 75_600,
  positionSeconds: 24_192,
  downloaded: true,
  description: "A sweeping story of politics, ecology, and destiny.",
};

describe("retained app view", () => {
  test("renders real shell panels and responsive library cards", async () => {
    const setup = await createTestRenderer({ width: 120, height: 36 });
    renderers.push(setup.renderer);
    const view = new AppView(setup.renderer, {
      imageProtocol: "blocks",
      onResize() {},
      onSeek() {},
      onTogglePlayback() {},
      onNavigate() {},
      onOpenSearch() {},
    });
    setup.renderer.root.add(view.root);
    let state = reducer(initialState(120, 36), { type: "library.loaded", items: [item] });
    state = reducer(state, { type: "engine.status", status: "online" });
    view.render(state);
    await setup.renderOnce();

    const frame = setup.captureCharFrame();
    expect(frame).toContain("AUDITUI");
    expect(frame).toContain("Continue listening");
    expect(frame).toContain("Dune");
    expect(frame).toContain("32% listened");
    expect(frame).toContain("Offline");
    expect(frame).toContain("Nothing playing");
    expect(view.root.findDescendantById("app-header")).toBeDefined();
    expect(view.root.findDescendantById("app-content")).toBeDefined();
    expect(view.root.findDescendantById("book-dune")).toBeDefined();
    expect(view.root.findDescendantById("book-continue-dune")).toBeDefined();
    expect(view.root.findDescendantById("player-dock")).toBeDefined();
  });

  test("shows live download progress on library cards and detail without a restart", async () => {
    const setup = await createTestRenderer({ width: 120, height: 36 });
    renderers.push(setup.renderer);
    const view = new AppView(setup.renderer, {
      imageProtocol: "blocks",
      onResize() {},
      onSeek() {},
      onTogglePlayback() {},
      onNavigate() {},
      onOpenSearch() {},
    });
    setup.renderer.root.add(view.root);
    let state = reducer(initialState(120, 36), {
      type: "library.loaded",
      items: [{ ...item, positionSeconds: 0, downloaded: false }],
    });
    view.render(state);
    await setup.renderOnce();

    state = reducer(state, {
      type: "download.progress",
      job: {
        jobId: "dune",
        itemId: "dune",
        title: "Dune",
        state: "active",
        received: 25,
        total: 100,
      },
    });
    view.render(state);
    await setup.renderOnce();
    expect(setup.captureCharFrame()).toContain("Downloading 25%");

    state = reducer(state, { type: "navigate", screen: "detail" });
    view.render(state);
    await setup.renderOnce();
    expect(setup.captureCharFrame()).toContain("Monitor or cancel");

    state = reducer(state, {
      type: "download.progress",
      job: {
        jobId: "dune",
        state: "completed",
        received: 100,
        total: 100,
        localPath: "/books/dune.aaxc",
      },
    });
    view.render(state);
    await setup.renderOnce();
    expect(setup.captureCharFrame()).toContain("Available offline");
  });

  test("tiles growing libraries into responsive cover-card rows", async () => {
    const setup = await createTestRenderer({ width: 190, height: 50 });
    renderers.push(setup.renderer);
    const view = new AppView(setup.renderer, {
      imageProtocol: "blocks",
      onResize() {},
      onSeek() {},
      onTogglePlayback() {},
      onNavigate() {},
      onOpenSearch() {},
    });
    setup.renderer.root.add(view.root);
    const books = Array.from({ length: 7 }, (_, index) => ({
      ...item,
      id: `book-${index}`,
      title: `Book ${index + 1}`,
      positionSeconds: 0,
    }));
    const state = reducer(initialState(190, 50), { type: "library.loaded", items: books });
    view.render(state);
    await setup.renderOnce();

    expect(view.root.findDescendantById("row-Your library-0")?.getChildren()).toHaveLength(5);
    expect(view.root.findDescendantById("row-Your library-5")?.getChildren()).toHaveLength(2);
    expect(view.root.findDescendantById("book-book-0-artwork")).toBeDefined();
  });

  test("scrolls the selected tile into view after vim-style navigation", async () => {
    const setup = await createTestRenderer({ width: 72, height: 32 });
    renderers.push(setup.renderer);
    const view = new AppView(setup.renderer, {
      imageProtocol: "blocks",
      onResize() {},
      onSeek() {},
      onTogglePlayback() {},
      onNavigate() {},
      onOpenSearch() {},
    });
    setup.renderer.root.add(view.root);
    const books = Array.from({ length: 8 }, (_, index) => ({
      ...item,
      id: `scroll-${index}`,
      title: `Scroll Book ${index}`,
      positionSeconds: 0,
    }));
    let state = reducer(initialState(72, 32), { type: "library.loaded", items: books });
    view.render(state);
    await setup.renderOnce();
    state = reducer(state, { type: "move", amount: 7 });
    view.render(state);
    await setup.renderOnce();
    await Bun.sleep(5);
    await setup.renderOnce();

    const body = view.root.findDescendantById("app-content") as unknown as { scrollTop: number };
    expect(body.scrollTop).toBeGreaterThan(0);
    const selected = view.root.findDescendantById("book-scroll-7")!;
    const content = view.root.findDescendantById("app-content")!;
    expect(selected.screenY + selected.height).toBeLessThanOrEqual(
      content.screenY + content.height,
    );
    const focusedRow = view.root.findDescendantById("row-Your library-6") as unknown as {
      border: unknown;
    };
    expect(focusedRow.border).toEqual(["left"]);
  });

  test("uses a nested cover frame and a true modal help surface", async () => {
    const setup = await createTestRenderer({ width: 90, height: 30 });
    renderers.push(setup.renderer);
    const view = new AppView(setup.renderer, {
      imageProtocol: "blocks",
      onResize() {},
      onSeek() {},
      onTogglePlayback() {},
      onNavigate() {},
      onOpenSearch() {},
    });
    setup.renderer.root.add(view.root);
    let state = reducer(initialState(90, 30), { type: "library.loaded", items: [item] });
    state = reducer(state, { type: "navigate", screen: "detail" });
    state = reducer(state, { type: "help.toggle" });
    view.render(state);
    await setup.renderOnce();

    expect(view.root.findDescendantById("detail-art-frame")).toBeDefined();
    expect(view.root.findDescendantById("cover-placeholder")?.parent?.id).toBe("detail-art-frame");
    expect(view.root.findDescendantById("help-modal")?.visible).toBe(true);
    const help = setup.captureCharFrame();
    expect(help).toContain("Keyboard shortcuts");
    expect(help).toContain("Shift+h/l");
    expect(help).toContain("2 Wishlist");
    expect(help).toContain("5 Settings");
    expect(help).toContain("Cancel/retry download");
    expect(help).toContain("click/drag timeline");
    state = reducer(state, { type: "help.toggle" });
    view.render(state);
    await setup.renderOnce();
    const detail = setup.captureCharFrame();
    expect(detail).toContain("Listening progress");
    expect(detail).toContain("32% listened");
    expect(detail).toContain("Available offline");
  });

  test("renders Audible publisher-summary HTML as readable text", async () => {
    const setup = await createTestRenderer({ width: 90, height: 42 });
    renderers.push(setup.renderer);
    const view = new AppView(setup.renderer, {
      imageProtocol: "blocks",
      onResize() {},
      onSeek() {},
      onTogglePlayback() {},
      onNavigate() {},
      onOpenSearch() {},
    });
    setup.renderer.root.add(view.root);
    const described = {
      ...item,
      description: "<p>A hero &amp; a friend.</p><p>Another chapter.</p>",
    };
    let state = reducer(initialState(90, 42), { type: "library.loaded", items: [described] });
    state = reducer(state, { type: "navigate", screen: "detail" });
    view.render(state);
    await setup.renderOnce();

    const frame = setup.captureCharFrame();
    expect(frame).toContain("A hero & a friend.");
    expect(frame).toContain("Another chapter.");
    expect(frame).not.toContain("<p>");
  });

  test("labels Yoto content as streamable without Audible download actions", async () => {
    const setup = await createTestRenderer({ width: 90, height: 36 });
    renderers.push(setup.renderer);
    const view = new AppView(setup.renderer, {
      imageProtocol: "blocks",
      onResize() {},
      onSeek() {},
      onTogglePlayback() {},
      onNavigate() {},
      onOpenSearch() {},
    });
    setup.renderer.root.add(view.root);
    const yoto = {
      ...item,
      id: "yoto-1",
      title: "Bedtime Story",
      downloaded: false,
      provider: "yoto",
      account: "kids-room",
      streamable: true,
      downloadable: false,
    };
    let state = reducer(initialState(90, 36), { type: "library.loaded", items: [yoto] });
    view.render(state);
    await setup.renderOnce();
    expect(setup.captureCharFrame()).toContain("YOTO");

    state = reducer(state, { type: "navigate", screen: "detail" });
    view.render(state);
    await setup.renderOnce();
    const detail = setup.captureCharFrame();
    expect(detail).toContain("READY TO STREAM");
    expect(detail).toContain("Stream / play");
    expect(detail).not.toContain("d  Download");

    state = reducer(state, { type: "navigate", screen: "downloads" });
    view.render(state);
    await setup.renderOnce();
    const downloads = setup.captureCharFrame();
    expect(downloads).toContain("Yoto titles stream directly");
    expect(downloads).not.toContain("Press d on any library title");
  });

  test("clicks play/pause and clicks or drags the timeline to seek", async () => {
    const setup = await createTestRenderer({ width: 120, height: 30 });
    renderers.push(setup.renderer);
    const seeks: number[] = [];
    const navigations: string[] = [];
    const speeds: number[] = [];
    const volumes: number[] = [];
    let toggles = 0;
    const view = new AppView(setup.renderer, {
      imageProtocol: "blocks",
      onResize() {},
      onSeek(position) {
        seeks.push(position);
      },
      onTogglePlayback() {
        toggles += 1;
      },
      onSetSpeed(value) {
        speeds.push(value);
      },
      onSetVolume(value) {
        volumes.push(value);
      },
      onNavigate(screen) {
        navigations.push(screen);
      },
      onOpenSearch() {},
    });
    setup.renderer.root.add(view.root);
    let state = initialState(120, 30);
    state = {
      ...state,
      player: {
        itemId: "dune",
        title: "Dune",
        durationSeconds: 100,
        positionSeconds: 0,
        paused: false,
        chapter: "",
        speed: 1,
        volume: 100,
        sleepTimer: null,
        sleepTimerSeconds: null,
        sleepTimerMode: null,
        bookmarks: [],
        chapters: [],
        ended: false,
      },
    };
    view.render(state);
    await setup.renderOnce();

    const mouse = createMockMouse(setup.renderer);
    const title = view.root.findDescendantById("dock-title")!;
    const timeline = view.root.findDescendantById("dock-progress")!;
    await mouse.click(title.screenX, title.screenY, MouseButtons.LEFT);
    expect(toggles).toBe(1);

    // The bar fills the dock: "0:00  " then the bar, then "  1:40   1.00×  vol 100%".
    const { start: barStart, width: barWidth } = view.timelineGeometry();
    expect(barStart).toBe(timeline.screenX + 6);
    expect(barWidth).toBe(120 - 4 - (4 + 2 + 2 + 4 + 3 + 15));
    await mouse.click(
      barStart + Math.round((barWidth - 1) / 2),
      timeline.screenY,
      MouseButtons.LEFT,
    );
    expect(seeks.at(-1)).toBeGreaterThan(45);
    expect(seeks.at(-1)).toBeLessThan(55);

    // Pressing the time labels or speed readout must not seek.
    const seekCount = seeks.length;
    await mouse.click(timeline.screenX + 1, timeline.screenY, MouseButtons.LEFT);
    await mouse.click(barStart + barWidth + 3, timeline.screenY, MouseButtons.LEFT);
    expect(seeks.length).toBe(seekCount);

    // Dragging to the very end stops short of it so playback does not finish.
    await mouse.drag(
      barStart + 2,
      timeline.screenY,
      barStart + barWidth - 1,
      timeline.screenY,
      MouseButtons.LEFT,
    );
    expect(seeks.at(-1)).toBe(95);

    // The speed readout is a control: left click steps up a preset, right click down.
    // Row: "0:00  " + bar + "  1:40   1.00×  vol 100%"
    const speedX = barStart + barWidth + 2 + 4 + 3;
    const seeksBeforeReadout = seeks.length;
    await mouse.click(speedX, timeline.screenY, MouseButtons.LEFT);
    await mouse.click(speedX + 4, timeline.screenY, MouseButtons.RIGHT);
    expect(speeds).toEqual([1.25, 0.75]);
    await mouse.click(speedX + 5 + 2, timeline.screenY, MouseButtons.LEFT);
    expect(volumes).toEqual([110]);
    expect(seeks.length).toBe(seeksBeforeReadout);

    // Clicking the title text (not the glyph) opens the player screen.
    await mouse.click(title.screenX + 8, title.screenY, MouseButtons.LEFT);
    expect(toggles).toBe(1);
    expect(navigations).toEqual(["now-playing"]);
  });

  test("makes every header destination clickable", async () => {
    const setup = await createTestRenderer({ width: 120, height: 30 });
    renderers.push(setup.renderer);
    const destinations: string[] = [];
    let searches = 0;
    const view = new AppView(setup.renderer, {
      imageProtocol: "blocks",
      onResize() {},
      onSeek() {},
      onTogglePlayback() {},
      onNavigate(screen) {
        destinations.push(screen);
      },
      onOpenSearch() {
        searches += 1;
      },
    });
    setup.renderer.root.add(view.root);
    view.render(initialState(120, 30));
    await setup.renderOnce();
    const mouse = createMockMouse(setup.renderer);

    for (const [id, expected] of [
      ["nav-library", "library"],
      ["nav-downloads", "downloads"],
      ["nav-now-playing", "now-playing"],
    ] as const) {
      const target = view.root.findDescendantById(id)!;
      await mouse.click(target.screenX, target.screenY, MouseButtons.LEFT);
      expect(destinations.at(-1)).toBe(expected);
    }
    const search = view.root.findDescendantById("nav-search")!;
    await mouse.click(search.screenX, search.screenY, MouseButtons.LEFT);
    expect(searches).toBe(1);
  });

  test("supports mouse actions across library, detail, downloads, player, and dock", async () => {
    const setup = await createTestRenderer({ width: 120, height: 42 });
    renderers.push(setup.renderer);
    const pointerStyles: string[] = [];
    const setMousePointer = setup.renderer.setMousePointer.bind(setup.renderer);
    setup.renderer.setMousePointer = (style) => {
      pointerStyles.push(style);
      setMousePointer(style);
    };
    const opened: string[] = [];
    const activated: string[] = [];
    const selectedDownloads: string[] = [];
    const playerCommands: string[] = [];
    let help = 0;
    const view = new AppView(setup.renderer, {
      imageProtocol: "blocks",
      onResize() {},
      onSeek() {},
      onTogglePlayback() {},
      onNavigate() {},
      onOpenSearch() {},
      onOpenItem(id) {
        opened.push(id);
      },
      onActivateItem(id) {
        activated.push(id);
      },
      onSelectDownload(id) {
        selectedDownloads.push(id);
      },
      onPlayerCommand(command) {
        playerCommands.push(command);
      },
      onToggleHelp() {
        help += 1;
      },
    });
    setup.renderer.root.add(view.root);
    const mouse = createMockMouse(setup.renderer);
    let state = reducer(initialState(120, 42), { type: "library.loaded", items: [item] });
    view.render(state);
    await setup.renderOnce();

    const book = view.root.findDescendantById("book-dune")!;
    await mouse.moveTo(book.screenX + 2, book.screenY + 2);
    expect(pointerStyles).toContain("pointer");
    await mouse.click(book.screenX + 2, book.screenY + 2, MouseButtons.LEFT);
    expect(opened).toEqual(["dune"]);

    state = reducer(state, { type: "navigate", screen: "detail" });
    view.render(state);
    await setup.renderOnce();
    const detailAction = view.root.findDescendantById("detail-action")!;
    await mouse.click(detailAction.screenX, detailAction.screenY, MouseButtons.LEFT);
    expect(activated).toEqual(["dune"]);

    state = reducer(state, {
      type: "download.list",
      jobs: [
        {
          jobId: "job-1",
          itemId: "dune",
          title: "Dune",
          state: "active",
          received: 50,
          total: 100,
        },
      ],
    });
    state = reducer(state, { type: "navigate", screen: "downloads" });
    view.render(state);
    await setup.renderOnce();
    const download = view.root.findDescendantById("download-job-1")!;
    await mouse.click(download.screenX + 2, download.screenY + 1, MouseButtons.LEFT);
    expect(selectedDownloads).toEqual(["job-1"]);

    state = reducer(state, {
      type: "player.status",
      player: { itemId: "dune", title: "Dune", durationSeconds: 100 },
    });
    state = reducer(state, { type: "navigate", screen: "now-playing" });
    view.render(state);
    await setup.renderOnce();
    for (const [id, command] of [
      ["now-playing-back", "seek-back"],
      ["now-playing-toggle", "toggle"],
      ["now-playing-next", "chapter-next"],
    ] as const) {
      const control = view.root.findDescendantById(id)!;
      await mouse.click(control.screenX, control.screenY, MouseButtons.LEFT);
      expect(playerCommands.at(-1)).toBe(command);
    }

    const dockHelp = view.root.findDescendantById("dock-help")!;
    await mouse.click(dockHelp.screenX, dockHelp.screenY, MouseButtons.LEFT);
    expect(help).toBe(1);
  });

  test("makes list actions, profiles, and bookmarks directly mouse-operable", async () => {
    const setup = await createTestRenderer({ width: 120, height: 42 });
    renderers.push(setup.renderer);
    const events: string[] = [];
    const view = new AppView(setup.renderer, {
      imageProtocol: "blocks",
      onResize() {},
      onSeek() {},
      onTogglePlayback() {},
      onNavigate() {},
      onOpenSearch() {},
      onDownloadAction(id) {
        events.push(`download:${id}`);
      },
      onSelectWishlist(id) {
        events.push(`wishlist:${id}`);
      },
      onRemoveWishlist(id) {
        events.push(`wishlist-remove:${id}`);
      },
      onSelectProfile(name) {
        events.push(`profile:${name}`);
      },
      onRemoveProfile() {
        events.push("profile-remove");
      },
      onSelectBookmark(id) {
        events.push(`bookmark:${id}`);
      },
      onSelectChapter(index) {
        events.push(`chapter:${index}`);
      },
    });
    setup.renderer.root.add(view.root);
    const mouse = createMockMouse(setup.renderer);
    let state = reducer(initialState(120, 42), {
      type: "download.list",
      jobs: [
        {
          jobId: "job-1",
          itemId: "dune",
          title: "Dune",
          state: "failed",
          received: 50,
          total: 100,
          error: "connection interrupted",
        },
      ],
    });
    state = reducer(state, { type: "navigate", screen: "downloads" });
    view.render(state);
    await setup.renderOnce();
    const downloadAction = view.root.findDescendantById("download-job-1-progress")!;
    await mouse.click(downloadAction.screenX + 4, downloadAction.screenY, MouseButtons.LEFT);
    expect(events).toContain("download:job-1");

    state = reducer(state, {
      type: "profiles.loaded",
      profiles: [{ name: "reader", secure: true }],
    });
    state = reducer(state, { type: "profile.loaded", name: "reader", secure: true });
    state = reducer(state, { type: "navigate", screen: "settings" });
    view.render(state);
    await setup.renderOnce();
    const profile = view.root.findDescendantById("profile-reader")!;
    await mouse.click(profile.screenX + 2, profile.screenY + 1, MouseButtons.LEFT);
    const removeProfile = view.root.findDescendantById("profile-remove-action")!;
    await mouse.click(removeProfile.screenX + 2, removeProfile.screenY, MouseButtons.LEFT);
    expect(events).toContain("profile:reader");
    expect(events).toContain("profile-remove");

    state = reducer(state, {
      type: "player.status",
      player: {
        itemId: "dune",
        title: "Dune",
        durationSeconds: 100,
        bookmarks: [{ id: "9", positionSeconds: 22, label: "Sandworm" }],
        chapter: "1",
        chapters: [
          { index: 0, title: "Arrival", startSeconds: 0 },
          { index: 1, title: "Sandworm", startSeconds: 22 },
        ],
      },
    });
    state = reducer(state, { type: "navigate", screen: "now-playing" });
    view.render(state);
    await setup.renderOnce();
    const bookmark = view.root.findDescendantById("bookmark-9")!;
    await mouse.click(bookmark.screenX + 2, bookmark.screenY + 1, MouseButtons.LEFT);
    expect(events).toContain("bookmark:9");
    const chapter = view.root.findDescendantById("now-playing-chapter-1")!;
    await mouse.click(chapter.screenX + 2, chapter.screenY, MouseButtons.LEFT);
    expect(events).toContain("chapter:1");
  });

  test("renders wishlist, profiles, command confirmation, and rich player surfaces", async () => {
    const setup = await createTestRenderer({ width: 100, height: 38 });
    renderers.push(setup.renderer);
    const view = new AppView(setup.renderer, {
      imageProtocol: "blocks",
      onResize() {},
      onSeek() {},
      onTogglePlayback() {},
      onNavigate() {},
      onOpenSearch() {},
    });
    setup.renderer.root.add(view.root);
    let state = reducer(initialState(100, 38), {
      type: "wishlist.loaded",
      items: [{ ...item, asin: "B012345678" }],
    });
    state = reducer(state, { type: "navigate", screen: "wishlist" });
    state = reducer(state, {
      type: "confirmation.open",
      confirmation: { kind: "wishlist.remove", asin: "B012345678", title: "Dune" },
    });
    view.render(state);
    await setup.renderOnce();
    expect(setup.captureCharFrame()).toContain("changes always ask for confirmation");
    expect(view.root.findDescendantById("confirmation-modal")?.visible).toBe(true);

    state = reducer(state, { type: "confirmation.close" });
    state = reducer(state, {
      type: "profiles.loaded",
      profiles: [{ name: "personal", secure: true }],
    });
    state = reducer(state, { type: "profile.loaded", name: "personal", secure: true });
    state = reducer(state, { type: "navigate", screen: "settings" });
    view.render(state);
    await setup.renderOnce();
    expect(setup.captureCharFrame()).toContain("Credential permissions are private");
    expect(view.root.findDescendantById("profile-personal")).toBeDefined();

    state = reducer(state, {
      type: "library.loaded",
      items: [
        {
          ...item,
          coverUrl: "https://m.media-amazon.com/images/I/example.jpg",
        },
      ],
    });
    state = reducer(state, {
      type: "player.status",
      player: {
        itemId: "dune",
        title: "Dune",
        durationSeconds: 100,
        positionSeconds: 25,
        sleepTimerSeconds: 900,
        sleepTimerMode: "duration",
        bookmarks: [{ id: "7", positionSeconds: 20, label: "The beginning" }],
        chapter: "1",
        chapters: [
          { index: 0, title: "Opening", startSeconds: 0 },
          { index: 1, title: "The reveal", startSeconds: 40 },
        ],
      },
    });
    state = reducer(state, { type: "navigate", screen: "now-playing" });
    view.render(state);
    await setup.renderOnce();
    const frame = setup.captureCharFrame();
    expect(frame).toContain("Bookmarks");
    expect(frame).toContain("The beginning");
    expect(frame).toContain("The reveal");
    expect(frame).toContain("15:00");
    expect(view.root.findDescendantById("now-playing-cover")).toBeDefined();
    state = reducer(state, { type: "command.toggle" });
    view.render(state);
    await setup.renderOnce();
    expect(view.root.findDescendantById("command-palette")?.visible).toBe(true);
  });

  test("bounds retained cards for large libraries and compacts narrow navigation", async () => {
    const setup = await createTestRenderer({ width: 72, height: 30 });
    renderers.push(setup.renderer);
    const view = new AppView(setup.renderer, {
      imageProtocol: "blocks",
      onResize() {},
      onSeek() {},
      onTogglePlayback() {},
      onNavigate() {},
      onOpenSearch() {},
    });
    setup.renderer.root.add(view.root);
    const books = Array.from({ length: 100 }, (_, index) => ({
      ...item,
      id: `large-${index}`,
      title: `Book ${index}`,
      positionSeconds: 0,
    }));
    const state = reducer(initialState(72, 30), { type: "library.loaded", items: books });
    view.render(state);
    await setup.renderOnce();
    const frame = setup.captureCharFrame();
    expect(frame).toContain("Wish");
    expect(view.root.findDescendantById("section-Your library-window")).toBeDefined();
    expect(view.root.findDescendantById("book-large-59")).toBeDefined();
    expect(view.root.findDescendantById("book-large-60")).toBeUndefined();
  });
});

describe("speed presets", () => {
  test("step through presets in both directions and wrap", () => {
    expect(nextSpeedPreset(1)).toBe(1.25);
    expect(nextSpeedPreset(1.1)).toBe(1.25);
    expect(nextSpeedPreset(2.5)).toBe(0.75);
    expect(nextSpeedPreset(1, true)).toBe(0.75);
    expect(nextSpeedPreset(0.75, true)).toBe(2.5);
    expect(nextSpeedPreset(1.45, true)).toBe(1.25);
  });
});
