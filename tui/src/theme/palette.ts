import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

export interface AppPalette {
  background: string;
  surface: string;
  surfaceRaised: string;
  panel: string;
  border: string;
  borderStrong: string;
  foreground: string;
  muted: string;
  subtle: string;
  accent: string;
  accentSoft: string;
  success: string;
  danger: string;
}

export interface ThemeEnvironment {
  HOME?: string;
  XDG_STATE_HOME?: string;
  AUDIBLE_TUI_THEME?: string;
  AUDIBLE_TUI_THEME_FILE?: string;
  AUDIBLE_TUI_MONOCHROME?: string;
  NO_COLOR?: string;
}

export interface LoadedTheme {
  name: string;
  path: string | null;
  palette: AppPalette;
}

export const fallbackPalette: AppPalette = {
  background: "#131416",
  surface: "#1b1c1f",
  surfaceRaised: "#222327",
  panel: "#1b1c1f",
  border: "#36373c",
  borderStrong: "#55565d",
  foreground: "#f4eee5",
  muted: "#aaa39a",
  subtle: "#77736e",
  accent: "#e7a94b",
  accentSoft: "#553b1d",
  success: "#83b879",
  danger: "#e57b72",
};

export function monochromePalette(source: AppPalette): AppPalette {
  return {
    ...source,
    surface: mix(source.background, source.foreground, 0.06),
    surfaceRaised: mix(source.background, source.foreground, 0.13),
    panel: mix(source.background, source.foreground, 0.06),
    border: mix(source.background, source.foreground, 0.24),
    borderStrong: mix(source.background, source.foreground, 0.48),
    muted: mix(source.background, source.foreground, 0.68),
    subtle: mix(source.background, source.foreground, 0.5),
    accent: source.foreground,
    accentSoft: mix(source.background, source.foreground, 0.25),
    success: source.foreground,
    danger: source.foreground,
  };
}

const hexColor = /^#[0-9a-f]{6}$/i;

/** Parse Omarchy's intentionally flat colors.toml format without adding a TOML dependency. */
export function parseOmarchyColors(source: string): Record<string, string> {
  const colors: Record<string, string> = {};
  for (const rawLine of source.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#") || line.startsWith("[")) continue;
    const match = line.match(/^([A-Za-z0-9_]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})["']?\s*(?:#.*)?$/);
    if (match) colors[match[1]!] = match[2]!.toLowerCase();
  }
  return colors;
}

function color(colors: Record<string, string>, keys: string[], fallback: string): string {
  for (const key of keys) {
    const value = colors[key];
    if (value && hexColor.test(value)) return value.toLowerCase();
  }
  return fallback;
}

function mix(from: string, to: string, amount: number): string {
  const channel = (value: string, offset: number) =>
    Number.parseInt(value.slice(offset, offset + 2), 16);
  const blend = (a: number, b: number) =>
    Math.round(a + (b - a) * amount)
      .toString(16)
      .padStart(2, "0");
  return `#${blend(channel(from, 1), channel(to, 1))}${blend(channel(from, 3), channel(to, 3))}${blend(channel(from, 5), channel(to, 5))}`;
}

export function paletteFromOmarchy(colors: Record<string, string>): AppPalette | null {
  const background = color(colors, ["background", "bg", "color0"], "");
  const foreground = color(colors, ["foreground", "fg", "color7"], "");
  const accent = color(colors, ["accent", "blue", "color4"], "");
  if (!background || !foreground || !accent) return null;

  const surface = color(colors, ["lighter_bg"], mix(background, foreground, 0.055));
  const surfaceRaised = color(
    colors,
    ["selection_background", "selection", "active_tab_background"],
    mix(background, foreground, 0.11),
  );
  const border = color(
    colors,
    ["muted", "color8", "hyprland_inactive_border"],
    mix(background, foreground, 0.2),
  );
  const borderStrong = color(colors, ["dark_fg"], mix(background, foreground, 0.38));
  const muted = color(colors, ["dark_fg", "color8"], mix(background, foreground, 0.64));
  const subtle = color(colors, ["muted", "color8"], mix(background, foreground, 0.46));

  return {
    background,
    surface,
    surfaceRaised,
    panel: surface,
    border,
    borderStrong,
    foreground: color(
      colors,
      ["bright_fg", "selection_foreground", "foreground", "fg", "color15"],
      foreground,
    ),
    muted,
    subtle,
    accent,
    accentSoft: mix(background, accent, 0.32),
    success: color(colors, ["green", "color2", "bright_green", "color10"], fallbackPalette.success),
    danger: color(colors, ["red", "color1", "bright_red", "color9"], fallbackPalette.danger),
  };
}

export function activeOmarchyThemePath(
  env: ThemeEnvironment = process.env as ThemeEnvironment,
): string | null {
  if (env.AUDIBLE_TUI_THEME_FILE) return env.AUDIBLE_TUI_THEME_FILE;
  if (env.AUDIBLE_TUI_THEME?.toLowerCase() === "default") return null;
  const stateHome = env.XDG_STATE_HOME || (env.HOME ? join(env.HOME, ".local", "state") : null);
  return stateHome ? join(stateHome, "omarchy", "current", "theme", "colors.toml") : null;
}

export function loadActiveTheme(
  env: ThemeEnvironment = process.env as ThemeEnvironment,
): LoadedTheme {
  const accessible = (value: LoadedTheme): LoadedTheme =>
    env.AUDIBLE_TUI_MONOCHROME === "1" || env.NO_COLOR !== undefined
      ? { ...value, name: `${value.name} monochrome`, palette: monochromePalette(value.palette) }
      : value;
  const path = activeOmarchyThemePath(env);
  if (!path || !existsSync(path))
    return accessible({ name: "Audible", path: null, palette: { ...fallbackPalette } });
  try {
    const mapped = paletteFromOmarchy(parseOmarchyColors(readFileSync(path, "utf8")));
    if (!mapped)
      return accessible({ name: "Audible", path: null, palette: { ...fallbackPalette } });
    const namePath = join(path, "..", "..", "theme.name");
    const name = existsSync(namePath) ? readFileSync(namePath, "utf8").trim() : "Omarchy";
    return accessible({ name: name || "Omarchy", path, palette: mapped });
  } catch {
    return accessible({ name: "Audible", path: null, palette: { ...fallbackPalette } });
  }
}

let activeTheme = loadActiveTheme();
export const palette: AppPalette = { ...activeTheme.palette };
export const currentTheme = (): LoadedTheme => activeTheme;

function paletteSignature(value: AppPalette): string {
  return Object.values(value).join(":");
}

/** Polling survives Omarchy atomically replacing the active theme directory. */
export function watchActiveTheme(
  onChange: (theme: LoadedTheme) => void,
  env: ThemeEnvironment = process.env as ThemeEnvironment,
  intervalMs = 750,
): () => void {
  let signature = paletteSignature(activeTheme.palette);
  const timer = setInterval(() => {
    const next = loadActiveTheme(env);
    // A missing/half-written file during `omarchy theme set` must not flash the fallback theme.
    if (!next.path) return;
    const nextSignature = paletteSignature(next.palette);
    if (nextSignature === signature) return;
    signature = nextSignature;
    activeTheme = next;
    Object.assign(palette, next.palette);
    onChange(next);
  }, intervalMs);
  timer.unref?.();
  return () => clearInterval(timer);
}
