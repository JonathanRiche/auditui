import type { AppState, DownloadJob, LibraryItem } from "../app/types";
import { detailCoverGeometry } from "./cover";

const truncate = (value: string, width: number): string =>
  value.length <= width
    ? value
    : width <= 1
      ? value.slice(0, width)
      : `${value.slice(0, width - 1)}…`;

export function formatTime(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return "0:00";
  const rounded = Math.floor(seconds);
  const hours = Math.floor(rounded / 3600);
  const minutes = Math.floor((rounded % 3600) / 60);
  const secs = rounded % 60;
  return hours > 0
    ? `${hours}:${String(minutes).padStart(2, "0")}:${String(secs).padStart(2, "0")}`
    : `${minutes}:${String(secs).padStart(2, "0")}`;
}

export function progressBar(value: number, total: number, width: number): string {
  const ratio = total > 0 ? Math.max(0, Math.min(1, value / total)) : 0;
  const filled = Math.round(ratio * width);
  return `${"━".repeat(filled)}${"─".repeat(Math.max(0, width - filled))}`;
}

function header(state: AppState): string {
  const active = (name: string, label: string) => (state.screen === name ? `[${label}]` : label);
  const status = state.engineStatus === "online" ? "● online" : `◌ ${state.engineStatus}`;
  return ` AUDIBLE   ${active("library", "Library")}  ${active("downloads", "Downloads")}  ${active("now-playing", "Now playing")}   / Search                                      ${status}`;
}

function bookLines(item: LibraryItem, selected: boolean, width: number): string[] {
  const inside = Math.max(6, width - 4);
  const author = item.authors.join(", ") || "Unknown author";
  const ratio = item.durationSeconds ? item.positionSeconds / item.durationSeconds : 0;
  const percent = Math.max(0, Math.min(100, Math.round(ratio * 100)));
  const listening =
    percent >= 100 ? "Finished" : percent === 0 ? "Not started" : `${percent}% listened`;
  const state = `${listening} · ${item.downloaded ? "Offline" : "Online only"}`;
  return [
    `${selected ? "▶" : " "}┌${"─".repeat(inside)}┐`,
    ` │ ${truncate(item.title.toUpperCase(), inside - 2).padEnd(inside - 1)}│`,
    ` │ ${truncate(author, inside - 2).padEnd(inside - 1)}│`,
    ` └${"─".repeat(inside)}┘`,
    `  ${truncate(item.title, inside + 1)}`,
    `  ${progressBar(item.positionSeconds, item.durationSeconds, Math.min(8, inside - 1))} ${state}`,
  ];
}

function shelf(items: LibraryItem[], state: AppState, title: string): string[] {
  const narrow = state.width < 96;
  const columns = narrow ? 1 : Math.max(2, Math.min(4, Math.floor((state.width - 2) / 24)));
  const tileWidth = narrow
    ? Math.max(24, state.width - 4)
    : Math.floor((state.width - 2) / columns);
  const visibleRows = narrow ? 3 : 2;
  const max = columns * visibleRows;
  const output = [` ${title}`];
  for (let index = 0; index < Math.min(items.length, max); index += columns) {
    const row = items
      .slice(index, index + columns)
      .map((item, column) =>
        bookLines(item, state.visibleItems[state.selectedIndex]?.id === item.id, tileWidth),
      );
    for (let line = 0; line < 6; line++) {
      output.push(row.map((tile) => tile[line]!.padEnd(tileWidth)).join(""));
    }
  }
  if (!items.length) output.push("   No titles here yet.");
  return output;
}

