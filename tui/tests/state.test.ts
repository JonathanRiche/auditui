import { describe, expect, test } from "bun:test";
import { initialState, reducer } from "../src/app/state";
import type { LibraryItem } from "../src/app/types";

const books: LibraryItem[] = [
  {
    id: "1",
    title: "Dune",
    authors: ["Frank Herbert"],
    narrators: ["Simon Vance"],
    durationSeconds: 100,
    positionSeconds: 32,
    downloaded: false,
  },
  {
    id: "2",
    title: "Project Hail Mary",
    authors: ["Andy Weir"],
    narrators: ["Ray Porter"],
    durationSeconds: 200,
    positionSeconds: 0,
    downloaded: true,
  },
];

describe("application reducer", () => {
  test("loads, filters and clamps library selection", () => {
    let state = reducer(initialState(), { type: "library.loaded", items: books });
    state = reducer(state, { type: "move", amount: 20 });
    expect(state.selectedIndex).toBe(1);
    state = reducer(state, { type: "search.change", query: "herbert" });
    expect(state.visibleItems.map((item) => item.id)).toEqual(["1"]);
    expect(state.selectedIndex).toBe(0);
  });

  test("search filters by provider and account as well as book metadata", () => {
    const yoto = {
      ...books[0]!,
      id: "yoto-1",
      provider: "yoto",
      account: "kids-room",
      streamable: true,
      downloadable: false,
    };
    let state = reducer(initialState(), { type: "library.loaded", items: [...books, yoto] });
    state = reducer(state, { type: "search.change", query: "yoto" });
    expect(state.visibleItems.map((item) => item.id)).toEqual(["yoto-1"]);
    state = reducer(state, { type: "search.change", query: "kids-room" });
    expect(state.visibleItems.map((item) => item.id)).toEqual(["yoto-1"]);
  });

  test("merges asynchronous player and download events", () => {
    let state = initialState();
    state = reducer(state, {
      type: "player.status",
      player: { itemId: "1", title: "Dune", paused: false },
    });
    state = reducer(state, {
      type: "download.progress",
      job: {
        jobId: "job-1",
        itemId: "1",
        title: "Dune",
        state: "active",
        received: 10,
        total: 100,
      },
    });
    state = reducer(state, { type: "download.progress", job: { jobId: "job-1", received: 75 } });
    expect(state.player).toMatchObject({ title: "Dune", paused: false });
    expect(state.downloads[0]).toMatchObject({ received: 75, total: 100 });
  });

  test("tracks previous screen for back navigation", () => {
    const state = reducer(initialState(), { type: "navigate", screen: "detail" });
    expect(state).toMatchObject({ screen: "detail", previousScreen: "library" });
  });

  test("preserves the selected title when a live refresh adds purchases", () => {
    const first = {
      id: "one",
      title: "One",
      authors: [],
      narrators: [],
      durationSeconds: 1,
      positionSeconds: 0,
      downloaded: false,
    };
    const second = { ...first, id: "two", title: "Two" };
    let state = reducer(initialState(), { type: "library.loaded", items: [first, second] });
    state = reducer(state, { type: "move", amount: 1 });
    state = reducer(state, {
      type: "library.loaded",
      items: [{ ...first, id: "new", title: "New" }, first, second],
    });
    expect(state.visibleItems[state.selectedIndex]?.id).toBe("two");
  });

  test("orders selection the same way the continuing shelf is displayed", () => {
    const untouched = {
      id: "new",
      title: "New",
      authors: [],
      narrators: [],
      durationSeconds: 100,
      positionSeconds: 0,
      downloaded: false,
    };
    const continuing = { ...untouched, id: "active", title: "Active", positionSeconds: 25 };
    let state = reducer(initialState(), { type: "library.loaded", items: [untouched, continuing] });
    expect(state.visibleItems.map((item) => item.id)).toEqual(["active", "new"]);
    state = reducer(state, { type: "move", amount: 1 });
    expect(state.visibleItems[state.selectedIndex]?.id).toBe("new");
  });

  test("keeps a cached library visible during a remote refresh", () => {
    let state = reducer(initialState(), { type: "library.loaded", items: books });
    state = reducer(state, { type: "library.loading" });
    expect(state.loading).toBe(false);
    expect(state.visibleItems).toHaveLength(2);
  });

  test("tracks wishlist confirmation and command palette state", () => {
    let state = reducer(initialState(), { type: "command.toggle" });
    state = reducer(state, { type: "command.move", amount: 3, count: 8 });
    expect(state).toMatchObject({ commandPaletteVisible: true, commandIndex: 3 });
    state = reducer(state, {
      type: "confirmation.open",
      confirmation: { kind: "wishlist.remove", asin: "B012345678", title: "Dune" },
    });
    expect(state.confirmation?.title).toBe("Dune");
    state = reducer(state, { type: "confirmation.close" });
    expect(state.confirmation).toBeNull();
  });
});
