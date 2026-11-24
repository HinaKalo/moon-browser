const std = @import("std");
const sdk = @import("moon_plugin");
const native = @import("native");
const db_api = @import("profile_db.zig");

const sqlite = &db_api.sqlite;
const State = sdk.DownloadState;
const Active = struct {
    id: u32 = 0,
    state: State = .choosing,
    received: u64 = 0,
    total: u64 = 0,
    cancelling: bool = false,
};
var slots: [64]Active = @splat(.{});
var database: ?*db_api.Database = null;
var path: [4096:0]u8 = @splat(0);
var process: u32 = 0;
var birth: u64 = 0;

pub fn init(profile: []const u8) void {
    _ = std.fmt.bufPrintSentinel(&path,"{s}\\downloads.sqlite3",.{profile},0) catch return;
    process = native.moon_current_pid();
    birth = native.moon_process_birth(process);
}

fn connection() !*db_api.Database {
    if (database) |db| return db;
    const db = try db_api.open(std.mem.sliceTo(&path,0));
    errdefer db_api.close(db);
    if (sqlite.sqlite3_exec(db,
        \\CREATE TABLE IF NOT EXISTS downloads (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT NOT NULL DEFAULT '', state INTEGER NOT NULL DEFAULT 0,
        \\  received INTEGER NOT NULL DEFAULT 0, total INTEGER NOT NULL DEFAULT 0, started INTEGER NOT NULL,
        \\  owner_pid INTEGER NOT NULL, owner_birth INTEGER NOT NULL
        \\);
        \\CREATE TRIGGER IF NOT EXISTS limit_finished_downloads AFTER UPDATE OF state ON downloads WHEN NEW.state >= 2 BEGIN
        \\  DELETE FROM downloads WHERE state >= 2 AND id < (
        \\    SELECT id FROM downloads WHERE state >= 2 ORDER BY id DESC LIMIT 1 OFFSET 499
        \\  );
        \\END;
    ,null,null,null) != db_api.ok) return error.IOError;
    database = db;
    return db;
}

fn lookup(id: u32) ?*Active {
    if (id == 0) return null;
    for (&slots) |*entry| if (entry.id == id) return entry;
    return null;
}

fn bind(statement: *db_api.Statement, column: c_int, value: u64) !void {
    const bounded: i64 = @intCast(@min(value,std.math.maxInt(i64)));
    if (sqlite.sqlite3_bind_int64(statement,column,bounded) != db_api.ok) return error.IOError;
}

fn number(statement: *db_api.Statement, column: c_int) u64 {
    return @intCast(@max(0,sqlite.sqlite3_column_int64(statement,column)));
}

pub fn begin() u32 {
    const slot = for (&slots) |*entry| {
        if (entry.id == 0) break entry;
    } else return 0;
    const db = connection() catch return 0;
    const statement = db_api.prepare(db,"INSERT INTO downloads(started,owner_pid,owner_birth) VALUES (?1,?2,?3)") catch return 0;
    defer _ = sqlite.sqlite3_finalize(statement);
    bind(statement,1,native.moon_wall_ms()) catch return 0;
    bind(statement,2,process) catch return 0;
    bind(statement,3,birth) catch return 0;
    if (sqlite.sqlite3_step(statement) != db_api.done) return 0;
    const id = std.math.cast(u32,sqlite.sqlite3_last_insert_rowid(db)) orelse return 0;
    slot.* = .{ .id=id };
    return id;
}

pub fn destination(id: u32, filename: []const u8) void {
    const entry = lookup(id) orelse return;
    entry.state = .transferring;
    const db = connection() catch return;
    const statement = db_api.prepare(db,"UPDATE downloads SET path=?1,state=1 WHERE id=?2") catch return;
    defer _ = sqlite.sqlite3_finalize(statement);
    db_api.bindText(statement,1,filename) catch return;
    bind(statement,2,id) catch return;
    _ = sqlite.sqlite3_step(statement);
}

pub fn progress(id: u32, chunk: u64, total: u64) void {
    const entry = lookup(id) orelse return;
    entry.received +|= chunk;
    if (total != 0) entry.total = total;
    if (entry.received > entry.total) entry.total = 0;
}

fn persistEnd(entry: *Active) !void {
    const db = try connection();
    const statement = try db_api.prepare(db,"UPDATE downloads SET state=?1,received=?2,total=?3 WHERE id=?4");
    defer _ = sqlite.sqlite3_finalize(statement);
    try bind(statement,1,@intFromEnum(entry.state));
    try bind(statement,2,entry.received);
    try bind(statement,3,entry.total);
    try bind(statement,4,entry.id);
    if (sqlite.sqlite3_step(statement) != db_api.done) return error.IOError;
    entry.* = .{};
}

pub fn finish(id: u32, state: State) void {
    const entry = lookup(id) orelse return;
    entry.state = state;
    if (state == .complete) {
        entry.received = @max(entry.received,entry.total);
        entry.total = entry.received;
    }
    persistEnd(entry) catch {};
}

