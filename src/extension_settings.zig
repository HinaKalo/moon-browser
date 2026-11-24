const std = @import("std");
const native = @import("native");

const limit = 4096;
pub const Error = error{ InvalidObject, TooLarge, IOError };

fn filePath(id: []const u8, buffer: []u8) ![:0]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(id,&digest,.{});
    const hex = std.fmt.bytesToHex(digest,.lower);
    return std.fmt.bufPrintSentinel(buffer,"{s}\\extension-{s}.json",.{ std.mem.span(native.moon_profile_dir()),&hex },0);
}

pub fn read(allocator: std.mem.Allocator,id: []const u8) !std.json.Value {
    var path: [4096]u8 = undefined;
    var text: [limit+1]u8 = undefined;
    const file = try filePath(id,&path);
    if (!native.moon_read_text(file.ptr,&text,text.len)) return .{ .object = .empty };
    const json = try std.json.parseFromSliceLeaky(std.json.Value,allocator,std.mem.sliceTo(&text,0),.{ .allocate = .alloc_always });
    if (json != .object) return error.InvalidObject;
    return json;
}

pub fn write(allocator: std.mem.Allocator,id: []const u8,value: std.json.Value) !void {
    if (value != .object) return error.InvalidObject;
    const json = try std.json.Stringify.valueAlloc(allocator,value,.{});
    defer allocator.free(json);
    if (json.len > limit) return error.TooLarge;
    const bytes = try allocator.dupeSentinel(u8,json,0);
    defer allocator.free(bytes);
    var path: [4096]u8 = undefined;
    const file = try filePath(id,&path);
    if (!native.moon_write_text(file.ptr,bytes.ptr)) return error.IOError;
}

pub fn pageReply(id: []const u8,request: []const u8,output: []u8) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const type_def = struct { op: enum { read, write }, value: ?std.json.Value = null };
    const query = std.json.parseFromSliceLeaky(type_def,allocator,request,.{}) catch return false;
    const response = switch (query.op) {
        .read => read(allocator,id) catch return false,
        .write => stored: {
            write(allocator,id,query.value orelse return false) catch return false;
            break :stored std.json.Value.null;
        },
    };
    const json = std.json.Stringify.valueAlloc(allocator,.{ .ok=true,.value=response },.{}) catch return false;
    if (json.len >= output.len) return false;
    @memcpy(output[0..json.len],json);
    output[json.len] = 0;
    return true;
}
