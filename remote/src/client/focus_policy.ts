import { isMobileRemoteShell } from "./mobile_layout";

export function shouldFocusTerminalElement(): boolean {
  return !isMobileRemoteShell();
}
