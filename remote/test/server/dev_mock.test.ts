import test from "node:test";
import assert from "node:assert/strict";

import {
  LOCAL_MOCK_PASSWORD_HASH,
  applyLocalMockEnv,
} from "../../src/server/dev_mock.js";

test("local mock env provides admin password login defaults", () => {
  const env: Record<string, string | undefined> = {};

  applyLocalMockEnv(env);

  assert.equal(env.ADMIN_USERNAME, "admin");
  assert.equal(env.ADMIN_PASSWORD_HASH, LOCAL_MOCK_PASSWORD_HASH);
  assert.equal(env.SESSION_SIGNING_SECRET, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
  assert.equal(env.REMOTE_COOKIE_SECURE, "false");
  assert.equal(env.HOST, "127.0.0.1");
  assert.equal(env.PORT, "8787");
});

test("local mock env preserves explicit overrides", () => {
  const env: Record<string, string | undefined> = {
    ADMIN_USERNAME: "dev",
    ADMIN_PASSWORD_HASH: "sha256:custom",
    SESSION_SIGNING_SECRET: "secret",
    REMOTE_COOKIE_SECURE: "true",
    HOST: "0.0.0.0",
    PORT: "9000",
  };

  applyLocalMockEnv(env);

  assert.deepEqual(env, {
    ADMIN_USERNAME: "dev",
    ADMIN_PASSWORD_HASH: "sha256:custom",
    SESSION_SIGNING_SECRET: "secret",
    REMOTE_COOKIE_SECURE: "true",
    HOST: "0.0.0.0",
    PORT: "9000",
  });
});
