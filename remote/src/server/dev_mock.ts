export const LOCAL_MOCK_PASSWORD_HASH =
  "sha256:5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8";

const LOCAL_MOCK_SESSION_SIGNING_SECRET =
  "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

export function applyLocalMockEnv(env: Record<string, string | undefined> = process.env): void {
  env.ADMIN_USERNAME ??= "admin";
  env.ADMIN_PASSWORD_HASH ??= LOCAL_MOCK_PASSWORD_HASH;
  env.SESSION_SIGNING_SECRET ??= LOCAL_MOCK_SESSION_SIGNING_SECRET;
  env.REMOTE_COOKIE_SECURE ??= "false";
  env.HOST ??= "127.0.0.1";
  env.PORT ??= "8787";
}
