import { activeSurfaceIdForInput, state } from "./state";

const kbdMods = { ctrl: false, alt: false };

type Sender = (surfaceId: string, data: string) => void;
let sender: Sender = () => {
  // no-op until transport registers
};

export function setVirtualKeyboardSender(send: Sender): void {
  sender = send;
}

export function renderVirtualKeyboardMarkup(): string {
  const key = (attrs: string, label: string, cls = ""): string =>
    `<button type="button" class="vkbd-key${cls ? ` ${cls}` : ""}" ${attrs}>${label}</button>`;
  return `
    <section class="vkbd" id="vkbd" data-mod-ctrl="false" data-mod-alt="false">
      <div class="vkbd-rows">
        <div class="vkbd-row">
          ${key('data-vk-key="esc"', "Esc")}
          ${key('data-vk-key="tab"', "Tab")}
          ${key('data-vk-mod="ctrl" data-active="false"', "Ctrl", "vkbd-mod")}
          ${key('data-vk-mod="alt" data-active="false"', "Alt", "vkbd-mod")}
          ${key('data-vk-key="up"', "↑")}
          ${key('data-vk-key="left"', "←")}
          ${key('data-vk-key="down"', "↓")}
          ${key('data-vk-key="right"', "→")}
        </div>
        <div class="vkbd-row">
          ${key('data-vk-text="|"', "|")}
          ${key('data-vk-text="\\"', "\\")}
          ${key('data-vk-text="/"', "/")}
          ${key('data-vk-text="~"', "~")}
          ${key('data-vk-text="\`"', "`")}
          ${key('data-vk-text="-"', "-")}
          ${key('data-vk-text="_"', "_")}
          ${key('data-vk-text="="', "=")}
          ${key('data-vk-text="*"', "*")}
        </div>
        <div class="vkbd-row">
          ${key('data-vk-ctrl="c"', "^C", "vkbd-pill")}
          ${key('data-vk-ctrl="d"', "^D", "vkbd-pill")}
          ${key('data-vk-ctrl="l"', "^L", "vkbd-pill")}
          ${key('data-vk-ctrl="r"', "^R", "vkbd-pill")}
          ${key('data-vk-ctrl="z"', "^Z", "vkbd-pill")}
          ${key('data-vk-key="bksp"', "⌫")}
          ${key('data-vk-key="enter"', "⏎")}
          ${key('data-vk-key="type"', "Type", "vkbd-wide")}
        </div>
      </div>
    </section>
  `;
}

export function bindVirtualKeyboard(onHide: () => void): void {
  const vkbd = document.querySelector<HTMLElement>("#vkbd");
  if (!vkbd) return;

  const keepFocus = (event: Event) => event.preventDefault();

  vkbd.querySelectorAll<HTMLButtonElement>(".vkbd-key").forEach((button) => {
    button.addEventListener("mousedown", keepFocus);
    button.addEventListener("touchstart", keepFocus, { passive: false });
    button.addEventListener("click", (event) => {
      event.preventDefault();
      dispatchVirtualKey(button, onHide);
    });
  });
}

function dispatchVirtualKey(button: HTMLButtonElement, onHide: () => void): void {
  const vkbd = document.querySelector<HTMLElement>("#vkbd");
  if (!vkbd) return;

  if (button.dataset.vkMod) {
    const mod = button.dataset.vkMod as "ctrl" | "alt";
    kbdMods[mod] = !kbdMods[mod];
    button.dataset.active = String(kbdMods[mod]);
    vkbd.dataset[mod === "ctrl" ? "modCtrl" : "modAlt"] = String(kbdMods[mod]);
    return;
  }

  const surfaceId = activeSurfaceIdForInput();
  if (!surfaceId) return;

  if (button.dataset.vkKey === "type") {
    state.surfaceViews.get(surfaceId)?.term.focus();
    return;
  }

  if (button.dataset.vkKey === "hide") {
    onHide();
    return;
  }

  if (button.dataset.vkCtrl) {
    const letter = button.dataset.vkCtrl.toLowerCase();
    if (letter.length === 1 && letter >= "a" && letter <= "z") {
      sender(surfaceId, String.fromCharCode(letter.charCodeAt(0) - 96));
    }
    return;
  }

  if (button.dataset.vkText !== undefined) {
    let text = button.dataset.vkText;
    if (kbdMods.ctrl && text.length === 1) {
      const lower = text.toLowerCase();
      if (lower >= "a" && lower <= "z") {
        text = String.fromCharCode(lower.charCodeAt(0) - 96);
      }
    } else if (kbdMods.alt && text.length === 1) {
      text = `\x1b${text}`;
    }
    sender(surfaceId, text);
    clearStickyMods();
    return;
  }

  if (button.dataset.vkKey) {
    const seq = keyToSequence(button.dataset.vkKey);
    if (seq) sender(surfaceId, seq);
  }
}

function keyToSequence(key: string): string | null {
  switch (key) {
    case "esc":
      return "\x1b";
    case "tab":
      return "\t";
    case "up":
      return "\x1b[A";
    case "down":
      return "\x1b[B";
    case "right":
      return "\x1b[C";
    case "left":
      return "\x1b[D";
    case "bksp":
      return "\x7f";
    case "enter":
      return "\r";
    default:
      return null;
  }
}

function clearStickyMods(): void {
  if (!kbdMods.ctrl && !kbdMods.alt) return;
  kbdMods.ctrl = false;
  kbdMods.alt = false;
  const vkbd = document.querySelector<HTMLElement>("#vkbd");
  if (vkbd) {
    vkbd.dataset.modCtrl = "false";
    vkbd.dataset.modAlt = "false";
    vkbd.querySelectorAll<HTMLButtonElement>("[data-vk-mod]").forEach((btn) => {
      btn.dataset.active = "false";
    });
  }
}
