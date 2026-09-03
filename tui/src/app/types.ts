export type Screen = "library" | "wishlist" | "downloads" | "now-playing" | "settings" | "detail";

export interface ProfileInfo {
  name: string;
  secure: boolean;
  provider?: string;
  account?: string;
}

export type Confirmation =
  | { kind: "wishlist.add" | "wishlist.remove"; asin: string; title: string }
  | { kind: "profile.remove"; profile: string; title: string };

export interface LibraryItem {
  id: string;
  asin?: string;
  title: string;
  authors: string[];
  narrators: string[];
  durationSeconds: number;
  positionSeconds: number;
  coverUrl?: string;
  localPath?: string;
  description?: string;
  releaseDate?: string;
  downloaded: boolean;
  provider?: string;
  account?: string;
  streamable?: boolean;
  downloadable?: boolean;
  downloadState?: "queued" | "active" | "completed" | "failed" | "cancelled";
}

export interface DownloadJob {
  jobId: string;
  itemId: string;
  title: string;
  state: "queued" | "active" | "completed" | "failed" | "cancelled";
  received: number;
  total: number | null;
  localPath?: string;
  error?: string;
  provider?: string;
  account?: string;
}

export interface PlayerState {
  itemId: string | null;
  title: string;
  chapter: string;
  positionSeconds: number;
  durationSeconds: number;
  paused: boolean;
  speed: number;
  volume: number;
  sleepTimer: string | null;
  sleepTimerSeconds: number | null;
  sleepTimerMode: "duration" | "chapter" | null;
  bookmarks: Array<{ id: string; positionSeconds: number; label: string }>;
  chapters: Array<{ index: number; title: string; startSeconds: number }>;
  ended: boolean;
}

export type EngineStatus = "starting" | "online" | "restarting" | "offline";

export interface AppState {
  screen: Screen;
  previousScreen: Screen;
  library: LibraryItem[];
  visibleItems: LibraryItem[];
  selectedIndex: number;
  downloads: DownloadJob[];
  wishlist: LibraryItem[];
  profiles: ProfileInfo[];
  player: PlayerState;
  query: string;
  searchMode: boolean;
  helpVisible: boolean;
  commandPaletteVisible: boolean;
  commandIndex: number;
  wishlistInputMode: boolean;
  wishlistInput: string;
  authInputMode: boolean;
  authInput: string;
  confirmation: Confirmation | null;
  loading: boolean;
  engineStatus: EngineStatus;
  profileName: string | null;
  profileSecure: boolean;
  activeProvider: string;
  activeAccount: string | null;
  message: string | null;
  width: number;
  height: number;
}

export type Action =
  | { type: "engine.status"; status: EngineStatus; message?: string }
  | {
      type: "profile.loaded";
      name: string | null;
      secure: boolean;
      provider?: string;
      account?: string | null;
    }
  | { type: "library.loading" }
  | { type: "library.loaded"; items: LibraryItem[] }
  | { type: "library.failed"; message: string }
  | { type: "download.list"; jobs: DownloadJob[] }
  | { type: "download.progress"; job: Partial<DownloadJob> & Pick<DownloadJob, "jobId"> }
  | { type: "wishlist.loaded"; items: LibraryItem[] }
  | { type: "profiles.loaded"; profiles: ProfileInfo[] }
  | { type: "player.status"; player: Partial<PlayerState> }
  | { type: "navigate"; screen: Screen }
  | { type: "move"; amount: number }
  | { type: "search.open" }
  | { type: "search.change"; query: string }
  | { type: "search.results"; items: LibraryItem[] }
  | { type: "search.close" }
  | { type: "help.toggle" }
  | { type: "command.toggle" }
  | { type: "command.move"; amount: number; count: number }
  | { type: "wishlist.input.open" }
  | { type: "wishlist.input.change"; value: string }
  | { type: "wishlist.input.close" }
  | { type: "auth.input.open" }
  | { type: "auth.input.change"; value: string }
  | { type: "auth.input.close" }
  | { type: "confirmation.open"; confirmation: Confirmation }
  | { type: "confirmation.close" }
  | { type: "resize"; width: number; height: number }
  | { type: "message"; message: string | null };
