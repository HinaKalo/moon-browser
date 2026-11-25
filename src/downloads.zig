const std = @import("std");
const sdk = @import("moon_plugin");
const native = @import("native");
const db_api = @import("profile_db.zig");
const history = @import("history.zig");

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
var preferences_path: [4096:0]u8 = @splat(0);
var preferred_folder: [4096:0]u8 = @splat(0);
var ask_where_to_save = true;
var process: u32 = 0;
var birth: u64 = 0;
const StoredPreferences = struct { folder: ?[]const u8 = null, askWhereToSave: bool = true };
pub const Preferences = struct { folder: ?[]const u8, custom: bool, askWhereToSave: bool };

pub fn init(profile: []const u8) void {
    _ = std.fmt.bufPrintSentinel(&path,"{s}\\downloads.sqlite3",.{profile},0) catch return;
    process = native.moon_current_pid();
    birth = native.moon_process_birth(process);
    _ = std.fmt.bufPrintSentinel(&preferences_path,"{s}\\download-preferences.json",.{profile},0) catch return;
    var raw: [32768]u8 = undefined;
    if (!native.moon_read_text(&preferences_path,&raw,raw.len)) return;
    const decoded = std.json.parseFromSlice(StoredPreferences,std.heap.page_allocator,std.mem.sliceTo(&raw,0),.{}) catch return;
    defer decoded.deinit();
    if (!validFolder(decoded.value.folder)) return;
    applyPreferences(decoded.value);
}

fn storedFolder() ?[]const u8 {
    return if (preferred_folder[0]==0) null else std.mem.sliceTo(&preferred_folder,0);
}

fn validFolder(folder: ?[]const u8) bool {
    const value = folder orelse return true;
    return value.len>0 and value.len<preferred_folder.len and
        std.unicode.utf8ValidateSlice(value) and std.mem.indexOfScalar(u8,value,0)==null;
}

fn applyPreferences(value: StoredPreferences) void {
    const folder = value.folder orelse "";
    std.mem.copyForwards(u8,preferred_folder[0..folder.len],folder);
    preferred_folder[folder.len]=0;
    ask_where_to_save=value.askWhereToSave;
}

fn savePreferences(allocator: std.mem.Allocator, value: StoredPreferences) !void {
    if (preferences_path[0]==0 or !validFolder(value.folder)) return error.IOError;
    const json = try std.json.Stringify.valueAlloc(allocator,value,.{});
    defer allocator.free(json);
    const bytes = try allocator.dupeSentinel(u8,json,0);
    defer allocator.free(bytes);
    if (!native.moon_write_text(&preferences_path,bytes.ptr)) return error.IOError;
    applyPreferences(value);
}

pub fn preferences(buffer: *[4096]u8) Preferences {
    const custom = storedFolder();
    const folder: ?[]const u8 = if (custom) |value| value else if (native.moon_shell_download_default(buffer,buffer.len))
        std.mem.sliceTo(buffer,0) else null;
    return .{ .folder=folder,.custom=custom!=null,.askWhereToSave=ask_where_to_save };
}

pub fn configurePrompt(allocator: std.mem.Allocator, prompt: bool) !void {
    if (prompt!=ask_where_to_save)
        try savePreferences(allocator,.{ .folder=storedFolder(),.askWhereToSave=prompt });
}

pub fn configureFolder(allocator: std.mem.Allocator, folder: ?[]const u8) !void {
    try savePreferences(allocator,.{ .folder=folder,.askWhereToSave=ask_where_to_save });
}

