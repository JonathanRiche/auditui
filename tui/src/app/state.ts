import type { Action, AppState, DownloadJob, LibraryItem, PlayerState } from "./types";

export const libraryColumnCount = (width: number): number =>
  Math.max(1, Math.min(5, Math.floor((width - 4) / 34)));

export const emptyPlayer: PlayerState = {
  itemId: null,
  title: "Nothing playing",
  chapter: "",
  positionSeconds: 0,
  durationSeconds: 0,
  paused: true,
  speed: 1,
  volume: 100,
  sleepTimer: null,
  sleepTimerSeconds: null,
  sleepTimerMode: null,
  bookmarks: [],
  chapters: [],
  ended: false,
};

export function initialState(width = 100, height = 30): AppState {
  return {
    screen: "library",
    previousScreen: "library",
    library: [],
    visibleItems: [],
    selectedIndex: 0,
    downloads: [],
    wishlist: [],
    profiles: [],
    player: emptyPlayer,
    query: "",
    searchMode: false,
    helpVisible: false,
    commandPaletteVisible: false,
    commandIndex: 0,
    wishlistInputMode: false,
    wishlistInput: "",
    authInputMode: false,
    authInput: "",
    confirmation: null,
    loading: true,
    engineStatus: "starting",
    profileName: null,
    profileSecure: true,
    activeProvider: "audible",
    activeAccount: null,
    message: null,
    width,
    height,
  };
}

function matches(item: LibraryItem, query: string): boolean {
  const needle = query.trim().toLocaleLowerCase();
  if (!needle) return true;
  const metadata = [item.title, ...item.authors, ...item.narrators].some((value) =>
    value.toLocaleLowerCase().includes(needle),
  );
  return (
    metadata ||
    item.provider?.toLocaleLowerCase() === needle ||
    item.account?.toLocaleLowerCase().includes(needle) === true
  );
}

function filtered(library: LibraryItem[], query: string): LibraryItem[] {
  const matchesQuery = library.filter((item) => matches(item, query));
  // The library view presents in-progress books first. Keep the state in that
  // same order so keyboard movement, activation, and the visible highlight all
  // refer to the same title.
  const continuing = matchesQuery.filter(
    (item) => item.positionSeconds > 0 && item.positionSeconds < item.durationSeconds,
  );
  const remaining = matchesQuery.filter(
    (item) => !(item.positionSeconds > 0 && item.positionSeconds < item.durationSeconds),
  );
  return [...continuing, ...remaining];
}

function applyDownloadState(items: LibraryItem[], jobs: DownloadJob[]): LibraryItem[] {
  const byItem = new Map<string, DownloadJob>();
  for (const job of jobs) byItem.set(job.itemId, job);
  return items.map((item) => {
    const job = byItem.get(item.id) ?? (item.asin ? byItem.get(item.asin) : undefined);
    if (!job) return item;
    return {
      ...item,
      downloadState: job.state,
      downloaded: item.downloaded || job.state === "completed",
      ...(job.state === "completed" && job.localPath ? { localPath: job.localPath } : {}),
    };
  });
}

function withDownloads(state: AppState, downloads: DownloadJob[]): AppState {
  const selectedId = state.visibleItems[state.selectedIndex]?.id;
  const library = applyDownloadState(state.library, downloads);
  const visibleItems = filtered(library, state.query);
  const retainedIndex = selectedId
    ? visibleItems.findIndex((item) => item.id === selectedId)
    : state.selectedIndex;
  return {
    ...state,
    downloads,
    library,
    visibleItems,
    selectedIndex: Math.max(0, Math.min(retainedIndex, Math.max(0, visibleItems.length - 1))),
  };
}

