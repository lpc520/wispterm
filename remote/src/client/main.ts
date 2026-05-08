import "@xterm/xterm/css/xterm.css";
import "./styles.css";

import { setSurfaceInputHandler } from "./surfaces";
import { kickReconnectIfIdle, loadMe, sendInputBytes, setTransportHooks } from "./transport";
import { setVirtualKeyboardSender } from "./vkbd";
import {
  renderConsole,
  renderNotices,
  renderRemoteWorkspace,
  setStatus,
  updateInputUi,
} from "./views/console";
import { renderLogin } from "./views/login";

const appRoot = document.querySelector<HTMLElement>("#app");
if (!appRoot) {
  throw new Error("Missing app root");
}
const app: HTMLElement = appRoot;

setSurfaceInputHandler(sendInputBytes);
setVirtualKeyboardSender(sendInputBytes);
setTransportHooks({
  onWorkspaceChanged: renderRemoteWorkspace,
  onNoticesChanged: renderNotices,
  onInputUiChanged: updateInputUi,
  setStatus,
});

window.addEventListener("online", kickReconnectIfIdle);
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") kickReconnectIfIdle();
});

void loadMe().then((me) => {
  if (me.authenticated) showConsole();
  else showLogin();
});

function showLogin(): void {
  renderLogin(app, showConsole);
}

function showConsole(): void {
  renderConsole(app, showLogin);
}
