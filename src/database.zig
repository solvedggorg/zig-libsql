const std = @import("std");
const c = @import("c/sqlite.zig");
const err = @import("error.zig");
const path_util = @import("util/path.zig");
const Connection = @import("connection.zig").Connection;

pub const OpenOptions = struct {
    /// File path, `:memory:`, `file:…`, or remote URL (remote → Phase 2).
    path: []const u8,
    /// Remote auth token (never logged). Ignored for local until Phase 2.
    auth_token: ?[]const u8 = null,
    /// Open read-only (local only).
    read_only: bool = false,
    /// Create file if missing (local only; default true when not read_only).
    create: bool = true,
};

/// Owns a local database handle. Call `connect` for the SQL surface.
pub const Database = struct {
    allocator: std.mem.Allocator,
    /// Owned copy of the resolved open path (for diagnostics).
    path: []const u8,
    db: *c.sqlite3,
    kind: path_util.Kind,

    pub fn open(allocator: std.mem.Allocator, opts: OpenOptions) err.Error!Database {
        const parsed = path_util.parse(opts.path);
        switch (parsed.kind) {
            .remote => return error.Unsupported,
            .memory, .file => {},
        }

        const path_owned = allocator.dupe(u8, opts.path) catch return error.OutOfMemory;
        errdefer allocator.free(path_owned);

        const open_path = if (parsed.kind == .memory) ":memory:" else parsed.path;
        const zpath = allocator.dupeZ(u8, open_path) catch return error.OutOfMemory;
        defer allocator.free(zpath);

        var flags: c_int = 0;
        if (opts.read_only) {
            flags |= c.SQLITE_OPEN_READONLY;
        } else {
            flags |= c.SQLITE_OPEN_READWRITE;
            if (opts.create) flags |= c.SQLITE_OPEN_CREATE;
        }
        // Allow URI filenames when callers pass file:… (we already stripped most).
        flags |= c.SQLITE_OPEN_URI;
        flags |= c.SQLITE_OPEN_FULLMUTEX;

        var db_ptr: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(zpath.ptr, &db_ptr, flags, null);
        if (rc != c.SQLITE_OK or db_ptr == null) {
            if (db_ptr) |d| _ = c.sqlite3_close(d);
            if (rc == c.SQLITE_NOMEM) return error.OutOfMemory;
            return error.Open;
        }

        return .{
            .allocator = allocator,
            .path = path_owned,
            .db = db_ptr.?,
            .kind = parsed.kind,
        };
    }

    pub fn deinit(self: *Database) void {
        _ = c.sqlite3_close_v2(self.db);
        self.allocator.free(self.path);
        self.* = undefined;
    }

    /// Non-owning connection view. Do not use after `Database.deinit`.
    pub fn connect(self: *Database) Connection {
        return .{
            .db = self.db,
            .allocator = self.allocator,
            .owns_db = false,
        };
    }

    pub fn isRemote(self: *const Database) bool {
        return self.kind == .remote;
    }
};

/// Convenience: open a local path (or `:memory:`) as an owning `Connection`.
pub fn open(allocator: std.mem.Allocator, path: []const u8) err.Error!Connection {
    var db = try Database.open(allocator, .{ .path = path });
    // Transfer ownership into Connection.
    const conn = Connection{
        .db = db.db,
        .allocator = allocator,
        .owns_db = true,
    };
    allocator.free(db.path);
    // Do not call db.deinit (would close). Null out to be safe.
    db = undefined;
    return conn;
}
