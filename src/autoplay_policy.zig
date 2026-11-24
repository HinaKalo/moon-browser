const std = @import("std");
const sdk = @import("moon_plugin");
const native = @import("native");
const popups = @import("popup_policy.zig");

const limit = 64;
const Entry = struct { origin: popups.Origin, mode: sdk.AutoplayMode };
const State = struct { entries: [limit]Entry = undefined, len: usize = 0 };
pub const Buffer = [limit]sdk.AutoplayRule;
var state: State = .{};
var path: [4096:0]u8 = @splat(0);

fn find(value: *const State, origin: []const u8) ?usize {
    for (value.entries[0..value.len],0..) |*entry,index| {
        if (std.mem.eql(u8,std.mem.sliceTo(&entry.origin,0),origin)) return index;
    }
    return null;
}

fn rules(value: *const State, buffer: *Buffer) []const sdk.AutoplayRule {
    for (value.entries[0..value.len],buffer[0..value.len]) |*entry,*rule|
        rule.* = .{ .origin=std.mem.sliceTo(&entry.origin,0),.mode=entry.mode };
    return buffer[0..value.len];
}

pub fn init(profile: []const u8) void {
    if (profile.len==0) return;
    _ = std.fmt.bufPrintSentinel(&path,"{s}\\autoplay-rules.json",.{profile},0) catch return;
    var bytes: [32 * 1024]u8 = undefined;
    if (!native.moon_read_text(&path,&bytes,bytes.len)) return;
    const saved = std.json.parseFromSlice([]sdk.AutoplayRule,std.heap.page_allocator,std.mem.sliceTo(&bytes,0),.{}) catch return;
    defer saved.deinit();
    for (saved.value) |rule| {
        if (state.len==limit) break;
        const key = popups.origin(rule.origin) orelse continue;
        if (rule.mode==.automatic or find(&state,std.mem.sliceTo(&key,0))!=null) continue;
        state.entries[state.len] = .{ .origin=key,.mode=rule.mode };
        state.len+=1;
    }
}

pub fn hasRules() bool {
    return state.len!=0;
}

pub fn mode(key: []const u8) sdk.AutoplayMode {
    return if (find(&state,key)) |index| state.entries[index].mode else .automatic;
}

pub fn status(panel: u64, owner: []const u8, buffer: *Buffer) sdk.AutoplaySettings {
    return .{ .currentOrigin=popups.boundOrigin(panel,owner),.rules=rules(&state,buffer) };
}

pub fn save(allocator: std.mem.Allocator, key: popups.Origin, value: sdk.AutoplayMode) !void {
    if (path[0]==0) return error.Unavailable;
    var updated = state;
    if (find(&updated,std.mem.sliceTo(&key,0))) |index| {
        if (updated.entries[index].mode==value) return;
        if (value==.automatic) {
            updated.len-=1;
            updated.entries[index] = updated.entries[updated.len];
        } else updated.entries[index].mode = value;
    } else {
        if (value==.automatic) return;
        if (updated.len==limit) return error.LimitExceeded;
        updated.entries[updated.len] = .{ .origin=key,.mode=value };
        updated.len+=1;
    }
    var buffer: Buffer = undefined;
    const json = try std.json.Stringify.valueAlloc(allocator,rules(&updated,&buffer),.{});
    defer allocator.free(json);
    const bytes = try allocator.dupeSentinel(u8,json,0);
    defer allocator.free(bytes);
    if (!native.moon_write_text(&path,bytes.ptr)) return error.Unavailable;
    state = updated;
}
