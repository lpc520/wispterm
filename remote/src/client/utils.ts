import type { LayoutSurface, RelayMessage } from "./types";

export function escapeText(value: string): string {
  return value.replace(/[&<>"']/g, (ch) => {
    switch (ch) {
      case "&":
        return "&amp;";
      case "<":
        return "&lt;";
      case ">":
        return "&gt;";
      case '"':
        return "&quot;";
      default:
        return "&#39;";
    }
  });
}

export function safeJson(data: string): RelayMessage | null {
  try {
    return JSON.parse(data) as RelayMessage;
  } catch {
    return null;
  }
}

export function decodeHex(hex: string): Uint8Array | null {
  if (hex.length % 2 !== 0) return null;
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i += 1) {
    const value = Number.parseInt(hex.slice(i * 2, i * 2 + 2), 16);
    if (Number.isNaN(value)) return null;
    bytes[i] = value;
  }
  return bytes;
}

export function encodeHex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function shortSurfaceId(id: string): string {
  return id.length > 6 ? id.slice(-6) : id;
}

export function numberOr(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

export function validNonNegativeInteger(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  const next = Math.floor(value);
  return next >= 0 ? next : null;
}

export function validPositiveInteger(value: unknown): number | null {
  const next = validNonNegativeInteger(value);
  return next !== null && next > 0 ? next : null;
}

export function cursorMoveSequence(surface: LayoutSurface): string {
  const x = validNonNegativeInteger(surface.cursorX);
  const y = validNonNegativeInteger(surface.cursorY);
  if (x === null || y === null) return "";
  return `\x1b[${y + 1};${x + 1}H`;
}

export function emptyState(text: string): HTMLDivElement {
  const node = document.createElement("div");
  node.className = "empty-state";
  node.textContent = text;
  return node;
}
