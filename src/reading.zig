const std = @import("std");
const db_api = @import("profile_db.zig");
const history = @import("history.zig");
const sdk = @import("moon_plugin");

const sqlite = &db_api.sqlite;
const levels = [_]u16{ 50, 67, 75, 80, 90, 100, 110, 125, 150, 175, 200, 250, 300 };
var database: ?*db_api.Database = null;
var path: [4096:0]u8 = @splat(0);

pub fn init(profile: []const u8) void {
    _ = std.fmt.bufPrintSentinel(&path, "{s}\\page-zoom.sqlite3", .{profile}, 0) catch return;
}

fn connection() !*db_api.Database {
    if (database) |db| return db;
    const db = try db_api.open(std.mem.sliceTo(&path, 0));
    errdefer db_api.close(db);
    if (sqlite.sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS zoom (origin TEXT PRIMARY KEY, percent INTEGER NOT NULL);", null, null, null) != db_api.ok) return error.IOError;
    database = db;
    return db;
}

pub fn close() void {
    if (database) |db| db_api.close(db);
    database = null;
}

pub fn origin(url: []const u8) ?[]const u8 {
    if (!history.validURL(url)) return null;
    const scheme: usize = if (url[4] == ':') 7 else 8;
    const rest = url[scheme..];
    return url[0 .. scheme + (std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len)];
}

pub fn next(current: u16, action: sdk.ZoomAction) u16 {
    switch (action) {
        .reset => return 100,
        .increase => {
            for (levels) |level| if (level > current) return level;
            return levels[levels.len - 1];
        },
        .decrease => {
            var index = levels.len;
            while (index > 0) {
                index -= 1;
                if (levels[index] < current) return levels[index];
            }
            return levels[0];
        },
    }
}

pub fn load(key: []const u8) u16 {
    const db = connection() catch return 100;
    const statement = db_api.prepare(db, "SELECT percent FROM zoom WHERE origin=?1") catch return 100;
    defer _ = sqlite.sqlite3_finalize(statement);
    db_api.bindText(statement, 1, key) catch return 100;
    if (sqlite.sqlite3_step(statement) != db_api.row) return 100;
    const percent = std.math.cast(u16, sqlite.sqlite3_column_int64(statement, 0)) orelse return 100;
    return if (std.mem.indexOfScalar(u16, &levels, percent) != null) percent else 100;
}

pub fn save(key: []const u8, percent: u16) !void {
    const db = try connection();
    const statement = try db_api.prepare(db, if (percent == 100) "DELETE FROM zoom WHERE origin=?1" else "INSERT OR REPLACE INTO zoom(origin,percent) VALUES (?1,?2)");
    defer _ = sqlite.sqlite3_finalize(statement);
    try db_api.bindText(statement, 1, key);
    if (percent != 100 and sqlite.sqlite3_bind_int64(statement, 2, percent) != db_api.ok) return error.IOError;
    if (sqlite.sqlite3_step(statement) != db_api.done) return error.IOError;
}
