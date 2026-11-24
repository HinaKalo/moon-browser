const std = @import("std");
const sdk = @import("moon_plugin");
const native = @import("native");

const allocator = std.heap.page_allocator;
const chunk_size = 12 * 1024;
var snapshot: sdk.PageSourceStatus = .{};
var generation: u64 = 0;
var source_tab: u64 = 0;
var panel_tab: u64 = 0;
var deadline: u64 = 0;
var owner: [96]u8 = undefined;
var owner_len: usize = 0;
var address: [4096]u8 = undefined;
var captured: ?[]u8 = null;

fn drop() void {
    if (captured) |bytes| allocator.free(bytes);
    captured = null;
    snapshot.url = "";
    snapshot.bytes = 0;
    snapshot.truncated = false;
    source_tab = 0;
}

pub fn reset() void {
    drop();
    snapshot = .{};
    owner_len = 0;
    panel_tab = 0;
}

pub fn invalidate(tab: u64) void {
    if (source_tab != tab) return;
    drop();
    snapshot.state = .stale;
}

pub fn closed(tab: u64) void {
    if (panel_tab == tab) reset() else invalidate(tab);
}

pub fn ownerId() ?[]const u8 {
    return if (owner_len == 0) null else owner[0..owner_len];
}

pub fn begin(id: []const u8, source: u64, panel: u64, url: []const u8, view: *native.MoonView) void {
    reset();
    generation += 1;
    source_tab = source;
    panel_tab = panel;
    @memcpy(owner[0..id.len], id);
    owner_len = id.len;
    @memcpy(address[0..url.len], url);
    snapshot = .{ .state = .pending, .generation = generation, .url = address[0..url.len] };
    deadline = native.moon_clock() + 5000;
    if (!native.moon_engine_page_source(view, generation)) snapshot.state = .unavailable;
}

pub fn complete(request: u64, raw: ?[]const u8) void {
    if (snapshot.state != .pending or snapshot.generation != request) return;
    snapshot.state = .unavailable;
    const bytes = raw orelse return;
    var size = @min(bytes.len, native.MOON_SOURCE_LIMIT);
    while (size < bytes.len and bytes[size] & 0xc0 == 0x80) size -= 1;
    captured = allocator.dupe(u8, bytes[0..size]) catch return;
    snapshot.state = .ready;
    snapshot.bytes = size;
    snapshot.truncated = size < bytes.len;
}

pub fn tick(now: u64) void {
    if (snapshot.state == .pending and now >= deadline) snapshot.state = .unavailable;
}

fn owns(tab: u64, id: []const u8) bool {
    return tab != 0 and tab == panel_tab and std.mem.eql(u8, owner[0..owner_len], id);
}

pub fn status(tab: u64, id: []const u8) sdk.PageSourceStatus {
    return if (owns(tab, id)) snapshot else .{};
}

pub fn read(tab: u64, id: []const u8, query: sdk.PageSourceQuery) ?struct { bytes: []const u8, next: ?usize } {
    if (!owns(tab, id) or query.generation != snapshot.generation) return null;
    const bytes = captured orelse return null;
    if (query.offset >= bytes.len) return null;
    const end = @min(bytes.len, query.offset + chunk_size);
    return .{ .bytes = bytes[query.offset..end], .next = if (end == bytes.len) null else end };
}