function library(state: AppState): string[] {
  if (state.loading) return ["", "   Warming up your library…"];
  if (!state.visibleItems.length && !state.query) {
    if (!state.profileName)
      return [
        "",
        "                          WELCOME TO AUDITUI",
        "",
        "   No Audible profile was detected.",
        "   Connect your account in another terminal (Amazon password stays in your browser):",
        "   auditui auth login --country-code us",
        "   Choose your Audible marketplace code, then restart this app.",
        "   Existing audible-cli profiles in ~/.audible are discovered automatically.",
      ];
    if (!state.profileSecure)
      return [
        "",
        `   Profile “${state.profileName}” was found, but its credential permissions are unsafe.`,
        "   Protect the profile file with chmod 600 before accessing the library.",
      ];
    return [
      "",
      `   Profile: ${state.profileName}`,
      "",
      "   Your local library cache is empty.",
      "   Press r to refresh it from Audible.",
      `   If a passphrase is required, run: auditui library refresh --profile ${state.profileName}`,
      "   The TUI stays available offline and will recover if the engine restarts.",
    ];
  }
  const continuing = state.visibleItems.filter(
    (item) => item.positionSeconds > 0 && item.positionSeconds < item.durationSeconds,
  );
  const rest = state.visibleItems.filter((item) => !continuing.includes(item));
  const lines = state.query ? [` Search results for “${state.query}”`] : [];
  if (continuing.length) lines.push(...shelf(continuing, state, "Continue listening"), "");
  lines.push(...shelf(continuing.length ? rest : state.visibleItems, state, "Your library"));
  return lines;
}

function detail(state: AppState): string[] {
  const item = state.visibleItems[state.selectedIndex];
  if (!item) return ["", "   No book selected."];
  const percent = item.durationSeconds
    ? Math.round((item.positionSeconds / item.durationSeconds) * 100)
    : 0;
  const geometry = detailCoverGeometry(state.width, state.height);
  const coverWidth = geometry.width;
  const coverBlank = " ".repeat(coverWidth);
  const coverLabel = `  ${truncate(item.title.toUpperCase(), coverWidth - 4).padEnd(coverWidth - 4)}  `;
  const frameTop = `   ┌${"─".repeat(coverWidth)}┐`;
  const frameLine = (label = "") => `   │${label.padEnd(coverWidth)}│`;
  const frameBottom = `   └${"─".repeat(coverWidth)}┘`;
  const metadata = new Map<number, string>([
    [0, `by ${item.authors.join(", ") || "Unknown author"}`],
    [1, `Narrated by ${item.narrators.join(", ") || "Unknown narrator"}`],
    [3, `${formatTime(item.durationSeconds)} · ${item.releaseDate ?? "Release date unavailable"}`],
    [
      5,
      `Listening progress  ${progressBar(item.positionSeconds, item.durationSeconds, 28)} ${percent}% listened`,
    ],
    [
      7,
      `${item.downloaded ? "✓ Available offline" : "d Download"}     ${item.localPath ? "Enter Resume/Play" : "Download to enable playback"}`,
    ],
  ]);
  const coverLines = Array.from({ length: geometry.height }, (_, index) => {
    const label = index === Math.floor(geometry.height / 2) ? coverLabel : coverBlank;
    const meta = metadata.get(index);
    return `${frameLine(label)}${meta ? `   ${meta}` : ""}`;
  });
  return [
    "",
    `${frameTop}   ${item.title}`,
    ...coverLines,
    frameBottom,
    "",
    `   ${truncate(
      item.description
        ?.replace(/<[^>]+>/g, "")
        .replace(/&nbsp;/gi, " ")
        .replace(/&amp;/gi, "&")
        .replace(/\s+/g, " ") ?? "No description available.",
      Math.max(30, state.width - 8),
    )}`,
  ];
}

function jobLine(job: DownloadJob, width: number, selected: boolean): string {
  const percent = job.total ? Math.round((job.received / job.total) * 100) : 0;
  const bar = progressBar(job.received, job.total ?? 0, Math.min(24, Math.max(8, width - 48)));
  return ` ${selected ? "▶" : " "} ${truncate(job.title, 28).padEnd(28)} ${bar} ${String(percent).padStart(3)}%  ${job.state}`;
}

function downloads(state: AppState): string[] {
  return [
    "",
    " Downloads",
    "",
    ...(state.downloads.length
      ? state.downloads.map((job, index) =>
          jobLine(job, state.width, index === state.selectedIndex),
        )
      : ["   No downloads. Press d on a library title to start one."]),
  ];
}

