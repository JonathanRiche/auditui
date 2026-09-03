import type { AppState } from "../app/types";

export interface CoverGeometry {
  left: number;
  top: number;
  width: number;
  height: number;
}

export function detailCoverGeometry(terminalWidth: number, terminalHeight: number): CoverGeometry {
  // Two terminal columns per row is approximately square in physical pixels.
  // Grow on roomy panes while preserving space for metadata and the player dock.
  const height = Math.max(
    8,
    Math.min(22, terminalHeight - 12, Math.floor((terminalWidth - 50) / 2)),
  );
  return { left: 4, top: 4, width: height * 2, height };
}

/**
 * Returns a remotely loadable cover only for the selected detail item.
 * Library metadata is untrusted: restricting hosts prevents file reads and
 * arbitrary network requests through OpenTUI's flexible ImageSource loader.
 */
export function selectedCoverSource(state: AppState): string | null {
  if (state.screen !== "detail") return null;
  return trustedCoverSource(state.visibleItems[state.selectedIndex]?.coverUrl);
}

/** Allows only Audible/Amazon HTTPS artwork in any view. */
export function trustedCoverSource(value?: string): string | null {
  if (!value) return null;
  try {
    const url = new URL(value);
    const host = url.hostname.toLowerCase();
    const trusted =
      host === "m.media-amazon.com" ||
      host.endsWith(".media-amazon.com") ||
      host.endsWith(".ssl-images-amazon.com");
    return url.protocol === "https:" && trusted ? url.href : null;
  } catch {
    return null;
  }
}
