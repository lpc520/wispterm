import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { handleWeixinRoute } from "../../src/server/bridge/weixin/routes.js";
import { WeixinBindingStore } from "../../src/server/bridge/weixin/binding.js";

function fakeReq(method: string, path: string, body = "") {
  return {
    method,
    url: path,
    async *[Symbol.asyncIterator]() {
      if (body) yield Buffer.from(body);
    },
  };
}

function fakeRes() {
  const headers = new Map<string, string>();
  return {
    statusCode: 0,
    body: "",
    setHeader(name: string, value: string) {
      headers.set(name.toLowerCase(), value);
    },
    end(chunk: string) {
      this.body += chunk;
    },
    headers,
  };
}

test("GET /api/weixin/settings returns settings and binding summary", async () => {
  const dir = await mkdtemp(join(tmpdir(), "phantty-weixin-route-"));
  const store = new WeixinBindingStore(dir);
  await store.saveSettings({ enabled: true, target_session: "alpha", reply_timeout_ms: 60000 });
  const res = fakeRes();

  const handled = await handleWeixinRoute(fakeReq("GET", "/api/weixin/settings") as never, res as never, {
    store,
    createClient: () => {
      throw new Error("not used");
    },
    listSessions: () => [],
    restartPoller: () => {},
  });

  assert.equal(handled, true);
  assert.equal(res.statusCode, 200);
  assert.equal(JSON.parse(res.body).settings.enabled, true);
});
