export const MOBILE_REMOTE_MEDIA_QUERY =
  "(max-width: 860px), (pointer: coarse) and (max-width: 1024px)";
export const REMOTE_VISUAL_VIEWPORT_HEIGHT_VAR = "--remote-visual-viewport-height";
export const REMOTE_VISUAL_VIEWPORT_OFFSET_TOP_VAR = "--remote-visual-viewport-offset-top";

export type SurfaceFitMode = "remote-grid" | "viewport";
type VisualViewportSizingWindow = Pick<Window, "innerHeight"> & {
  visualViewport?: Pick<VisualViewport, "height" | "offsetTop"> | null;
};

export function fitModeForSurface(hasRemoteGridDimensions: boolean): SurfaceFitMode {
  return hasRemoteGridDimensions ? "remote-grid" : "viewport";
}

export function shouldUseViewportFit(hasRemoteGridDimensions: boolean): boolean {
  return fitModeForSurface(hasRemoteGridDimensions) === "viewport";
}

export function shouldUseCanvasPan(
  hasRemoteGridDimensions: boolean,
  win: Pick<Window, "matchMedia"> = window,
): boolean {
  return hasRemoteGridDimensions || isMobileRemoteShell(win);
}

export function isMobileRemoteShell(win: Pick<Window, "matchMedia"> = window): boolean {
  return win.matchMedia(MOBILE_REMOTE_MEDIA_QUERY).matches;
}

export function applyVisualViewportSizing(
  root: Pick<HTMLElement, "style"> | null,
  win: VisualViewportSizingWindow = window,
): void {
  if (!root) return;

  const viewport = win.visualViewport;
  const rawHeight = isPositiveFiniteNumber(viewport?.height) ? viewport.height : win.innerHeight;
  const height = isPositiveFiniteNumber(rawHeight) ? rawHeight : 0;
  const rawOffsetTop = isFiniteNumber(viewport?.offsetTop) ? viewport.offsetTop : 0;

  root.style.setProperty(REMOTE_VISUAL_VIEWPORT_HEIGHT_VAR, `${height}px`);
  root.style.setProperty(REMOTE_VISUAL_VIEWPORT_OFFSET_TOP_VAR, `${Math.max(0, rawOffsetTop)}px`);
}

function isPositiveFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value > 0;
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}
