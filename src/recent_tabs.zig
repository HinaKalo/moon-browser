const std = @import("std");
const native = @import("native");
const sdk = @import("moon_plugin");
const reading = @import("reading.zig");

pub const limit = 12;
pub const Entry = struct {
    id: u32 = 0,
    title: [512:0]u8,
    url: [4096:0]u8,
    state: ?*const anyopaque,
};
var entries: [limit]Entry = undefined;
var count: usize = 0;
var next_id: u32 = 1;

fn release(entry: Entry) void {
    if (entry.state) |state| native.moon_engine_release_state(state);
}

pub fn clear() void {
    for (entries[0..count]) |entry| release(entry);
    count = 0;
}

pub fn record(entry: Entry) void {
    if (count == entries.len) {
        release(entries[0]);
        std.mem.copyForwards(Entry, entries[0 .. count - 1], entries[1..count]);
        count -= 1;
    }
    entries[count] = entry;
    entries[count].id = next_id;
    next_id +%= 1;
    count += 1;
}

pub fn take(id: ?u32) ?Entry {
    if (count == 0) return null;
    if (id) |selected| {
        for (entries[0..count], 0..) |entry, index| {
            if (entry.id != selected) continue;
            std.mem.copyForwards(Entry, entries[index .. count - 1], entries[index + 1 .. count]);
            count -= 1;
            return entry;
        }
        return null;
    }
    count -= 1;
    return entries[count];
}

fn preview(value: []const u8) []const u8 {
    if (!std.unicode.utf8ValidateSlice(value)) return "";
    var end = @min(value.len, 192);
    while (end < value.len and value[end] & 0xc0 == 0x80) end -= 1;
    return value[0..end];
}

pub fn list(output: *[limit]sdk.ClosedTab) []const sdk.ClosedTab {
    for (output[0..count], 0..) |*item, index| {
        const entry = &entries[count - 1 - index];
        item.* = .{
            .id = entry.id,
            .title = preview(std.mem.sliceTo(&entry.title, 0)),
            .origin = preview(reading.origin(std.mem.sliceTo(&entry.url, 0)) orelse ""),
        };
    }
    return output[0..count];
}
