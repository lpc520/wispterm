//! Owns the WeChat direct lifecycle: persisted binding, the ilink client, and
//! the background poller. Built by App with a live Control. This module is
//! platform-neutral (no GUI deps) so it compiles and is checkable off-Windows;
//! the GUI parts live in App/AppWindow and the QR panel.
const std = @import("std");
const types = @import("types.zig");
const state_store = @import("state_store.zig");
const ilink = @import("ilink_client.zig");
const poller = @import("poller.zig");
const control_mod = @import("control.zig");

pub const Controller = struct {
    allocator: std.mem.Allocator,
    state_path: []u8,
    control: control_mod.Control,
    settings: types.Settings,

    // Heap-owned copies of the active binding. Empty slices mean "unset".
    token: []u8 = &.{},
    base_url: []u8 = &.{},
    owner: []u8 = &.{},
    bot_id: []u8 = &.{},

    // Live while running. `client` must outlive `poll` (poll holds a ClientApi
    // pointing at it); both are fields of this heap object so addresses are stable.
    client: ilink.Client = undefined,
    poll: poller.Poller = undefined,
    running: bool = false,

    pub fn create(
        allocator: std.mem.Allocator,
        state_path: []const u8,
        control: control_mod.Control,
        settings: types.Settings,
    ) !*Controller {
        const self = try allocator.create(Controller);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .state_path = try allocator.dupe(u8, state_path),
            .control = control,
            .settings = settings,
        };
        return self;
    }

    pub fn destroy(self: *Controller) void {
        self.stop();
        self.clearBinding();
        self.allocator.free(self.state_path);
        self.allocator.destroy(self);
    }

    /// Loads the persisted binding; if a token exists, starts polling.
    pub fn start(self: *Controller) !void {
        var loaded = try state_store.load(self.allocator, self.state_path);
        defer loaded.deinit(self.allocator);
        if (loaded.binding.bot_token.len == 0) return; // not logged in yet
        try self.startWithBinding(loaded.binding);
    }

    /// Stops the poller, persisting the latest sync cursor so the next start
    /// resumes where it left off.
    pub fn stop(self: *Controller) void {
        if (!self.running) return;
        self.poll.stop();
        // Persist the advanced sync cursor (best-effort).
        self.persist(self.poll.sync_buf) catch {};
        self.allocator.free(self.poll.sync_buf);
        // ilink.Client holds no persistent resources (it opens a fresh
        // std.http.Client per request), so there is nothing to deinit here.
        self.running = false;
    }

    /// Clears the persisted owner + token and stops. Used by "Unbind".
    pub fn unbind(self: *Controller) !void {
        self.stop();
        self.clearBinding();
        try self.persistBinding(.{});
    }

    // --- login (driven by the QR panel) ---

    /// Step 1 of login: fetch a QR code. The returned value borrows from `arena`.
    pub fn beginLogin(self: *Controller, arena: std.mem.Allocator) !types.QrCode {
        var client = ilink.Client.init(self.allocator, self.configuredBaseUrl(), "");
        return client.getBotQrcode(arena);
    }

    /// Step 2 of login: poll a QR code's status. Borrows from `arena`.
    pub fn pollLogin(self: *Controller, arena: std.mem.Allocator, qrcode: []const u8) !types.QrStatus {
        var client = ilink.Client.init(self.allocator, self.configuredBaseUrl(), "");
        return client.getQrcodeStatus(arena, qrcode);
    }

    /// Step 3: a confirmed QR status carries the bot_token; persist and start.
    pub fn confirmLogin(self: *Controller, status: types.QrStatus) !void {
        if (status.status != .confirmed or status.bot_token.len == 0) return error.NotConfirmed;
        const binding = types.Binding{
            .bot_token = status.bot_token,
            .base_url = if (status.base_url.len != 0) status.base_url else self.configuredBaseUrl(),
            // owner is auto-bound from the first inbound 1:1 message, unless the
            // config pins an allowed user (settings.allowed_user).
            .owner_user_id = self.settings.allowed_user,
            .bot_id = status.bot_id,
            .sync_buf = "",
        };
        try self.persistBinding(binding);
        try self.startWithBinding(binding);
    }

    // --- internals ---

    fn configuredBaseUrl(self: *Controller) []const u8 {
        return if (self.base_url.len != 0) self.base_url else ilink_default_base_url;
    }

    fn startWithBinding(self: *Controller, binding: types.Binding) !void {
        if (self.running) return;
        try self.setBinding(binding);

        self.client = ilink.Client.init(self.allocator, self.base_url, self.token);
        self.poll = .{
            .allocator = self.allocator,
            .client = self.client.api(),
            .control = self.control,
            .settings = self.settings,
            .owner = self.owner,
            .account_id = self.bot_id,
            .sync_buf = try self.allocator.dupe(u8, binding.sync_buf),
        };
        try self.poll.start();
        self.running = true;
    }

    fn setBinding(self: *Controller, b: types.Binding) !void {
        const token = try self.allocator.dupe(u8, b.bot_token);
        errdefer self.allocator.free(token);
        const base_url = try self.allocator.dupe(u8, b.base_url);
        errdefer self.allocator.free(base_url);
        const owner = try self.allocator.dupe(u8, b.owner_user_id);
        errdefer self.allocator.free(owner);
        const bot_id = try self.allocator.dupe(u8, b.bot_id);
        errdefer self.allocator.free(bot_id);

        self.clearBinding();
        self.token = token;
        self.base_url = base_url;
        self.owner = owner;
        self.bot_id = bot_id;
    }

    fn clearBinding(self: *Controller) void {
        freeOwned(self.allocator, &self.token);
        freeOwned(self.allocator, &self.base_url);
        freeOwned(self.allocator, &self.owner);
        freeOwned(self.allocator, &self.bot_id);
    }

    fn persist(self: *Controller, sync_buf: []const u8) !void {
        try self.persistBinding(.{
            .bot_token = self.token,
            .base_url = self.base_url,
            .owner_user_id = self.owner,
            .bot_id = self.bot_id,
            .sync_buf = sync_buf,
        });
    }

    fn persistBinding(self: *Controller, binding: types.Binding) !void {
        try state_store.save(self.allocator, self.state_path, binding);
    }
};

