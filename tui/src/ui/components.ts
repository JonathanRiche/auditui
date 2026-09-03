import {
  BoxRenderable,
  StyledText,
  TextRenderable,
  bold,
  dim,
  fg,
  stringToStyledText,
  t,
} from "@opentui/core";
import type { RenderContext, TextOptions } from "@opentui/core";
import { palette } from "../theme/palette";

export type Copy = string | StyledText;

export function concat(...parts: Copy[]): StyledText {
  return new StyledText(
    parts.flatMap((part) =>
      typeof part === "string" ? stringToStyledText(part).chunks : part.chunks,
    ),
  );
}

export function text(
  ctx: RenderContext,
  id: string,
  content: Copy,
  options: Partial<TextOptions> = {},
): TextRenderable {
  return new TextRenderable(ctx, {
    id,
    content,
    height: 1,
    fg: palette.foreground,
    bg: palette.background,
    wrapMode: "none",
    selectable: false,
    ...options,
  });
}

export function sectionTitle(label: string, count?: number): StyledText {
  return t`${bold(fg(palette.foreground)(label))}${count === undefined ? "" : dim(fg(palette.muted)(`  ${count}`))}`;
}

export function statusCopy(online: boolean, label: string): StyledText {
  return online
    ? t`${fg(palette.success)("●")} ${fg(palette.muted)(label)}`
    : t`${fg(palette.danger)("○")} ${fg(palette.muted)(label)}`;
}

export function panel(ctx: RenderContext, id: string, raised = false): BoxRenderable {
  return new BoxRenderable(ctx, {
    id,
    width: "100%",
    backgroundColor: raised ? palette.surfaceRaised : palette.surface,
    shouldFill: true,
  });
}

export function progress(value: number, total: number, width: number): StyledText {
  const ratio = total > 0 ? Math.max(0, Math.min(1, value / total)) : 0;
  const filled = Math.round(ratio * width);
  return t`${fg(palette.accent)("━".repeat(filled))}${fg(palette.borderStrong)("─".repeat(Math.max(0, width - filled)))}`;
}
