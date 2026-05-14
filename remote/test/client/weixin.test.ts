import test from "node:test";
import assert from "node:assert/strict";

import { bridgeStatusText, normalizeWeixinSettings } from "../../src/client/weixin";

test("normalizeWeixinSettings applies defaults", () => {
  assert.deepEqual(normalizeWeixinSettings({}), {
    enabled: false,
    target_session: "",
    reply_timeout_ms: 60000,
  });
});

test("bridgeStatusText describes binding and target state", () => {
  assert.equal(
    bridgeStatusText(
      { enabled: true, target_session: "abcdef", reply_timeout_ms: 60000 },
      { bound: true, user_id: "user@im.wechat" },
    ),
    "Weixin bridge enabled · bound to user@im.wechat · target abcd****",
  );
});
