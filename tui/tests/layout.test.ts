import { describe, expect, test } from "bun:test";
import { initialState, reducer } from "../src/app/state";
import { formatTime, progressBar, renderLayout } from "../src/screens/layout";

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

describe("responsive layouts", () => {
  test("renders a visual grid and persistent player at wide sizes", () => {
    let state = reducer(initialState(120, 36), {
      type: "library.loaded",
      items: [item, { ...item, id: "two", title: "Messiah" }],
    });
    state = reducer(state, {
      type: "player.status",
      player: {
        itemId: "dune",
        title: "Dune",
        chapter: "The Spice",
        durationSeconds: 75_600,
        positionSeconds: 1_200,
      },
    });
    const rendered = renderLayout(state);
    expect(rendered).toContain("Continue listening");
    expect(rendered).toContain("DUNE");
    expect(rendered).toContain("The Spice");
    expect(rendered.split("\n")).toHaveLength(36);
  });

  test("collapses to a narrow single-column shelf", () => {
    const state = reducer(initialState(80, 24), { type: "library.loaded", items: [item] });
    const rendered = renderLayout(state);
    expect(rendered).toContain("▶┌");
    expect(rendered).toContain("? help");
    expect(rendered.split("\n")).toHaveLength(24);
  });

  test("renders detail, downloads, and help states", () => {
    let state = reducer(initialState(80, 24), { type: "library.loaded", items: [item] });
    state = reducer(state, { type: "navigate", screen: "detail" });
    const detail = renderLayout(state);
    expect(detail).toContain("Narrated by Simon Vance");
    expect(detail).toContain("Listening progress");
    expect(detail).toContain("32% listened");
    expect(detail).toContain("Available offline");
    state = reducer(state, { type: "help.toggle" });
    expect(renderLayout(state)).toContain("Keyboard shortcuts");
  });

  test("formats timelines defensively", () => {
    expect(formatTime(3_661)).toBe("1:01:01");
    expect(progressBar(150, 100, 5)).toBe("━━━━━");
  });

  test("guides users through empty profile states", () => {
    let state = reducer(initialState(80, 24), { type: "library.loaded", items: [] });
    const onboarding = renderLayout(state);
    expect(onboarding).toContain("No Audible profile was detected");
    expect(onboarding).toContain("auditui auth login --country-code us");
    expect(onboarding).not.toContain("password=");
    state = reducer(state, { type: "profile.loaded", name: "Jonathan", secure: false });
    expect(renderLayout(state)).toContain("chmod 600");
    state = reducer(state, { type: "profile.loaded", name: "Jonathan", secure: true });
    const emptyLibrary = renderLayout(state);
    expect(emptyLibrary).toContain("local library cache is empty");
    expect(emptyLibrary).toContain("Press r to refresh");
    expect(emptyLibrary).toContain("auditui library refresh --profile Jonathan");
  });
});
