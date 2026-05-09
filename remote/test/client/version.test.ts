import test from "node:test";
import assert from "node:assert/strict";

import { WEB_VERSION, webVersionLabel } from "../../src/client/version";

test("web version is exposed for the remote UI", () => {
  assert.equal(WEB_VERSION, "v0.16.0");
  assert.equal(webVersionLabel(), "Web v0.16.0");
});