pub fn flush() void {
    for (&slots) |*entry| {
        if (entry.id != 0 and entry.state != .choosing and entry.state != .transferring) persistEnd(entry) catch {};
    }
}

pub fn close() void {
    for (&slots) |*entry| {
        if (entry.id == 0) continue;
        if (entry.state == .choosing or entry.state == .transferring) entry.state = .interrupted;
        persistEnd(entry) catch {};
    }
    if (database) |db| db_api.close(db);
    database = null;
}

fn readState(statement: *db_api.Statement, id: u32, state_col: c_int, owner_col: c_int) State {
    if (lookup(id)) |entry| return entry.state;
    const state = std.enums.fromInt(State,number(statement,state_col)) orelse return .interrupted;
    if (state != .choosing and state != .transferring) return state;
    const other = std.math.cast(u32,number(statement,owner_col)) orelse return .interrupted;
    const created = number(statement,owner_col+1);
    if (other == process or created == 0 or native.moon_process_birth(other) != created) return .interrupted;
    return state;
}

pub fn list(allocator: std.mem.Allocator, options: sdk.HistoryQuery, buffer: *[24]sdk.Download) !sdk.DownloadPage {
    if (options.query.len > 256) return error.InvalidParams;
    flush();
    const statement = try db_api.prepare(try connection(),
        \\SELECT id,path,state,received,total,started,owner_pid,owner_birth FROM downloads
        \\WHERE id>0 AND id<?1 AND instr(lower(path),lower(?2)) ORDER BY id DESC LIMIT 25
    );
    defer _ = sqlite.sqlite3_finalize(statement);
    try bind(statement,1,if (options.before) |id| id else @as(u64,std.math.maxInt(u32))+1);
    try db_api.bindText(statement,2,options.query);
    var length: usize = 0;
    var budget: usize = 24*1024;
    while (true) {
        const status = sqlite.sqlite3_step(statement);
        if (status == db_api.done) return .{ .downloads=buffer[0..length],.next=null };
        if (status != db_api.row) return error.IOError;
        const filename = try db_api.columnText(statement,1);
        const name = if (std.mem.lastIndexOfAny(u8,filename,"\\/")) |index| filename[index+1..] else filename;
        if (name.len > 1200 or !std.unicode.utf8ValidateSlice(name)) continue;
        const cost = 6*name.len+192;
        if (length == buffer.len or cost > budget)
            return .{ .downloads=buffer[0..length],.next=buffer[length-1].id };
        const id: u32 = @intCast(number(statement,0));
        const entry = lookup(id);
        const total = if (entry) |transfer| transfer.total else number(statement,4);
        buffer[length] = .{
            .id=id,.name=try allocator.dupe(u8,name),.state=readState(statement,id,2,6),
            .received=if (entry) |transfer| transfer.received else number(statement,3),
            .total=if (total != 0) total else null,.startedAt=number(statement,5),
            .cancellable=if (entry) |transfer| transfer.state == .transferring and !transfer.cancelling else false,
        };
        length += 1;
        budget -= cost;
    }
}

pub fn cancel(id: u32) !void {
    const entry = lookup(id) orelse return error.NotFound;
    if (entry.state != .transferring or entry.cancelling) return error.InvalidParams;
    entry.cancelling = true;
    if (!native.moon_engine_cancel_download(id)) {
        entry.cancelling = false;
        return error.NotFound;
    }
}

pub fn remove(id: u32) !void {
    flush();
    const db = try connection();
    const state = read: {
        const statement = try db_api.prepare(db,"SELECT state,owner_pid,owner_birth FROM downloads WHERE id=?1");
        defer _ = sqlite.sqlite3_finalize(statement);
        try bind(statement,1,id);
        const result = sqlite.sqlite3_step(statement);
        if (result == db_api.done) return error.NotFound;
        if (result != db_api.row) return error.IOError;
        break :read readState(statement,id,0,1);
    };
    if (state == .choosing or state == .transferring) return error.InvalidParams;
    const statement = try db_api.prepare(db,"DELETE FROM downloads WHERE id=?1");
    defer _ = sqlite.sqlite3_finalize(statement);
    try bind(statement,1,id);
    if (sqlite.sqlite3_step(statement) != db_api.done) return error.IOError;
    if (sqlite.sqlite3_changes(db) == 0) return error.NotFound;
}

pub fn reveal(allocator: std.mem.Allocator, id: u32) !void {
    const statement = try db_api.prepare(try connection(),"SELECT path FROM downloads WHERE id=?1 AND state=2");
    defer _ = sqlite.sqlite3_finalize(statement);
    try bind(statement,1,id);
    const result = sqlite.sqlite3_step(statement);
    if (result == db_api.done) return error.NotFound;
    if (result != db_api.row) return error.IOError;
    const filename = try allocator.dupeSentinel(u8,try db_api.columnText(statement,0),0);
    if (!native.moon_shell_reveal_file(filename.ptr)) return error.NotFound;
}
