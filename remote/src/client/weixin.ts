import { maskSessionKey } from "./storage";

export type WeixinSettings = {
  enabled: boolean;
  target_session: string;
  reply_timeout_ms: number;
};

export type WeixinBindingSummary = {
  bound: boolean;
  user_id?: string;
  account_id?: string;
  base_url?: string;
  bound_at?: string;
};

export type WeixinSettingsResponse = {
  settings: WeixinSettings;
  binding: WeixinBindingSummary;
  sessions: Array<{ key: string; connected: boolean }>;
};

export type WeixinBindStartResponse = {
  qrcode: string;
  qrcode_content: string;
  qrcode_data_url: string;
  status: string;
};

async function weixinApi(path: string, init?: RequestInit): Promise<Response> {
  const { api } = await import("./transport");
  return api(path, init);
}

export function normalizeWeixinSettings(input: Partial<WeixinSettings>): WeixinSettings {
  return {
    enabled: input.enabled === true,
    target_session: String(input.target_session ?? "").trim(),
    reply_timeout_ms: Number.isFinite(input.reply_timeout_ms) ? Number(input.reply_timeout_ms) : 60000,
  };
}

export function bridgeStatusText(settings: WeixinSettings, binding: WeixinBindingSummary): string {
  const parts = [settings.enabled ? "Weixin bridge enabled" : "Weixin bridge disabled"];
  parts.push(binding.bound ? `bound to ${binding.user_id || binding.account_id || "Weixin"}` : "not bound");
  if (settings.target_session) parts.push(`target ${maskSessionKey(settings.target_session)}`);
  return parts.join(" · ");
}

export async function fetchWeixinSettings(): Promise<WeixinSettingsResponse> {
  const res = await weixinApi("/api/weixin/settings");
  if (!res.ok) throw new Error("Failed to load Weixin settings");
  return (await res.json()) as WeixinSettingsResponse;
}

export async function saveWeixinSettings(settings: WeixinSettings): Promise<WeixinSettingsResponse> {
  const res = await weixinApi("/api/weixin/settings", { method: "PUT", body: JSON.stringify(settings) });
  if (!res.ok) throw new Error("Failed to save Weixin settings");
  return (await res.json()) as WeixinSettingsResponse;
}

export async function startWeixinBind(): Promise<WeixinBindStartResponse> {
  const res = await weixinApi("/api/weixin/bind/start", { method: "POST" });
  if (!res.ok) throw new Error("Failed to start Weixin binding");
  return (await res.json()) as WeixinBindStartResponse;
}

export async function pollWeixinBindStatus(
  qrcode: string,
): Promise<{ status: string; message?: string; binding: WeixinBindingSummary }> {
  const res = await weixinApi(`/api/weixin/bind/status?qrcode=${encodeURIComponent(qrcode)}`);
  if (!res.ok) throw new Error("Failed to poll Weixin binding");
  return (await res.json()) as { status: string; message?: string; binding: WeixinBindingSummary };
}

export async function unbindWeixin(): Promise<void> {
  const res = await weixinApi("/api/weixin/bind", { method: "DELETE" });
  if (!res.ok) throw new Error("Failed to unbind Weixin");
}
