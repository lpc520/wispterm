import { applyLocalMockEnv } from "./dev_mock.js";

applyLocalMockEnv();
await import("./index.js");
