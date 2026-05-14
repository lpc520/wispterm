import test from "node:test";
import assert from "node:assert/strict";

import { shouldFocusTerminalElement } from "../../src/client/focus_policy";

function setMobileShell(mobile: boolean): void {
  Object.defineProperty(globalThis, "window", {
    configurable: true,
    value: {
      matchMedia: () => ({ matches: mobile }),
    },
  });
}

test("terminal focus policy suppresses native input focus on mobile", () => {
  setMobileShell(true);

  assert.equal(shouldFocusTerminalElement(), false);
});

test("terminal focus policy allows native input focus on desktop", () => {
  setMobileShell(false);

  assert.equal(shouldFocusTerminalElement(), true);
});
