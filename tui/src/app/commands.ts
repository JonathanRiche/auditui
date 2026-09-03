import type { Screen } from "./types";

export type CommandId =
  | "library"
  | "wishlist"
  | "downloads"
  | "now-playing"
  | "settings"
  | "search"
  | "refresh"
  | "help";

export interface CommandEntry {
  id: CommandId;
  label: string;
  shortcut: string;
  screen?: Screen;
}

export const commandEntries: readonly CommandEntry[] = [
  { id: "library", label: "Go to Library", shortcut: "1", screen: "library" },
  { id: "wishlist", label: "Go to Wishlist", shortcut: "2", screen: "wishlist" },
  { id: "downloads", label: "Go to Downloads", shortcut: "3", screen: "downloads" },
  { id: "now-playing", label: "Go to Now Playing", shortcut: "4", screen: "now-playing" },
  { id: "settings", label: "Open Settings & Profiles", shortcut: "5", screen: "settings" },
  { id: "search", label: "Search your library", shortcut: "/" },
  { id: "refresh", label: "Refresh Audible library", shortcut: "r" },
  { id: "help", label: "Keyboard shortcuts", shortcut: "?" },
];
