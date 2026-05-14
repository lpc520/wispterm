import test from "node:test";
import assert from "node:assert/strict";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";

import { WeixinClient } from "../../src/server/bridge/weixin/client.js";

type ServerHandler = (req: IncomingMessage, res: ServerResponse) => void;

async function withServer(handler: ServerHandler) {
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
  let bodyText = "";
  let body: unknown = null;
  const server = await withServer((req, res) => {
    assert.equal(req.url, "/ilink/bot/sendmessage");
    req.on("data", (chunk) => { bodyText += chunk; });
    req.on("end", () => {
      body = JSON.parse(bodyText);
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

test("WeixinClient treats missing sendmessage ret as success", async () => {
  let body: unknown = null;
  let bodyText = "";
  const server = await withServer((req, res) => {
    assert.equal(req.url, "/ilink/bot/sendmessage");
    req.on("data", (chunk) => { bodyText += chunk; });
    req.on("end", () => {
      body = JSON.parse(bodyText);
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify({}));
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

test("WeixinClient throws for explicit nonzero sendmessage ret", async () => {
  const server = await withServer((req, res) => {
    assert.equal(req.url, "/ilink/bot/sendmessage");
    req.on("data", () => {});
    req.on("end", () => {
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify({ ret: 42, errcode: 7, message: "denied" }));
    });
  });
  try {
    const client = new WeixinClient({ baseUrl: server.baseUrl, token: "secret" });
    await assert.rejects(
      () => client.sendTextMessage("user@im.wechat", "hello", "ctx"),
      /sendmessage ret=42 errcode=7: denied/,
    );
  } finally {
    await server.close();
  }
});

test("WeixinClient polls QR status with encoded qrcode and app client version header", async () => {
  let seenUrl = "";
  let appClientVersion = "";
  let authType = "";
  const server = await withServer((req, res) => {
    seenUrl = req.url ?? "";
    appClientVersion = String(req.headers["ilink-app-clientversion"] ?? "");
    authType = String(req.headers.authorizationtype ?? "");
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ ret: 0, status: "wait" }));
  });
  try {
    const client = new WeixinClient({ baseUrl: server.baseUrl, token: "secret" });
    const status = await client.getQRCodeStatus("qr session");
    assert.deepEqual(status, { ret: 0, status: "wait" });
    assert.equal(seenUrl, "/ilink/bot/get_qrcode_status?qrcode=qr%20session");
    assert.equal(appClientVersion, "1");
    assert.equal(authType, "ilink_bot_token");
  } finally {
    await server.close();
  }
});
