const std = @import("std");
const c = @import("c/sqlite.zig");

pub const Error = error{
    /// Failed to open the database file or memory handle.
    Open,
    /// SQL execution failed (exec / step / prepare / bind).
    Sql,
    /// Parameter index out of range or bind type mismatch.
    Bind,
    /// Requested backend is not available yet (e.g. remote Hrana).
    Unsupported,
    /// Invalid path / URI for open.
    InvalidPath,
    OutOfMemory,
};

/// Map a SQLite result code to a library error when non-OK.
pub fn mapRc(rc: c_int) Error!void {
    if (rc == c.SQLITE_OK) return;
    // mapRc runs on statement-time paths (bind/reset/step); Database.open maps
    // its own result codes. So SQLITE_CANTOPEN/PERM/NOTADB seen here are runtime
    // SQL failures, not a failed open, and must map to Sql rather than Open.
    return switch (rc) {
        c.SQLITE_NOMEM => error.OutOfMemory,
        c.SQLITE_RANGE => error.Bind,
        else => error.Sql,
    };
}

pub fn errmsg(db: ?*c.sqlite3) []const u8 {
    if (db) |d| return std.mem.span(c.sqlite3_errmsg(d));
    return "unknown sqlite error";
}

pub fn errstr(rc: c_int) []const u8 {
    return std.mem.span(c.sqlite3_errstr(rc));
}