export function reducer(state: AppState, action: Action): AppState {
  switch (action.type) {
    case "engine.status":
      return { ...state, engineStatus: action.status, message: action.message ?? state.message };
    case "profile.loaded":
      return {
        ...state,
        profileName: action.name,
        profileSecure: action.secure,
        activeProvider: action.provider ?? "audible",
        activeAccount: action.account ?? action.name,
      };
    case "library.loading":
      // A remote reconciliation should not replace a useful cached library
      // with the initial loading screen.
      return { ...state, loading: state.library.length === 0, message: null };
    case "library.loaded": {
      const selectedId = state.visibleItems[state.selectedIndex]?.id;
      const visibleItems = filtered(action.items, state.query);
      const retainedIndex = selectedId
        ? visibleItems.findIndex((item) => item.id === selectedId)
        : -1;
      const selectedIndex =
        retainedIndex >= 0
          ? retainedIndex
          : Math.min(state.selectedIndex, Math.max(0, visibleItems.length - 1));
      return { ...state, library: action.items, visibleItems, selectedIndex, loading: false };
    }
    case "library.failed":
      return { ...state, loading: false, message: action.message };
    case "download.list":
      return withDownloads(state, action.jobs);
    case "wishlist.loaded":
      return {
        ...state,
        wishlist: action.items,
        selectedIndex:
          state.screen === "wishlist"
            ? Math.min(state.selectedIndex, Math.max(0, action.items.length - 1))
            : state.selectedIndex,
      };
    case "profiles.loaded":
      return {
        ...state,
        profiles: action.profiles,
        selectedIndex:
          state.screen === "settings"
            ? Math.min(state.selectedIndex, Math.max(0, action.profiles.length - 1))
            : state.selectedIndex,
      };
    case "download.progress": {
      const index = state.downloads.findIndex((job) => job.jobId === action.job.jobId);
      if (index < 0) {
        const job = {
          itemId: "",
          title: "Audiobook download",
          state: "active" as const,
          received: 0,
          total: null,
          ...action.job,
        };
        return withDownloads(state, [...state.downloads, job]);
      }
      const downloads = state.downloads.slice();
      downloads[index] = { ...downloads[index]!, ...action.job };
      return withDownloads(state, downloads);
    }
    case "player.status":
      return { ...state, player: { ...state.player, ...action.player } };
    case "navigate":
      return {
        ...state,
        previousScreen: state.screen,
        screen: action.screen,
        selectedIndex:
          state.screen === "detail" || action.screen === "detail" ? state.selectedIndex : 0,
        helpVisible: false,
        commandPaletteVisible: false,
      };
    case "move": {
      const count =
        state.screen === "downloads"
          ? state.downloads.length
          : state.screen === "wishlist"
            ? state.wishlist.length
            : state.screen === "settings"
              ? state.profiles.length
              : state.screen === "now-playing"
                ? state.player.bookmarks.length
                : state.visibleItems.length;
      if (!count) return state;
      return {
        ...state,
        selectedIndex: Math.max(0, Math.min(count - 1, state.selectedIndex + action.amount)),
      };
    }
    case "search.open":
      return {
        ...state,
        searchMode: true,
        query: "",
        visibleItems: filtered(state.library, ""),
        selectedIndex: 0,
      };
    case "search.change": {
      const visibleItems = filtered(state.library, action.query);
      return { ...state, query: action.query, visibleItems, selectedIndex: 0 };
    }
    case "search.results":
      return {
        ...state,
        visibleItems: action.items,
        selectedIndex: Math.min(state.selectedIndex, Math.max(0, action.items.length - 1)),
      };
    case "search.close":
      return { ...state, searchMode: false };
    case "help.toggle":
      return {
        ...state,
        helpVisible: !state.helpVisible,
        searchMode: false,
        commandPaletteVisible: false,
      };
    case "command.toggle":
      return {
        ...state,
        commandPaletteVisible: !state.commandPaletteVisible,
        commandIndex: 0,
        helpVisible: false,
        searchMode: false,
      };
    case "command.move":
      return {
        ...state,
        commandIndex: Math.max(
          0,
          Math.min(Math.max(0, action.count - 1), state.commandIndex + action.amount),
        ),
      };
    case "wishlist.input.open":
      return { ...state, wishlistInputMode: true, wishlistInput: "", commandPaletteVisible: false };
    case "wishlist.input.change":
      return { ...state, wishlistInput: action.value };
    case "wishlist.input.close":
      return { ...state, wishlistInputMode: false, wishlistInput: "" };
    case "auth.input.open":
      return { ...state, authInputMode: true, authInput: "", commandPaletteVisible: false };
    case "auth.input.change":
      return { ...state, authInput: action.value };
    case "auth.input.close":
      return { ...state, authInputMode: false, authInput: "" };
    case "confirmation.open":
      return { ...state, confirmation: action.confirmation, wishlistInputMode: false };
    case "confirmation.close":
      return { ...state, confirmation: null };
    case "resize":
      return { ...state, width: action.width, height: action.height };
    case "message":
      return { ...state, message: action.message };
  }
}
