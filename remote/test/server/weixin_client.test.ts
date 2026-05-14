import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";

import { WeixinClient } from "../../src/server/bridge/weixin/client";

async function withServer(handler: Parameters<typeof createServer>[0]) {
  const server = createServer(handler);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("missing server address");
  return {
    baseUrl: `http://127.0.0.1:${address.port}`,
    close: () => new Promise<void>((resolve) => server.close(() => resolve())),
  };
}

test("WeixinClient requests QR code with bot_type 3", async () => {
  const seen: string[] = [];
  const server = await withServer((req, res) => {
    seen.push(req.url ?? "");
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ ret: 0, qrcode: "qr-session", qrcode_img_content: "qr-content" }));
  });
  try {
    const client = new WeixinClient({ baseUrl: server.baseUrl, token: "" });
    const qr = await client.getQRCode();
    assert.deepEqual(qr, { ret: 0, qrcode: "qr-session", qrcode_img_content: "qr-content" });
    assert.equal(seen[0], "/ilink/bot/get_bot_qrcode?bot_type=3");
  } finally {
    await server.close();
  }
});

test("WeixinClient posts getupdates with auth headers", async () => {
  let auth = "";
  let authType = "";
  let bodyText = "";
  const server = await withServer((req, res) => {
    auth = req.headers.authorization ?? "";
    authType = String(req.headers.authorizationtype ?? "");
    req.on("data", (chunk) => { bodyText += chunk; });
    req.on("end", () => {
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify({ ret: 0, msgs: [], get_updates_buf: "next" }));
    });
  });
  try {
    const client = new WeixinClient({ baseUrl: server.baseUrl, token: "secret" });
    const updates = await client.getUpdates("cursor");
    assert.equal(auth, "Bearer secret");
    assert.equal(authType, "ilink_bot_token");
    assert.equal(JSON.parse(bodyText).get_updates_buf, "cursor");
    assert.equal(updates.get_updates_buf, "next");
  } finally {
    await server.close();
  }
});

test("WeixinClient sends text messages through sendmessage", async () => {
  let body: unknown = null;
  const server = await withServer((req, res) => {
    assert.equal(req.url, "/ilink/bot/sendmessage");
    req.on("data", (chunk) => { body = JSON.parse(String(chunk)); });
    req.on("end", () => {
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify({ ret: 0 }));
    });
  });
  try {
    const client = new WeixinClient({ baseUrl: server.baseUrl, token: "secret" });
    await client.sendTextMessage("user@im.wechat", "hello", "ctx");
    assert.equal((body as { msg: { to_user_id: string } }).msg.to_user_id, "user@im.wechat");
  } finally {
    await server.close();
  }
});
