export const WEIXIN_DEFAULT_BASE_URL = "https://ilinkai.weixin.qq.com";
export const WEIXIN_BOT_TYPE = "3";
export const WEIXIN_CHANNEL_VERSION = "1.0.2";

export type WeixinBaseInfo = { channel_version: string };

export type WeixinQRCodeResponse = {
  ret: number;
  qrcode?: string;
  qrcode_img_content?: string;
  message?: string;
};

export type WeixinQRCodeStatusResponse = {
  ret: number;
  status?: "wait" | "scaned" | "confirmed" | "expired" | string;
  bot_token?: string;
  baseurl?: string;
  ilink_bot_id?: string;
  ilink_user_id?: string;
  message?: string;
};

export type WeixinMessageItem = {
  type?: number;
  text_item?: { text?: string };
  voice_item?: { text?: string };
};

export type WeixinMessage = {
  from_user_id?: string;
  to_user_id?: string;
  client_id?: string;
  message_type?: number;
  message_state?: number;
  context_token?: string;
  group_id?: string;
  item_list?: WeixinMessageItem[];
};

export type WeixinGetUpdatesResponse = {
  ret: number;
  msgs?: WeixinMessage[];
  get_updates_buf?: string;
  longpolling_timeout_ms?: number;
  errcode?: number;
  message?: string;
};

export type WeixinSendMessageResponse = {
  ret?: number;
  errcode?: number;
  message?: string;
};

export type WeixinBindingRecord = {
  token: string;
  base_url: string;
  user_id: string;
  account_id: string;
  bound_at: string;
};

export type WeixinSettings = {
  enabled: boolean;
  target_session: string;
  reply_timeout_ms: number;
};
