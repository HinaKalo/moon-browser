const std = @import("std");
const native = @import("native");
const sdk = @import("moon_plugin");

const allocator = std.heap.page_allocator;
const script = "(() => {\n" ++ @embedFile("readability_source") ++ "\n" ++ @embedFile("reader_extract.js") ++ "\n})()";
var status: sdk.ReaderStatus = .{};
var source: u64 = 0;
var panel: u64 = 0;
var serial: u64 = 0;
var deadline: u64 = 0;
var owner: [96]u8 = undefined;
var owner_len: usize = 0;
var address: [4096]u8 = undefined;
var captured: ?[]u8 = null;

fn clear() void {
    if (captured) |bytes| allocator.free(bytes);
    captured = null;
}

pub fn reset() void {
    clear();
    status = .{};
    source = 0;
    panel = 0;
    owner_len = 0;
}

pub fn ownerId() ?[]const u8 {
    return if (owner_len == 0) null else owner[0..owner_len];
}

pub fn invalidate(tab: u64) void {
    if (tab != source) return;
    clear();
    status.state = .stale;
}

pub fn closed(tab: u64) void {
    if (panel == tab) reset() else invalidate(tab);
}

pub fn begin(id: []const u8, tab: u64, reader_tab: u64, url: []const u8, view: *native.MoonView) void {
    reset();
    if (id.len > owner.len or url.len > address.len) return;
    serial += 1;
    source = tab;
    panel = reader_tab;
    @memcpy(owner[0..id.len],id);
    owner_len = id.len;
    @memcpy(address[0..url.len],url);
    status = .{ .state=.pending,.generation=serial,.url=address[0..url.len] };
    deadline = native.moon_clock()+5000;
    if (!native.moon_engine_read_article(view,serial,script.ptr)) status.state = .unavailable;
}

pub fn complete(tab: u64, request: u64, json: []const u8) void {
    if (tab != source or status.state != .pending or status.generation != request) return;
    status.state = .unavailable;
    if (std.mem.eql(u8,json,"\"noArticle\"")) {
        status.state = .noArticle;
    } else if (std.mem.eql(u8,json,"\"tooLarge\"")) {
        status.state = .tooLarge;
    } else if (json.len > 2 and json.len < 192*1024 and json[0] == '{' and json[json.len-1] == '}') {
        captured = allocator.dupe(u8,json) catch return;
        status.state = .ready;
    }
}

pub fn tick(now: u64) void {
    if (status.state == .pending and now >= deadline) status.state = .unavailable;
}

fn owns(tab: u64, id: []const u8) bool {
    return tab != 0 and tab == panel and std.mem.eql(u8,owner[0..owner_len],id);
}

pub fn selected(tab: u64, id: []const u8) ?u64 {
    return if (owns(tab,id) and source != 0) source else null;
}

pub fn article(tab: u64, id: []const u8) sdk.ReaderStatus {
    return if (owns(tab,id)) status else .{};
}

pub fn read(tab: u64, id: []const u8, query: sdk.ReaderQuery) ?struct { bytes: []const u8, next: ?usize } {
    if (!owns(tab,id) or query.generation != status.generation) return null;
    const bytes = captured orelse return null;
    if (query.offset >= bytes.len) return null;
    const end = @min(bytes.len,query.offset+12*1024);
    return .{ .bytes=bytes[query.offset..end],.next=if (end==bytes.len) null else end };
}
