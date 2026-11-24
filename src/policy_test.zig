const std = @import("std");
const policy = @import("policy.zig");

test "fifty idle pages release oldest background tabs first" {
    var tabs: [50]policy.Tab = undefined;
    for (&tabs, 0..) |*tab, id| tab.* = .{ .last_used = id };
    tabs[0].protected = true;
    var count: usize = 0;
    while (policy.choose(&tabs, 0, 100, false, .{})) |index| {
        count += 1;
        try std.testing.expectEqual(count, index);
        tabs[index].live = false;
    }
    try std.testing.expectEqual(@as(usize, 43), count);
}

test "age limit, pressure hysteresis and protected tabs" {
    const tabs = [_]policy.Tab{ .{ .protected = true }, .{ .last_used = 100 } };
    try std.testing.expectEqual(null, policy.choose(&tabs, 0, 300099, false, .{}));
    try std.testing.expectEqual(@as(?usize, 1), policy.choose(&tabs, 0, 300100, false, .{}));
    try std.testing.expectEqual(@as(?usize, 1), policy.choose(&tabs, 0, 100, true, .{}));
    try std.testing.expect(policy.underPressure(false, 1025 * policy.mib, false, .{}));
    try std.testing.expect(policy.underPressure(true, 801 * policy.mib, false, .{}));
    try std.testing.expect(!policy.underPressure(true, 800 * policy.mib, false, .{}));
    try std.testing.expect(policy.underPressure(false, 0, true, .{}));
}

test "pressure prefers a process that can be reclaimed without touching protected tabs" {
    const tabs = [_]policy.Tab{
        .{ .pid = 11, .protected = true },
        .{ .pid = 11, .last_used = 1 },
        .{ .pid = 22, .last_used = 2 },
        .{ .pid = 22, .last_used = 3 },
    };
    try std.testing.expectEqual(@as(?usize, 2), policy.choose(&tabs, 0, 10, true, .{}));
    try std.testing.expectEqual(@as(?usize, 1), policy.choose(&tabs, 0, 10, false, .{ .warm_limit = 0 }));
}

test "private commit counts one sample per process and ignores PID zero" {
    const samples = [_]policy.Sample{
        .{ .pid = 45, .bytes = 20 },
        .{ .pid = 89, .bytes = 30 },
        .{ .pid = 45, .bytes = 20 },
        .{ .pid = 0, .bytes = 500 },
    };
    try std.testing.expectEqual(@as(u64, 50), policy.totalCommit(&samples));
}
