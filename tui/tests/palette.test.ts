import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  activeOmarchyThemePath,
  fallbackPalette,
  loadActiveTheme,
  watchActiveTheme,
  paletteFromOmarchy,
  parseOmarchyColors,
} from "../src/theme/palette";

const temporaryDirectories: string[] = [];
afterEach(() => {
  for (const directory of temporaryDirectories.splice(0))
    rmSync(directory, { recursive: true, force: true });
});

describe("Omarchy theme integration", () => {
  test("parses the flat Omarchy palette and ignores unrelated TOML", () => {
    expect(
      parseOmarchyColors(`
# comment
mode = "dark"
background = "#101216"
foreground='#D3D7DD'
accent = "#ad2222" # supported trailing comment
[ignored]
bad = "red"
`),
    ).toEqual({ background: "#101216", foreground: "#d3d7dd", accent: "#ad2222" });
  });

  test("maps extended Omarchy roles into the complete application palette", () => {
    const mapped = paletteFromOmarchy(
      parseOmarchyColors(`
background = "#101010"
foreground = "#eeeeee"
bright_fg = "#ffffff"
accent = "#ff8800"
lighter_bg = "#181818"
selection_background = "#303030"
muted = "#555555"
dark_fg = "#999999"
green = "#00cc66"
red = "#ff3344"
`),
    );
    expect(mapped).toMatchObject({
      background: "#101010",
      surface: "#181818",
      surfaceRaised: "#303030",
      foreground: "#ffffff",
      muted: "#999999",
      subtle: "#555555",
      accent: "#ff8800",
      success: "#00cc66",
      danger: "#ff3344",
    });
  });

  test("follows XDG state paths, supports overrides, and falls back outside Omarchy", () => {
    const root = mkdtempSync(join(tmpdir(), "audible-theme-"));
    temporaryDirectories.push(root);
    const themeDirectory = join(root, "omarchy", "current", "theme");
    mkdirSync(themeDirectory, { recursive: true });
    writeFileSync(join(root, "omarchy", "current", "theme.name"), "Test Light\n");
    writeFileSync(
      join(themeDirectory, "colors.toml"),
      `background="#fafafa"\nforeground="#202020"\naccent="#3366cc"\n`,
    );

    const env = { XDG_STATE_HOME: root };
    expect(activeOmarchyThemePath(env)).toBe(join(themeDirectory, "colors.toml"));
    expect(loadActiveTheme(env)).toMatchObject({
      name: "Test Light",
      path: join(themeDirectory, "colors.toml"),
    });
    expect(loadActiveTheme(env).palette.background).toBe("#fafafa");
    expect(loadActiveTheme({ ...env, AUDIBLE_TUI_THEME: "default" }).palette).toEqual(
      fallbackPalette,
    );
    const monochrome = loadActiveTheme({ ...env, AUDIBLE_TUI_MONOCHROME: "1" });
    expect(monochrome.name).toContain("monochrome");
    expect(monochrome.palette.accent).toBe(monochrome.palette.foreground);
    expect(monochrome.palette.success).toBe(monochrome.palette.foreground);
    expect(monochrome.palette.danger).toBe(monochrome.palette.foreground);
  });

  test("hot reloads a replaced active palette without restarting", async () => {
    const root = mkdtempSync(join(tmpdir(), "audible-theme-watch-"));
    temporaryDirectories.push(root);
    const themeDirectory = join(root, "omarchy", "current", "theme");
    mkdirSync(themeDirectory, { recursive: true });
    const colorsPath = join(themeDirectory, "colors.toml");
    writeFileSync(colorsPath, `background="#111111"\nforeground="#eeeeee"\naccent="#1122aa"\n`);

    let changes = 0;
    let resolveSecondChange!: () => void;
    const secondChange = new Promise<void>((resolve) => {
      resolveSecondChange = resolve;
    });
    const stop = watchActiveTheme(
      (theme) => {
        changes += 1;
        if (changes === 1) {
          writeFileSync(
            colorsPath,
            `background="#111111"\nforeground="#eeeeee"\naccent="#cc4400"\n`,
          );
        } else if (theme.palette.accent === "#cc4400") {
          resolveSecondChange();
        }
      },
      { XDG_STATE_HOME: root },
      10,
    );

    await Promise.race([
      secondChange,
      Bun.sleep(1_000).then(() => {
        throw new Error("theme watcher did not reload");
      }),
    ]);
    stop();
    expect(changes).toBeGreaterThanOrEqual(2);
  });
});
