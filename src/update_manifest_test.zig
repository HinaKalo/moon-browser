const std = @import("std");
const manifest = @import("update_manifest.zig");

const fixture = @embedFile("update_fixture.json");

test "reject modified signed fields and reject a foreign release" {
    const expected: manifest.Target = .{ .app = "moonchat", .platform = "win-x64", .channel = "stable", .suffix = ".zip" };
    const signed = (try manifest.parse(fixture, expected, 1)).?;
    try std.testing.expectEqual(@as(u64, 200), signed.code);
    try std.testing.expectEqual(null, try manifest.parse(fixture, expected, 200));
    var modified = fixture.*;
    modified[std.mem.indexOf(u8, fixture, "0.2.0").?] = '9';
    try std.testing.expectError(error.InvalidSignature, manifest.parse(&modified, expected, 1));
    try std.testing.expectError(error.WrongTarget, manifest.parse(fixture, .{
        .app = "moon-browser",
        .platform = "win-x64",
        .channel = "stable",
        .suffix = ".zip",
    }, 1));
}

test "no publication yields no pending update" {
    try std.testing.expectEqual(null, try manifest.parse("{\"manifest\":null}", .{
        .app = "moon-browser",
        .platform = "win-x64-portable",
        .channel = "preview",
        .suffix = ".zip",
    }, 102));
}
