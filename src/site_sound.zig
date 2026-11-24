const std = @import("std");
const sdk = @import("moon_plugin");
const native = @import("native");
const popups = @import("popup_policy.zig");

const limit = 64;
const State = struct { entries: [limit]popups.Origin = undefined, len: usize = 0 };
pub const Buffer = [limit][]const u8;
var state: State = .{};
var path: [4096:0]u8 = @splat(0);

fn find(value: *const State, origin: []const u8) ?usize {
    for (value.entries[0..value.len],0..) |*entry,index| {
        if (std.mem.eql(u8,std.mem.sliceTo(entry,0),origin)) return index;
    }
    return null;
}

fn origins(value: *const State, buffer: *Buffer) []const []const u8 {
    for (value.entries[0..value.len],buffer[0..value.len]) |*entry,*origin| origin.*=std.mem.sliceTo(entry,0);
    return buffer[0..value.len];
}

pub fn init(profile: []const u8) void {
    if (profile.len==0) return;
    _ = std.fmt.bufPrintSentinel(&path,"{s}\\muted-sites.json",.{profile},0) catch return;
    var bytes: [32 * 1024]u8 = undefined;
    if (!native.moon_read_text(&path,&bytes,bytes.len)) return;
    const saved = std.json.parseFromSlice([][]const u8,std.heap.page_allocator,std.mem.sliceTo(&bytes,0),.{}) catch return;
    defer saved.deinit();
    for (saved.value) |entry| {
        if (state.len==limit) break;
        const key = popups.origin(entry) orelse continue;
        if (find(&state,std.mem.sliceTo(&key,0))!=null) continue;
        state.entries[state.len] = key;
        state.len+=1;
    }
}

pub fn muted(key: []const u8) bool {
    return find(&state,key)!=null;
}

pub fn hasRules() bool {
    return state.len!=0;
}

pub fn status(panel: u64, owner: []const u8, buffer: *Buffer) sdk.SiteSoundSettings {
    return .{ .currentOrigin=popups.boundOrigin(panel,owner),.muted=origins(&state,buffer) };
}

pub fn save(allocator: std.mem.Allocator, key: popups.Origin, enabled: bool) !void {
    if (path[0]==0) return error.Unavailable;
    var updated = state;
    if (find(&updated,std.mem.sliceTo(&key,0))) |index| {
        if (enabled) return;
        updated.len-=1;
        updated.entries[index]=updated.entries[updated.len];
    } else {
        if (!enabled) return;
        if (updated.len==limit) return error.LimitExceeded;
        updated.entries[updated.len]=key;
        updated.len+=1;
    }
    var buffer: Buffer = undefined;
    const json = try std.json.Stringify.valueAlloc(allocator,origins(&updated,&buffer),.{});
    defer allocator.free(json);
    const bytes = try allocator.dupeSentinel(u8,json,0);
    defer allocator.free(bytes);
    if (!native.moon_write_text(&path,bytes.ptr)) return error.Unavailable;
    state=updated;
}
