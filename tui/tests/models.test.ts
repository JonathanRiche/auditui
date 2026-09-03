import { describe, expect, test } from "bun:test";
import {
  mergeCompletedDownloads,
  normalizeDownloads,
  normalizeLibrary,
  normalizePlayer,
} from "../src/engine/models";

describe("engine model compatibility", () => {
  test("normalizes provider accounts and media capabilities", () => {
    const [item] = normalizeLibrary({
      items: [
        {
          id: "yoto-1",
          title: "Bedtime Story",
          provider: "YOTO",
          account: "kids-room",
          streamable: true,
          downloadable: false,
        },
      ],
    });
    expect(item).toMatchObject({
      provider: "yoto",
      account: "kids-room",
      streamable: true,
      downloadable: false,
    });
  });
  test("normalizes Zig cache field names", () => {
    const [item] = normalizeLibrary({
      items: [
        {
          asin: "B001",
          title: "Dune",
          authors: ["Frank Herbert"],
          narrators: ["Simon Vance"],
          runtime_minutes: 100,
          progress_seconds: 120,
          cover_url: "https://example.invalid/cover.jpg",
          local_path: "/library/Dune.m4b",
          downloaded: true,
        },
      ],
    });
    expect(item).toMatchObject({
      id: "B001",
      durationSeconds: 6000,
      positionSeconds: 120,
      downloaded: true,
      localPath: "/library/Dune.m4b",
    });
  });

  test("normalizes protocol fixture field names", () => {
    const [item] = normalizeLibrary({
      items: [{ asin: "B002", title: "Example", runtimeSeconds: 3600, percentComplete: 25 }],
    });
    expect(item).toMatchObject({ durationSeconds: 3600, positionSeconds: 900 });
    expect(
      normalizePlayer({ state: "paused", timePosition: 12, duration: 50, chapter: 3 }),
    ).toMatchObject({
      paused: true,
      positionSeconds: 12,
      durationSeconds: 50,
      chapter: "3",
    });
  });

  test("accepts both downloads result envelope names", () => {
    expect(normalizeDownloads({ items: [] })).toEqual([]);
    expect(
      normalizeDownloads({ jobs: [{ id: "j1", state: "active", received: 1, total: 2 }] })[0],
    ).toMatchObject({ jobId: "j1", state: "active" });
  });

  test("keeps downloaded library items visible after completed job files are pruned", () => {
    const library = normalizeLibrary({
      items: [
        { asin: "owned", title: "Owned", downloaded: true, localPath: "/books/owned.m4b" },
        { asin: "online", title: "Online", downloaded: false },
      ],
    });
    expect(mergeCompletedDownloads([], library)).toEqual([
      {
        jobId: "library:owned",
        itemId: "owned",
        title: "Owned",
        state: "completed",
        received: 1,
        total: 1,
      },
    ]);
    const real = {
      jobId: "owned",
      itemId: "owned",
      title: "Owned",
      state: "completed" as const,
      received: 42,
      total: 42,
    };
    expect(mergeCompletedDownloads([real], library)).toEqual([real]);
  });

  test("normalizes bookmarks, chapters, and structured sleep timers", () => {
    expect(
      normalizePlayer({
        bookmarks: [{ id: 7, positionSeconds: 42, label: "The reveal" }],
        chapters: [{ index: 1, title: "The reveal", start_seconds: 40 }],
        sleepTimerSeconds: 900,
        sleepTimerMode: "duration",
      }),
    ).toMatchObject({
      bookmarks: [{ id: "7", positionSeconds: 42, label: "The reveal" }],
      chapters: [{ index: 1, title: "The reveal", startSeconds: 40 }],
      sleepTimerSeconds: 900,
      sleepTimerMode: "duration",
    });
  });
});
