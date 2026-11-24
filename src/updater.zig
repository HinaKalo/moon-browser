const std = @import("std");
const native = @import("native");
const manifest = @import("update_manifest.zig");

const Version = struct { name: []const u8, code: u64, windows_version: []const u8 };
const Mode = enum { development, portable, installer };
const State = enum(u8) { idle, checking, current, ready, unavailable, rejected, download_failed };
const channel = "preview";
const app = "moon-browser";
const interval_ms = 6 * 60 * 60 * 1000;

var mode: Mode = .development;
var state: std.atomic.Value(State) = .init(.idle);
var installed: u64 = 0;
var version: [65:0]u8 = @splat(0);
var target: manifest.Package = undefined;
var next_check: u64 = 0;
var announced: u64 = 0;
var requested = false;
var probe_log: [4096:0]u8 = @splat(0);

pub fn configure(app_dir: []const u8, now: u64) void {
    var memory: [1024]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&memory);
    const parsed = std.json.parseFromSlice(Version, allocator.allocator(), @embedFile("version.json"), .{}) catch return;
    defer parsed.deinit();
    if (parsed.value.name.len >= version.len or parsed.value.code == 0) return;
    installed = parsed.value.code;
    @memcpy(version[0..parsed.value.name.len], parsed.value.name);
    var path: [4096]u8 = undefined;
    const marker = std.fmt.bufPrintSentinel(&path, "{s}\\release-mode", .{app_dir}, 0) catch return;
    var marker_text: [32]u8 = undefined;
    if (!native.moon_read_text(marker.ptr, &marker_text, marker_text.len)) return;
    const value = std.mem.trim(u8, std.mem.sliceTo(&marker_text, 0), " \r\n");
    mode = std.meta.stringToEnum(Mode, value) orelse .development;
    if (mode != .development) next_check = now + 12000;
}

// The release probe only exercises signed downloads from the normal origin.
pub fn configureProbe(log_file: []const u8, kind: []const u8, code: u64) bool {
    const new_mode = std.meta.stringToEnum(Mode, kind) orelse return false;
    if (new_mode == .development or code == 0 or log_file.len == 0 or log_file.len >= probe_log.len) return false;
    if (std.mem.indexOfScalar(u8, log_file, 0) != null) return false;
    @memcpy(probe_log[0..log_file.len], log_file);
    mode = new_mode;
    installed = code;
    next_check = 1;
    return true;
}

fn platform() []const u8 {
    return if (mode == .portable) "win-x64-portable" else "win-x64-installer";
}

fn check() State {
    var path_buffer: [256]u8 = undefined;
    const check_path = std.fmt.bufPrintSentinel(&path_buffer, "/v1/apps/{s}/check?platform={s}&channel={s}&versionCode={d}", .{ app, platform(), channel, installed }, 0) catch return .rejected;
    var body: [65536]u8 = undefined;
    var length: usize = 0;
    switch (native.moon_update_read(check_path.ptr, &body, body.len, &length)) {
        200 => {},
        404 => return .current,
        else => return .unavailable,
    }
    const package = (manifest.parse(body[0..length], .{
        .app = app,
        .platform = platform(),
        .channel = channel,
        .suffix = if (mode == .portable) ".zip" else ".exe",
    }, installed) catch return .rejected) orelse return .current;
    const download_path = std.fmt.bufPrintSentinel(&path_buffer, "/v1/apps/{s}/{s}/releases/{d}/download", .{ app, platform(), package.code }, 0) catch return .rejected;
    if (!native.moon_update_download(download_path.ptr, mode == .portable, package.size, &package.hash))
        return .download_failed;
    target = package;
    return .ready;
}

export fn moon_update_worker() void {
    state.store(check(), .release);
}

fn start(now: u64) void {
    if (state.load(.acquire) == .checking) return;
    next_check = now + interval_ms;
    state.store(.checking, .release);
    if (!native.moon_update_thread()) state.store(.unavailable, .release);
}

fn finished(status: State) bool {
    return status != .idle and status != .checking;
}

pub fn tick(now: u64) void {
    if (mode == .development) return;
    const status = state.load(.acquire);
    if (probe_log[0] != 0 and finished(status)) {
        var buffer: [512]u8 = undefined;
        const line = if (status == .ready)
            std.fmt.bufPrintSentinel(&buffer, "ready {s} {d} {s}\n", .{ platform(), target.code, std.mem.sliceTo(&target.filename, 0) }, 0) catch unreachable
        else
            std.fmt.bufPrintSentinel(&buffer, "{s} {s}\n", .{ @tagName(status), platform() }, 0) catch unreachable;
        native.moon_log(&probe_log, line.ptr);
        native.moon_quit(if (status == .ready or status == .current) 0 else 1);
        return;
    }
    if (requested and finished(status)) {
        requested = false;
        report(status, true);
    } else if (status == .ready and target.code != announced) {
        announced = target.code;
        report(status, false);
    }
    if (now >= next_check) start(now);
}

pub fn open(now: u64) void {
    if (mode == .development) {
        native.moon_shell_info("版本与更新", "此开发构建无需联网更新。请使用正式发布的便携版或安装版。");
        return;
    }
    const status = state.load(.acquire);
    if (status == .ready) {
        report(status, true);
        return;
    }
    requested = true;
    start(now);
    native.moon_shell_info("版本与更新", "正在检查更新。发现新版本后将在后台下载并校验。");
}

fn report(status: State, interactive: bool) void {
    switch (status) {
        .ready => {
            const package = target;
            announced = package.code;
            var buffer: [512]u8 = undefined;
            const hint = if (!interactive)
                "可在「版本与更新」中查看。"
            else if (mode == .portable)
                "现在打开更新包所在文件夹？"
            else
                "现在关闭浏览器并启动安装程序？";
            const text = std.fmt.bufPrintSentinel(&buffer, "已下载并验证 {s}。{s}", .{ std.mem.sliceTo(&package.version, 0), hint }, 0) catch return;
            if (!interactive) {
                native.moon_shell_info("版本与更新", text.ptr);
            } else if (native.moon_shell_confirm("版本与更新", text.ptr)) {
                if (!native.moon_update_open(mode == .portable, package.size, &package.hash)) {
                    native.moon_shell_info("版本与更新", "无法打开完整的更新包。请重新检查并下载。");
                    if (state.load(.acquire) == .ready and target.code == package.code) state.store(.download_failed, .release);
                } else if (mode == .installer) native.moon_quit(0);
            }
        },
        .current => {
            var buffer: [140]u8 = undefined;
            const message = std.fmt.bufPrintSentinel(&buffer, "当前版本 {s} 已是最新。", .{std.mem.sliceTo(&version, 0)}, 0) catch return;
            native.moon_shell_info("版本与更新", message.ptr);
        },
        .unavailable => native.moon_shell_info("版本与更新", "无法连接 Moon 发布中心，请稍后重试。"),
        .rejected => native.moon_shell_info("版本与更新", "更新清单未通过签名或渠道校验。"),
        .download_failed => native.moon_shell_info("版本与更新", "更新下载或完整性校验失败，请稍后重试。"),
        else => {},
    }
}
