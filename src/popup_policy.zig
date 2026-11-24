const std = @import("std");
const native = @import("native");
const sdk = @import("moon_plugin");
const history = @import("history.zig");

const max_rules = 64;
pub const Origin = [320:0]u8;
const Entry = struct { origin: Origin, mode: sdk.PopupMode };
const State = struct { entries: [max_rules]Entry = undefined, len: usize = 0 };
const Notice = struct { source: u64, id: u64, count: u32, target: [4096:0]u8 };
const Binding = struct { panel: u64, source: u64, owner: [96:0]u8, origin: Origin };
pub const Status = struct { currentOrigin: ?[]const u8, rules: []const sdk.PopupRule, blocked: ?sdk.PopupNotice };

var state: State = .{};
var path: [4096:0]u8 = @splat(0);
var binding: ?Binding = null;
var notice: ?Notice = null;
var sequence: u64 = 0;
pub const RuleBuffer = [max_rules]sdk.PopupRule;

fn text(value: anytype) []const u8 {
    return std.mem.sliceTo(value, 0);
}

pub fn origin(url: []const u8) ?Origin {
    if (!history.validURL(url)) return null;
    const parsed = std.Uri.parse(url) catch return null;
    const host = parsed.host orelse return null;
    if (host.isEmpty() or parsed.port == 0) return null;
    const secure = std.ascii.eqlIgnoreCase(parsed.scheme, "https");
    const start: usize = if (secure) 8 else 7;
    const rest = url[start..];
    const authority = rest[0 .. std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len];
    for (authority) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "-.:[]", ch) == null) return null;
    }
    const hostname = if (parsed.port != null)
        authority[0 .. std.mem.lastIndexOfScalar(u8, authority, ':') orelse return null]
    else authority;
    const len = start + hostname.len;
    var normalized: Origin = @splat(0);
    if (len >= normalized.len) return null;
    _ = std.ascii.lowerString(normalized[0..start], url[0..start]);
    _ = std.ascii.lowerString(normalized[start..len], hostname);
    if (parsed.port) |port| {
        if (port != (if (secure) @as(u16,443) else @as(u16,80))) {
            _ = std.fmt.bufPrint(normalized[len..normalized.len-1], ":{d}", .{port}) catch return null;
        }
    }
    return normalized;
}

fn find(state_value: *const State, key: []const u8) ?usize {
    for (state_value.entries[0..state_value.len], 0..) |*entry, index| {
        if (std.mem.eql(u8, text(&entry.origin), key)) return index;
    }
    return null;
}

fn rules(value: *const State, buffer: *RuleBuffer) []const sdk.PopupRule {
    for (value.entries[0..value.len], buffer[0..value.len]) |*entry, *item| {
        item.* = .{ .origin=text(&entry.origin), .mode=entry.mode };
    }
    return buffer[0..value.len];
}

pub fn init(profile: []const u8) void {
    _ = std.fmt.bufPrintSentinel(&path, "{s}\\popup-rules.json", .{profile}, 0) catch return;
    const allocator = std.heap.page_allocator;
    const raw = allocator.alloc(u8, 32 * 1024) catch return;
    defer allocator.free(raw);
    if (!native.moon_read_text(&path, raw.ptr, raw.len)) return;
    const saved = std.json.parseFromSlice([]sdk.PopupRule, allocator, text(raw), .{}) catch return;
    defer saved.deinit();
    for (saved.value) |item| {
        if (state.len == max_rules) break;
        const key = origin(item.origin) orelse continue;
        if (item.mode == .automatic or find(&state,text(&key)) != null) continue;
        state.entries[state.len] = .{ .origin=key, .mode=item.mode };
        state.len += 1;
    }
}

pub fn mode(key: []const u8) sdk.PopupMode {
    return if (find(&state,key)) |index| state.entries[index].mode else .automatic;
}

pub fn save(allocator: std.mem.Allocator, rule: sdk.PopupRule) !void {
    if (path[0] == 0) return error.Unavailable;
    const key = origin(rule.origin) orelse return error.InvalidParams;
    var next = state;
    if (find(&next, text(&key))) |index| {
        if (rule.mode == .automatic) {
            next.len -= 1;
            if (index != next.len) next.entries[index] = next.entries[next.len];
        } else next.entries[index].mode = rule.mode;
    } else if (rule.mode != .automatic) {
        if (next.len == max_rules) return error.LimitExceeded;
        next.entries[next.len] = .{ .origin=key, .mode=rule.mode };
        next.len += 1;
    } else return;
    var buffer: RuleBuffer = undefined;
    const json = try std.json.Stringify.valueAlloc(allocator, rules(&next,&buffer), .{});
    defer allocator.free(json);
    const bytes = try allocator.dupeSentinel(u8,json,0);
    defer allocator.free(bytes);
    if (!native.moon_write_text(&path,bytes.ptr)) return error.Unavailable;
    state = next;
}

pub fn bind(panel: u64, owner: []const u8, source: u64, current: Origin) void {
    if (owner.len >= 96) return;
    binding = .{ .panel=panel, .source=source, .owner=@splat(0), .origin=current };
    if (binding) |*entry| @memcpy(entry.owner[0..owner.len],owner);
}

pub fn invalidate(tab: u64) void {
    if (notice) |value| if (value.source == tab) { notice = null; };
}

pub fn clear(tab: u64) void {
    invalidate(tab);
    if (binding) |value| if (value.panel == tab) { binding = null; };
}

pub fn blocked(source: u64, url: []const u8) bool {
    const retained = notice != null and notice.?.source == source;
    const count = if (retained) notice.?.count +| 1 else 1;
    sequence += 1;
    notice = .{ .source=source, .id=sequence, .count=count, .target=@splat(0) };
    if (notice) |*value| @memcpy(value.target[0..url.len],url);
    return !retained;
}

fn selected(panel: u64, owner: []const u8) ?*const Binding {
    const value = if (binding) |*item| item else return null;
    if (value.panel != panel or !std.mem.eql(u8,text(&value.owner),owner)) return null;
    return value;
}

pub fn status(panel: u64, owner: []const u8, buffer: *RuleBuffer, target: *Origin) Status {
    var result: Status = .{ .rules=rules(&state,buffer), .currentOrigin=null, .blocked=null };
    const bound = selected(panel,owner) orelse return result;
    if (bound.origin[0] != 0) result.currentOrigin = text(&bound.origin);
    const item = if (notice) |*value| value else return result;
    if (item.source != bound.source) return result;
    target.* = origin(text(&item.target)) orelse return result;
    result.blocked = .{ .id=item.id, .count=item.count, .targetOrigin=text(target) };
    return result;
}

pub fn openOnce(panel: u64, owner: []const u8, id: u64, output: *[4096:0]u8) bool {
    const bound = selected(panel,owner) orelse return false;
    const item = notice orelse return false;
    if (item.source != bound.source or item.id != id) return false;
    output.* = item.target;
    notice = null;
    return true;
}
