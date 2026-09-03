import type { DownloadJob, LibraryItem, PlayerState } from "../app/types";

const record = (value: unknown): Record<string, unknown> =>
  value && typeof value === "object" ? (value as Record<string, unknown>) : {};
const text = (value: unknown, fallback = ""): string =>
  typeof value === "string" ? value : fallback;
const number = (value: unknown, fallback = 0): number =>
  typeof value === "number" && Number.isFinite(value) ? value : fallback;
const strings = (value: unknown): string[] =>
  Array.isArray(value) ? value.filter((part): part is string => typeof part === "string") : [];

export function normalizeLibrary(value: unknown): LibraryItem[] {
  const envelope = record(value);
  const values = Array.isArray(value) ? value : Array.isArray(envelope.items) ? envelope.items : [];
  return values.map((raw, index) => {
    const item = record(raw);
    const durationSeconds = number(
      item.durationSeconds,
      number(item.duration_seconds, number(item.runtimeSeconds, number(item.runtime_minutes) * 60)),
    );
    const positionSeconds = number(
      item.positionSeconds,
      number(item.progress_seconds, (durationSeconds * number(item.percentComplete)) / 100),
    );
    const asin = text(item.asin);
    const provider = text(item.provider, "audible").toLowerCase();
    return {
      id: text(item.id, asin || `book-${index}`),
      ...(asin ? { asin } : {}),
      title: text(item.title, "Untitled audiobook"),
      authors: strings(item.authors),
      narrators: strings(item.narrators),
      durationSeconds,
      positionSeconds,
      ...(text(item.coverUrl, text(item.cover_url))
        ? { coverUrl: text(item.coverUrl, text(item.cover_url)) }
        : {}),
      ...(text(item.localPath, text(item.local_path))
        ? { localPath: text(item.localPath, text(item.local_path)) }
        : {}),
      ...(text(item.description) ? { description: text(item.description) } : {}),
      ...(text(item.releaseDate, text(item.release_date))
        ? { releaseDate: text(item.releaseDate, text(item.release_date)) }
        : {}),
      downloaded: item.downloaded === true,
      provider,
      ...(text(item.account) ? { account: text(item.account) } : {}),
      streamable: item.streamable === true,
      downloadable:
        typeof item.downloadable === "boolean" ? item.downloadable : provider === "audible",
    };
  });
}

export function normalizeDownloads(value: unknown): DownloadJob[] {
  const envelope = record(value);
  const values = Array.isArray(value)
    ? value
    : Array.isArray(envelope.jobs)
      ? envelope.jobs
      : Array.isArray(envelope.items)
        ? envelope.items
        : [];
  return values.map((raw, index) => {
    const job = record(raw);
    const state = text(job.state, "queued");
    return {
      jobId: text(job.jobId, text(job.id, `job-${index}`)),
      itemId: text(job.itemId, text(job.asin)),
      title: text(job.title, "Audiobook download"),
      state: (["queued", "active", "completed", "failed", "cancelled"].includes(state)
        ? state
        : "failed") as DownloadJob["state"],
      received: number(job.received),
      total: typeof job.total === "number" ? job.total : null,
      ...(text(job.error) ? { error: text(job.error) } : {}),
    };
  });
}

/** Keep already-downloaded books visible after transfer job files are pruned. */
export function mergeCompletedDownloads(
  jobs: DownloadJob[],
  library: readonly LibraryItem[],
): DownloadJob[] {
  const represented = new Set(jobs.map((job) => job.itemId));
  const completed = library
    .filter((item) => item.downloaded && !represented.has(item.id))
    .map(
      (item): DownloadJob => ({
        jobId: `library:${item.id}`,
        itemId: item.id,
        title: item.title,
        state: "completed",
        received: 1,
        total: 1,
      }),
    );
  return [...jobs, ...completed];
}

export function normalizePlayer(value: unknown): Partial<PlayerState> {
  const player = record(value);
  const state = text(player.state);
  const bookmarks = Array.isArray(player.bookmarks)
    ? player.bookmarks.flatMap((raw, index) => {
        const bookmark = record(raw);
        return [
          {
            id:
              typeof bookmark.id === "number" && Number.isInteger(bookmark.id)
                ? String(bookmark.id)
                : text(bookmark.id, `bookmark-${index}`),
            positionSeconds: number(bookmark.positionSeconds),
            label: text(bookmark.label, `Bookmark ${index + 1}`),
          },
        ];
      })
    : [];
  const sleepTimerMode =
    player.sleepTimerMode === "duration" || player.sleepTimerMode === "chapter"
      ? player.sleepTimerMode
      : null;
  const chapters = Array.isArray(player.chapters)
    ? player.chapters.flatMap((raw, index) => {
        const chapter = record(raw);
        const title = text(chapter.title, `Chapter ${index + 1}`);
        return [
          {
            index: number(chapter.index, index),
            title,
            startSeconds: number(chapter.startSeconds, number(chapter.start_seconds)),
          },
        ];
      })
    : [];
  return {
    ...(typeof player.itemId === "string" ? { itemId: player.itemId } : {}),
    ...(typeof player.title === "string" ? { title: player.title } : {}),
    ...(typeof player.chapter === "string" || typeof player.chapter === "number"
      ? { chapter: String(player.chapter) }
      : {}),
    positionSeconds: number(player.positionSeconds, number(player.timePosition)),
    durationSeconds: number(player.durationSeconds, number(player.duration)),
    paused: typeof player.paused === "boolean" ? player.paused : state === "paused",
    speed: number(player.speed, 1),
    volume: number(player.volume, 100),
    ...(Array.isArray(player.bookmarks) ? { bookmarks } : {}),
    ...(Array.isArray(player.chapters) ? { chapters } : {}),
    sleepTimerSeconds:
      typeof player.sleepTimerSeconds === "number" ? number(player.sleepTimerSeconds) : null,
    sleepTimerMode,
    ended: state === "ended" || player.ended === true,
  };
}
