import test from "node:test";
import assert from "node:assert/strict";

import {
  readSavedDesktopPanelMode,
  readSavedSidebarCollapsed,
  saveDesktopPanelMode,
  saveSidebarCollapsed,
} from "../../src/client/storage";

const store = new Map<string, string>();

test("sidebar collapsed preference round-trips through storage", () => {
  installLocalStorage();

  saveSidebarCollapsed(true);
  assert.equal(readSavedSidebarCollapsed(), true);

  saveSidebarCollapsed(false);
  assert.equal(readSavedSidebarCollapsed(), false);
});

test("sidebar collapsed preference is nullable when unset", () => {
  installLocalStorage();

  assert.equal(readSavedSidebarCollapsed(), null);
});

test("desktop panel mode preference round-trips through storage", () => {
  installLocalStorage();

  assert.equal(readSavedDesktopPanelMode(), "layout");

  saveDesktopPanelMode("single");
  assert.equal(readSavedDesktopPanelMode(), "single");

  saveDesktopPanelMode("layout");
  assert.equal(readSavedDesktopPanelMode(), "layout");
});

test("desktop panel mode ignores invalid stored values", () => {
  installLocalStorage();

  store.set("phantty.remote.desktopPanelMode", "wide");

  assert.equal(readSavedDesktopPanelMode(), "layout");
});

function installLocalStorage(): void {
  store.clear();
  Object.defineProperty(globalThis, "localStorage", {
    configurable: true,
    value: {
      getItem(key: string): string | null {
        return store.get(key) ?? null;
      },
      setItem(key: string, value: string): void {
        store.set(key, value);
      },
    },
  });
}
