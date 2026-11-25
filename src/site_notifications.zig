const std = @import("std");
const native = @import("native");
const sdk = @import("moon_plugin");
const popups = @import("popup_policy.zig");

const limit = 64;
const Entry = struct { origin: popups.Origin, mode: sdk.NotificationMode };
pub const Buffer = [limit]sdk.NotificationRule;
const State = struct {
    entries: [limit]Entry = undefined,
    len: usize = 0,

    fn find(self: *const State, origin: []const u8) ?usize {
        for (self.entries[0..self.len],0..) |*entry,index| {
            if (std.mem.eql(u8,std.mem.sliceTo(&entry.origin,0),origin)) return index;
        }
        return null;
    }

    fn rules(self: *const State, buffer: *Buffer) []const sdk.NotificationRule {
        for (self.entries[0..self.len],buffer[0..self.len]) |*entry,*rule|
            rule.* = .{ .origin=std.mem.sliceTo(&entry.origin,0),.mode=entry.mode };
        return buffer[0..self.len];
    }
};
var state: State = .{};
var path: [4096:0]u8 = @splat(0);

pub fn init(profile: []const u8) void {
    if (profile.len==0) return;
    _ = std.fmt.bufPrintSentinel(&path,"{s}\\notification-rules.json",.{profile},0) catch return;
    var bytes: [32*1024]u8 = undefined;
    if (!native.moon_read_text(&path,&bytes,bytes.len)) return;
    const saved = std.json.parseFromSlice([]sdk.NotificationRule,std.heap.page_allocator,std.mem.sliceTo(&bytes,0),.{}) catch return;
    defer saved.deinit();
    for (saved.value) |rule| {
        if (state.len==limit) break;
        const key = popups.origin(rule.origin) orelse continue;
        if (rule.mode==.ask or state.find(std.mem.sliceTo(&key,0))!=null) continue;
        state.entries[state.len] = .{ .origin=key,.mode=rule.mode };
        state.len+=1;
    }
}

pub fn mode(origin: []const u8) sdk.NotificationMode {
    return if (state.find(origin)) |index| state.entries[index].mode else .ask;
}

pub fn list(buffer: *Buffer) []const sdk.NotificationRule {
    return state.rules(buffer);
}

pub fn save(allocator: std.mem.Allocator, key: popups.Origin, decision: sdk.NotificationMode) !void {
    if (path[0]==0) return error.Unavailable;
    var next = state;
    if (next.find(std.mem.sliceTo(&key,0))) |index| {
        if (decision==.ask) {
            next.len-=1;
            next.entries[index] = next.entries[next.len];
        } else {
            next.entries[index].mode = decision;
        }
    } else {
        if (decision==.ask) return;
        if (next.len==limit) return error.LimitExceeded;
        next.entries[next.len] = .{ .origin=key,.mode=decision };
        next.len+=1;
    }
    var buffer: Buffer = undefined;
    const bytes = try std.json.Stringify.valueAlloc(allocator,next.rules(&buffer),.{});
    defer allocator.free(bytes);
    const json = try allocator.dupeSentinel(u8,bytes,0);
    defer allocator.free(json);
    if (!native.moon_write_text(&path,json.ptr)) return error.Unavailable;
    state = next;
}
