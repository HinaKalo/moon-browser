const std = @import("std");
const native = @import("native");
const sdk = @import("moon_plugin");
const history = @import("history.zig");
const recent_tabs = @import("recent_tabs.zig");
const site_data = @import("site_data.zig");
const userscripts = @import("userscripts.zig");

var owner: [96:0]u8 = @splat(0);
var confirming = false;
var waiting: c_uint = 0;
var began: u64 = 0;
var failed: sdk.PrivacySelection = .{};

pub fn status(plugin_id: []const u8) sdk.PrivacyStatus {
    if (!std.mem.eql(u8, std.mem.sliceTo(&owner, 0), plugin_id)) return .{ .state = .idle };
    return .{
        .state = if (waiting != 0)
            if (native.moon_clock() -| began >= 30_000) .waitingForEngine else .running
        else if (failed.history or failed.siteData or failed.cache) .incomplete else .complete,
        .failed = failed,
    };
}

pub fn start(selection: sdk.PrivacySelection, tab: u64, plugin_id: [:0]const u8, consent: userscripts.Consent) sdk.PrivacyStart {
    if (confirming or waiting != 0) return .busy;
    if (plugin_id.len >= owner.len or !native.moon_privacy_allowed(tab, plugin_id.ptr)) return .unavailable;
    var buffer: [640]u8 = undefined;
    const detail = std.fmt.bufPrintSentinel(&buffer, "永久清除当前浏览器配置文件中所选项目的全部时间记录？\n{s}{s}{s}", .{
        if (selection.history) "\n· 浏览历史和最近关闭的标签" else "",
        if (selection.siteData) "\n· Cookie 和持久站点数据。网站可能会退出登录。" else "",
        if (selection.cache) "\n· 网页缓存文件" else "",
    }, 0) catch return .unavailable;
    confirming = true;
    defer confirming = false;
    if (!native.moon_shell_confirm("清除浏览数据？", detail.ptr)) return .cancelled;
    if (!consent.valid(consent.context) or !native.moon_privacy_allowed(tab, plugin_id.ptr)) return .unavailable;

    @memcpy(owner[0..plugin_id.len], plugin_id);
    owner[plugin_id.len] = 0;
    failed = .{};
    began = native.moon_clock();
    if (selection.history) {
        history.clear() catch {
            failed.history = true;
        };
        if (!failed.history) recent_tabs.clear();
    }
    if (selection.siteData) site_data.reset();
    const requested: c_uint = (if (selection.siteData) @as(c_uint, native.MOON_ERASE_SITE) else 0) |
        (if (selection.cache) @as(c_uint, native.MOON_ERASE_CACHE) else 0);
    waiting = requested;
    if (requested != 0) {
        const accepted = native.moon_engine_erase_data(requested);
        waiting &= accepted;
        failed.siteData = selection.siteData and accepted & native.MOON_ERASE_SITE == 0;
        failed.cache = selection.cache and accepted & native.MOON_ERASE_CACHE == 0;
    }
    return .started;
}

export fn moon_privacy_engine_done(category: c_uint) void {
    if (category == native.MOON_ERASE_SITE) site_data.reset();
    waiting &= ~category;
}