fn connection() !*db_api.Database {
    if (database) |db| return db;
    const db = try db_api.open(std.mem.sliceTo(&path,0));
    errdefer db_api.close(db);
    if (sqlite.sqlite3_exec(db,"BEGIN IMMEDIATE",null,null,null)!=db_api.ok) return error.IOError;
    errdefer _ = sqlite.sqlite3_exec(db,"ROLLBACK",null,null,null);
    if (sqlite.sqlite3_exec(db,
        \\CREATE TABLE IF NOT EXISTS downloads (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT NOT NULL DEFAULT '', state INTEGER NOT NULL DEFAULT 0,
        \\  received INTEGER NOT NULL DEFAULT 0, total INTEGER NOT NULL DEFAULT 0, started INTEGER NOT NULL,
        \\  owner_pid INTEGER NOT NULL, owner_birth INTEGER NOT NULL, source TEXT NOT NULL DEFAULT ''
        \\);
        \\CREATE TRIGGER IF NOT EXISTS limit_finished_downloads AFTER UPDATE OF state ON downloads WHEN NEW.state >= 2 BEGIN
        \\  DELETE FROM downloads WHERE state >= 2 AND id < (
        \\    SELECT id FROM downloads WHERE state >= 2 ORDER BY id DESC LIMIT 1 OFFSET 499
        \\  );
        \\END;
    ,null,null,null) != db_api.ok) return error.IOError;
    const needs_source = check: {
        const columns = try db_api.prepare(db,"SELECT 1 FROM pragma_table_info('downloads') WHERE name='source'");
        defer _ = sqlite.sqlite3_finalize(columns);
        break :check switch (sqlite.sqlite3_step(columns)) {
            db_api.row => false, db_api.done => true, else => return error.IOError,
        };
    };
    if (needs_source and sqlite.sqlite3_exec(db,"ALTER TABLE downloads ADD COLUMN source TEXT NOT NULL DEFAULT ''",null,null,null)!=db_api.ok)
        return error.IOError;
    if (sqlite.sqlite3_exec(db,"COMMIT",null,null,null)!=db_api.ok) return error.IOError;
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

pub fn sourceAllowed(url: []const u8) bool {
    return history.validURL(url) and std.mem.indexOfScalar(u8,url,'\\')==null;
}

fn freeSlot() ?*Active {
    for (&slots) |*entry| if (entry.id==0) return entry;
    return null;
}

pub fn begin(source: []const u8) u32 {
    const slot = freeSlot() orelse return 0;
    const db = connection() catch return 0;
    const statement = db_api.prepare(db,"INSERT INTO downloads(started,owner_pid,owner_birth,source) VALUES (?1,?2,?3,?4)") catch return 0;
    defer _ = sqlite.sqlite3_finalize(statement);
    bind(statement,1,native.moon_wall_ms()) catch return 0;
    bind(statement,2,process) catch return 0;
    bind(statement,3,birth) catch return 0;
    const url = if (sourceAllowed(source)) source[0..std.mem.indexOfScalar(u8,source,'#') orelse source.len] else "";
    db_api.bindText(statement,4,url) catch return 0;
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

pub fn list(allocator: std.mem.Allocator, options: sdk.DownloadQuery, buffer: *[24]sdk.Download) !sdk.DownloadPage {
    if (options.query.len > 256) return error.InvalidParams;
    flush();
    const statement = try db_api.prepare(try connection(),
        \\SELECT id,path,state,received,total,started,owner_pid,owner_birth,source FROM downloads
        \\WHERE id>0 AND id<?1 AND instr(lower(path),lower(?2)) ORDER BY id DESC
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
        const id: u32 = @intCast(number(statement,0));
        const state = readState(statement,id,2,6);
        const matches = switch (options.filter) {
            .all => true,
            .active => state == .choosing or state == .transferring,
            .complete => state == .complete,
            .unsuccessful => retryState(state),
        };
        if (!matches) continue;
        const filename = try db_api.columnText(statement,1);
        const name = if (std.mem.lastIndexOfAny(u8,filename,"\\/")) |index| filename[index+1..] else filename;
        if (name.len > 1200 or !std.unicode.utf8ValidateSlice(name)) continue;
        const cost = 6*name.len+192;
        if (length == buffer.len or cost > budget)
            return .{ .downloads=buffer[0..length],.next=buffer[length-1].id };
        const entry = lookup(id);
        const total = if (entry) |transfer| transfer.total else number(statement,4);
        buffer[length] = .{
            .id=id,.name=try allocator.dupe(u8,name),.state=state,
            .received=if (entry) |transfer| transfer.received else number(statement,3),
            .total=if (total != 0) total else null,.startedAt=number(statement,5),
            .cancellable=if (entry) |transfer| transfer.state == .transferring and !transfer.cancelling else false,
            .retryable=retryState(state) and sourceAllowed(try db_api.columnText(statement,8)),
        };
        length += 1;
        budget -= cost;
    }
}

fn retryState(state: State) bool {
    return state==.failed or state==.cancelled or state==.interrupted;
}

fn reserveRetry(id: u32, source: *[4096:0]u8) !void {
    const db = try connection();
    if (sqlite.sqlite3_exec(db,"BEGIN IMMEDIATE",null,null,null)!=db_api.ok) return error.IOError;
    errdefer _ = sqlite.sqlite3_exec(db,"ROLLBACK",null,null,null);
    {
        const statement = try db_api.prepare(db,"SELECT state,owner_pid,owner_birth,source FROM downloads WHERE id=?1");
        defer _ = sqlite.sqlite3_finalize(statement);
        try bind(statement,1,id);
        if (sqlite.sqlite3_step(statement)!=db_api.row or !retryState(readState(statement,id,0,1))) return error.NotFound;
        const url = try db_api.columnText(statement,3);
        if (!sourceAllowed(url)) return error.NotFound;
        _ = try std.fmt.bufPrintSentinel(source,"{s}",.{url},0);
    }
    const update = try db_api.prepare(db,"UPDATE downloads SET state=0,received=0,total=0,started=?1,owner_pid=?2,owner_birth=?3 WHERE id=?4");
    defer _ = sqlite.sqlite3_finalize(update);
    try bind(update,1,native.moon_wall_ms());
    try bind(update,2,process);
    try bind(update,3,birth);
    try bind(update,4,id);
    if (sqlite.sqlite3_step(update)!=db_api.done or sqlite.sqlite3_changes(db)!=1 or
        sqlite.sqlite3_exec(db,"COMMIT",null,null,null)!=db_api.ok) return error.IOError;
}

pub fn retry(id: u32) sdk.DownloadRetry {
    if (!native.moon_engine_retry_available()) return .busy;
    flush();
    const slot = freeSlot() orelse return .busy;
    var url: [4096:0]u8 = undefined;
    reserveRetry(id,&url) catch return .unavailable;
    slot.* = .{ .id=id };
    if (native.moon_engine_retry_download(id,&url)) return .started;
    finish(id,.failed);
    return .unavailable;
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

pub fn clearCompleted() !u32 {
    flush();
    const db = try connection();
    const statement = try db_api.prepare(db,"DELETE FROM downloads WHERE state=?1");
    defer _ = sqlite.sqlite3_finalize(statement);
    try bind(statement,1,@intFromEnum(State.complete));
    if (sqlite.sqlite3_step(statement) != db_api.done) return error.IOError;
    return @intCast(sqlite.sqlite3_changes(db));
}

pub fn completedPath(allocator: std.mem.Allocator, id: u32) ![:0]const u8 {
    const statement = try db_api.prepare(try connection(),"SELECT path FROM downloads WHERE id=?1 AND state=2");
    defer _ = sqlite.sqlite3_finalize(statement);
    try bind(statement,1,id);
    const result = sqlite.sqlite3_step(statement);
    if (result == db_api.done) return error.NotFound;
    if (result != db_api.row) return error.IOError;
    const filename = try db_api.columnText(statement,0);
    if (filename.len==0 or filename.len>=4096 or std.mem.indexOfScalar(u8,filename,0)!=null) return error.NotFound;
    return allocator.dupeSentinel(u8,filename,0);
}

pub fn reveal(allocator: std.mem.Allocator, id: u32) !void {
    const filename = try completedPath(allocator,id);
    if (!native.moon_shell_reveal_file(filename.ptr)) return error.NotFound;
}
