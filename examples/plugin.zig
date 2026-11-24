const std = @import("std");

extern "c" fn getchar() c_int;
extern "c" fn puts([*:0]const u8) c_int;
extern "c" fn fflush(?*anyopaque) c_int;
extern "c" fn Sleep(u32) callconv(.winapi) void;
extern "c" fn exit(c_int) noreturn;

fn readLine(buffer: []u8) ?[]const u8 {
    var len: usize = 0;
    while (len < buffer.len) {
        const ch = getchar();
        if (ch < 0) return null;
        if (ch == '\n') return buffer[0..len];
        buffer[len] = @intCast(ch);
        len += 1;
    }
    return null;
}

fn write(comptime message: [:0]const u8) void {
    _ = puts(message);
    _ = fflush(null);
}

pub fn main() void {
    var buffer: [16384]u8 = undefined;
    const initial = readLine(&buffer) orelse return;
    if (std.mem.indexOf(u8, initial, "\"tabs.changed\"") != null) {
        write("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"Tab change received\"}");
        return;
    }
    if (std.mem.indexOf(u8, initial, "\"test.timeout\"") != null) Sleep(60000);
    if (std.mem.indexOf(u8, initial, "\"test.crash\"") != null) exit(31);
    write("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tabs.getActive\"}");
    const response = readLine(&buffer) orelse return;
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, response, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    if (parsed.value.object.get("result")) |result| {
        if (result == .object) {
            if (result.object.get("title")) |title| {
                if (title == .string) {
                    const encoded = std.json.Stringify.valueAlloc(std.heap.page_allocator, title.string, .{}) catch return;
                    defer std.heap.page_allocator.free(encoded);
                    const message = std.fmt.bufPrintSentinel(&buffer, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{s}}}", .{encoded}, 0) catch return;
                    _ = puts(message);
                    return;
                }
            }
        }
    }
    write("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"No access to active tab details\"}");
}