const ilink_default_base_url = @import("ilink_codec.zig").DEFAULT_BASE_URL;

fn freeOwned(allocator: std.mem.Allocator, slot: *[]u8) void {
    if (slot.len != 0) allocator.free(slot.*);
    slot.* = &.{};
}

const t = std.testing;

// A no-op Control used to exercise controller lifetime without a GUI.
const NoopControl = struct {
    fn is_connected(_: *anyopaque) bool {
        return false;
    }
    fn find_ai_surface(_: *anyopaque) ?control_mod.Surface {
        return null;
    }
    fn find_terminal_surface(_: *anyopaque) ?control_mod.Surface {
        return null;
    }
    fn open_ai_agent(_: *anyopaque, _: u32) control_mod.OpenResult {
        return .offline;
    }
    fn send_input(_: *anyopaque, _: [16]u8, _: []const u8) bool {
        return false;
    }
    fn latest_transcript(_: *anyopaque) []const u8 {
        return "";
    }
    var dummy: u8 = 0;
    fn iface() control_mod.Control {
        return .{ .ctx = &dummy, .vtable = &.{
            .is_connected = is_connected,
            .find_ai_surface = find_ai_surface,
            .find_terminal_surface = find_terminal_surface,
            .open_ai_agent = open_ai_agent,
            .send_input = send_input,
            .latest_transcript = latest_transcript,
        } };
    }
};

test "create/start without a persisted token stays idle, destroy is clean" {
    const path = "zig-cache-tmp-weixin-ctrl.json";
    defer std.fs.cwd().deleteFile(path) catch {};

    const ctrl = try Controller.create(t.allocator, path, NoopControl.iface(), .{});
    defer ctrl.destroy();

    try ctrl.start(); // no token file → no poller spawned
    try t.expect(!ctrl.running);
}
