import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  selectedMobileSurfaceKind,
  shouldShowMobileVirtualKeyboard,
} from "../../src/client/mobile_surface_mode";
import type { LayoutState } from "../../src/client/types";

function layoutWith(surfaceKind: "terminal" | "ai_chat"): LayoutState {
  return {
    activeTab: 0,
    tabs: [
      {
        index: 0,
        title: surfaceKind === "ai_chat" ? "DeepSeek" : "Terminal",
        focusedSurfaceId: "surface-1",
        surfaces: [
          {
            id: "surface-1",
            kind: surfaceKind,
            title: "Surface",
            focused: true,
          },
        ],
      },
    ],
  };
}

describe("mobile surface mode", () => {
  it("detects the selected AI chat surface", () => {
    assert.equal(selectedMobileSurfaceKind(layoutWith("ai_chat"), 0, "surface-1"), "ai_chat");
  });

  it("treats terminal surfaces as terminal mode", () => {
    assert.equal(selectedMobileSurfaceKind(layoutWith("terminal"), 0, "surface-1"), "terminal");
  });

  it("falls back to the focused surface when no selected surface id is available", () => {
    assert.equal(selectedMobileSurfaceKind(layoutWith("ai_chat"), 0, null), "ai_chat");
  });

  it("only shows the mobile virtual keyboard for terminal surfaces", () => {
    assert.equal(shouldShowMobileVirtualKeyboard("terminal", true), true);
    assert.equal(shouldShowMobileVirtualKeyboard("ai_chat", true), false);
    assert.equal(shouldShowMobileVirtualKeyboard("none", true), false);
    assert.equal(shouldShowMobileVirtualKeyboard("terminal", false), false);
  });

  it("shows the shortcut keyboard from edit mode only when the key toggle is active", () => {
    assert.equal(shouldShowMobileVirtualKeyboard("terminal", true, "edit"), true);
    assert.equal(shouldShowMobileVirtualKeyboard("terminal", false, "edit"), false);
    assert.equal(shouldShowMobileVirtualKeyboard("terminal", true, "view"), false);
  });
});
