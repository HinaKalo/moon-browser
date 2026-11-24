const std = @import("std");

pub const Database = opaque {};
pub const Statement = opaque {};
pub const Link = struct { title: []const u8, url: []const u8 };
const Sqlite = struct {
    sqlite3_open: *const fn ([*:0]const u8,*?*Database) callconv(.c) c_int,
    sqlite3_open_v2: *const fn ([*:0]const u8,*?*Database,c_int,?[*:0]const u8) callconv(.c) c_int,
    sqlite3_close: *const fn (*Database) callconv(.c) c_int,
    sqlite3_busy_timeout: *const fn (*Database,c_int) callconv(.c) c_int,
    sqlite3_exec: *const fn (*Database,[*:0]const u8,?*anyopaque,?*anyopaque,?*anyopaque) callconv(.c) c_int,
    sqlite3_prepare_v2: *const fn (*Database,[*:0]const u8,c_int,*?*Statement,?*anyopaque) callconv(.c) c_int,
    sqlite3_finalize: *const fn (*Statement) callconv(.c) c_int,
    sqlite3_bind_int64: *const fn (*Statement,c_int,i64) callconv(.c) c_int,
    sqlite3_bind_text: *const fn (*Statement,c_int,[*]const u8,c_int,?*anyopaque) callconv(.c) c_int,
    sqlite3_step: *const fn (*Statement) callconv(.c) c_int,
    sqlite3_reset: *const fn (*Statement) callconv(.c) c_int,
    sqlite3_column_int64: *const fn (*Statement,c_int) callconv(.c) i64,
    sqlite3_column_text: *const fn (*Statement,c_int) callconv(.c) ?[*:0]const u8,
    sqlite3_column_bytes: *const fn (*Statement,c_int) callconv(.c) c_int,
    sqlite3_changes: *const fn (*Database) callconv(.c) c_int,
    sqlite3_last_insert_rowid: *const fn (*Database) callconv(.c) i64,
};

extern "kernel32" fn LoadLibraryExW([*:0]const u16,?*anyopaque,u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(*anyopaque,[*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn FreeLibrary(*anyopaque) callconv(.winapi) c_int;

pub const ok = 0;
pub const row = 100;
pub const done = 101;
pub var sqlite: Sqlite = undefined;
var loaded = false;

fn load() !void {
    if (loaded) return;
    const system32 = 0x00000800;
    const module = LoadLibraryExW(std.unicode.utf8ToUtf16LeStringLiteral("winsqlite3.dll"),null,system32) orelse return error.IOError;
    errdefer _ = FreeLibrary(module);
    inline for (@typeInfo(Sqlite).@"struct".field_names) |name| {
        @field(sqlite,name) = @ptrCast(GetProcAddress(module,name) orelse return error.IOError);
    }
    loaded = true;
}

pub fn openReadOnly(path: [:0]const u8) !*Database {
    if (path.len == 0) return error.IOError;
    try load();
    const read_only = 0x01;
    var handle: ?*Database = null;
    const opened = sqlite.sqlite3_open_v2(path.ptr,&handle,read_only,null);
    const db = handle orelse return error.IOError;
    errdefer close(db);
    if (opened != ok) return error.IOError;
    return db;
}

pub fn open(path: [:0]const u8) !*Database {
    if (path.len == 0) return error.IOError;
    try load();
    var handle: ?*Database = null;
    const opened = sqlite.sqlite3_open(path.ptr,&handle);
    const db = handle orelse return error.IOError;
    errdefer close(db);
    if (opened != ok or sqlite.sqlite3_busy_timeout(db,25) != ok) return error.IOError;
    if (sqlite.sqlite3_exec(db,"PRAGMA secure_delete=ON; PRAGMA cache_size=-256;",null,null,null) != ok) return error.IOError;
    return db;
}

pub fn close(db: *Database) void {
    _ = sqlite.sqlite3_close(db);
}

pub fn prepare(db: *Database, sql: [:0]const u8) !*Statement {
    var statement: ?*Statement = null;
    if (sqlite.sqlite3_prepare_v2(db,sql.ptr,-1,&statement,null) != ok) return error.IOError;
    return statement orelse error.IOError;
}

pub fn bindText(statement: *Statement, index: c_int, value: []const u8) !void {
    const address = if (value.len == 0) "".ptr else value.ptr;
    if (sqlite.sqlite3_bind_text(statement,index,address,@intCast(value.len),null) != ok) return error.IOError;
}

pub fn columnText(statement: *Statement, index: c_int) ![]const u8 {
    const value = sqlite.sqlite3_column_text(statement,index) orelse return error.IOError;
    return value[0..@intCast(sqlite.sqlite3_column_bytes(statement,index))];
}

pub fn findLinks(allocator: std.mem.Allocator, db: *Database, sql: [:0]const u8,
    query: []const u8, output: []Link) ![]Link {
    // Suggestions can be skipped if another process is holding the profile database.
    _=sqlite.sqlite3_busy_timeout(db,0);
    defer _=sqlite.sqlite3_busy_timeout(db,25);
    const statement=try prepare(db,sql);
    defer _=sqlite.sqlite3_finalize(statement);
    try bindText(statement,1,query);
    if (sqlite.sqlite3_bind_int64(statement,2,@intCast(output.len))!=ok) return error.IOError;
    var length: usize=0;
    while (length<output.len) {
        switch (sqlite.sqlite3_step(statement)) {
            done => break,
            row => {},
            else => return error.IOError,
        }
        const title=try columnText(statement,0);
        const url=try columnText(statement,1);
        if (title.len>511 or url.len>4095) continue;
        output[length]=.{ .title=try allocator.dupe(u8,title),.url=try allocator.dupe(u8,url) };
        length+=1;
    }
    return output[0..length];
}
