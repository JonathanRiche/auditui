import { describe, expect, test } from "bun:test";
import { initialState, reducer } from "../src/app/state";
import { detailCoverGeometry, selectedCoverSource, trustedCoverSource } from "../src/screens/cover";

const item = (coverUrl: string) => ({
  id: "book",
  title: "Book",
  authors: [],
  narrators: [],
  durationSeconds: 1,
  positionSeconds: 0,
  downloaded: false,
  coverUrl,
});

describe("cover image selection", () => {
  test("grows the cover on roomy panes while retaining a compact layout", () => {
    expect(detailCoverGeometry(80, 24)).toMatchObject({ width: 24, height: 12 });
    expect(detailCoverGeometry(120, 40)).toMatchObject({ width: 44, height: 22 });
  });

  test("shows a selected Audible/Amazon CDN cover in detail view", () => {
    let state = reducer(initialState(), {
      type: "library.loaded",
      items: [item("https://m.media-amazon.com/images/I/example.jpg")],
    });
    expect(selectedCoverSource(state)).toBeNull();
    state = reducer(state, { type: "navigate", screen: "detail" });
    expect(selectedCoverSource(state)).toBe("https://m.media-amazon.com/images/I/example.jpg");
  });

  test("rejects local, insecure, and arbitrary image sources", () => {
    for (const source of [
      "file:///etc/passwd",
      "/tmp/cover.jpg",
      "http://m.media-amazon.com/images/I/example.jpg",
      "https://example.com/cover.jpg",
      "not a URL",
    ]) {
      let state = reducer(initialState(), { type: "library.loaded", items: [item(source)] });
      state = reducer(state, { type: "navigate", screen: "detail" });
      expect(selectedCoverSource(state)).toBeNull();
    }
  });

  test("accepts trusted artwork outside the detail screen for library tiles", () => {
    expect(trustedCoverSource("https://m.media-amazon.com/images/I/tile.jpg")).toBe(
      "https://m.media-amazon.com/images/I/tile.jpg",
    );
  });
});