function nowPlaying(state: AppState): string[] {
  const player = state.player;
  return [
    "",
    "                       NOW PLAYING",
    "",
    "                 ┌────────────────────┐",
    "                 │                    │",
    `                 │   ${truncate(player.title.toUpperCase(), 14).padEnd(14)}   │`,
    "                 │                    │",
    "                 └────────────────────┘",
    "",
    `                 ${player.title}`,
    `                 ${player.chapter || (player.ended ? "Completed" : "Chapter unavailable")}`,
    "",
    `      ${formatTime(player.positionSeconds)}  ${progressBar(player.positionSeconds, player.durationSeconds, Math.max(12, Math.min(42, state.width - 34)))}  ${formatTime(player.durationSeconds)}`,
    `      [ previous   h -10s   ${player.paused ? "▶ play" : "❚❚ pause"}   l +10s   ] next`,
    `      Speed ${player.speed.toFixed(2)}×   Volume ${player.volume}%   Sleep ${player.sleepTimer ?? "off"}`,
  ];
}

function playerDock(state: AppState): string[] {
  const player = state.player;
  const narrow = state.width < 96;
  const title = truncate(player.title, narrow ? 22 : 36);
  const timeline = progressBar(player.positionSeconds, player.durationSeconds, narrow ? 12 : 24);
  if (narrow)
    return [
      "─".repeat(state.width),
      ` ${player.paused ? "▶" : "❚❚"} ${title}  ${timeline} ${formatTime(player.positionSeconds)}`,
    ];
  return [
    "─".repeat(state.width),
    `  ${player.paused ? "▶" : "❚❚"}  ${title} · ${truncate(player.chapter, 24)}`,
    `     [ ${player.paused ? "Play" : "Pause"} ]  ${formatTime(player.positionSeconds)} ${timeline} ${formatTime(player.durationSeconds)}   ${player.speed.toFixed(2)}×  vol ${player.volume}%`,
  ];
}

function help(state: AppState): string[] {
  const width = Math.min(62, state.width - 4);
  const rule = `┌${"─".repeat(width - 2)}┐`;
  return [
    rule,
    `│ Keyboard shortcuts${" ".repeat(Math.max(0, width - 21))}│`,
    `│ ↑/k ↓/j  Move     Enter  Open / play${" ".repeat(Math.max(0, width - 40))}│`,
    `│ /         Search   d      Download   r Refresh${" ".repeat(Math.max(0, width - 50))}│`,
    `│ Space     Pause    h/l    Seek ±10s${" ".repeat(Math.max(0, width - 39))}│`,
    `│ [ / ]     Chapter  ,/.    Speed${" ".repeat(Math.max(0, width - 35))}│`,
    `│ 1 Library  2 Wishlist  3 Downloads  4 Now playing  5 Settings${" ".repeat(Math.max(0, width - 63))}│`,
    `│ q Back/quit          ? Close help${" ".repeat(Math.max(0, width - 36))}│`,
    `└${"─".repeat(width - 2)}┘`,
  ];
}

export function renderLayout(state: AppState): string {
  const body = state.helpVisible
    ? help(state)
    : state.screen === "detail"
      ? detail(state)
      : state.screen === "downloads"
        ? downloads(state)
        : state.screen === "now-playing"
          ? nowPlaying(state)
          : library(state);
  const search = state.searchMode
    ? [``, ` Search: ${state.query}▌  (Enter accept · Esc clear)`]
    : [];
  const message = state.message
    ? [` ! ${truncate(state.message, Math.max(10, state.width - 4))}`]
    : [];
  const lines = [header(state), "─".repeat(state.width), ...search, ...message, ...body];
  const dock = playerDock(state);
  const room = Math.max(0, state.height - dock.length - 1);
  return [
    ...lines.slice(0, room),
    ...Array(Math.max(0, room - lines.length)).fill(""),
    ...dock,
    " ? help  / search  r refresh  q back/quit",
  ].join("\n");
}
