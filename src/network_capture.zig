const std = @import("std");
const sdk = @import("moon_plugin");
const native = @import("native");

const capacity = 160;
pub const page_size = 16;
const url_limit = 280;
const Row = struct {
    id: u64,
    url: [url_limit]u8,
    len: usize,
    status: u16,
    kind: sdk.NetworkEventKind,
    elapsed_ms: u64,
    truncated: bool,
};
var rows: [capacity]Row = undefined;
var used: usize = 0;
var head: usize = 0;
var serial: u64 = 0;
var dropped: u64 = 0;
var started: u64 = 0;
var source_tab: u64 = 0;
var panel_tab: u64 = 0;
var owner: [96:0]u8 = @splat(0);
var source_view: ?*native.MoonView = null;
var recording = false;

pub fn ownerId() ?[]const u8 {
    return if (panel_tab != 0) std.mem.sliceTo(&owner, 0) else null;
}

pub fn reset() void {
    _ = setRecording(false);
    source_view = null;
    source_tab = 0;
    panel_tab = 0;
    clear();
}

pub fn closed(tab: u64) void {
    if (tab == source_tab or tab == panel_tab) reset();
}

pub fn begin(id: []const u8, source: u64, panel: u64, view: *native.MoonView) bool {
    reset();
    @memcpy(owner[0..id.len], id);
    owner[id.len] = 0;
    source_tab = source;
    panel_tab = panel;
    source_view = view;
    started = native.moon_clock();
    return setRecording(true);
}

pub fn sourceFor(panel: u64, id: []const u8) ?u64 {
    const active_owner = ownerId() orelse return null;
    if (panel != panel_tab or !std.mem.eql(u8, active_owner, id)) return null;
    return source_tab;
}

pub fn setRecording(enable: bool) bool {
    if (recording == enable) return true;
    const view = source_view orelse return false;
    if (!native.moon_engine_network_capture(view, enable)) return false;
    recording = enable;
    return true;
}

pub fn clear() void {
    head = 0;
    used = 0;
    dropped = 0;
}

pub fn add(view: *native.MoonView, token: u64, raw: []const u8, code: u16, kind: sdk.NetworkEventKind) void {
    if (!recording or source_view != view or source_tab != token) return;
    const scheme: usize = if (std.mem.startsWith(u8, raw, "https://")) 8
        else if (std.mem.startsWith(u8, raw, "http://")) 7 else return;
    const end = std.mem.indexOfAny(u8, raw, "?#") orelse raw.len;
    const rest = raw[scheme..end];
    const authority_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host = if (std.mem.lastIndexOfScalar(u8, rest[0..authority_end], '@')) |at| at + 1 else 0;
    if (host >= authority_end or !std.unicode.utf8ValidateSlice(rest[host..])) return;
    const safe = rest[host..];
    var len = @min(safe.len, url_limit - scheme);
    while (len < safe.len and safe[len] & 0xc0 == 0x80) len -= 1;

    const row = &rows[head];
    serial += 1;
    row.id = serial;
    @memcpy(row.url[0..scheme], raw[0..scheme]);
    @memcpy(row.url[scheme..][0..len], safe[0..len]);
    row.len = scheme + len;
    row.status = code;
    row.kind = kind;
    row.elapsed_ms = native.moon_clock() -| started;
    row.truncated = len != safe.len;
    head = (head + 1) % capacity;
    if (used < capacity) used += 1 else dropped += 1;
}

pub fn address(id: u64) ?[]const u8 {
    for (0..used) |offset| {
        const row = &rows[(head + capacity - offset - 1) % capacity];
        if (row.id == id and !row.truncated) return row.url[0..row.len];
    }
    return null;
}

pub fn list(panel: u64, id: []const u8, query: sdk.NetworkCaptureQuery, output: *[page_size]sdk.NetworkCaptureEvent) sdk.NetworkCapturePage {
    if (sourceFor(panel, id) == null) return .{};
    var len: usize = 0;
    var next: ?u64 = null;
    for (0..used) |offset| {
        const row = &rows[(head + capacity - offset - 1) % capacity];
        if (query.before) |before| if (row.id >= before) continue;
        const url = row.url[0..row.len];
        if (query.search.len != 0 and std.ascii.findIgnoreCase(url, query.search) == null) continue;
        if (query.kind) |kind| if (row.kind != kind) continue;
        if (query.failures and row.kind != .failed and row.status < 400) continue;
        if (len == page_size) {
            next = output[len - 1].id;
            break;
        }
        output[len] = .{
            .id = row.id, .url = url, .status = if (row.status != 0) row.status else null,
            .kind = row.kind, .elapsedMs = row.elapsed_ms, .truncated = row.truncated,
        };
        len += 1;
    }
    return .{
        .state = if (recording) .recording else .paused,
        .events = output[0..len],
        .retained = used,
        .dropped = dropped,
        .next = next,
    };
}
