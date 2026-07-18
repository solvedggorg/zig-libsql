const std = @import("std");
const Io = std.Io;
const c = @import("c/sqlite.zig");
const err = @import("error.zig");
const path_util = @import("util/path.zig");
const Connection = @import("connection.zig").Connection;
const remote = @import("backend/remote.zig");

pub const OpenOptions = struct {
    /// File path, `:memory:`, `file:…`, or remote URL (`libsql://`, `https://`, …).
    path: []const u8,
    /// Remote auth token (never logged). Required for most remote servers.
    auth_token: ?[]const u8 = null,
    /// Open read-only (local only).
    read_only: bool = false,
    /// Create file if missing (local only; default true when not read_only).
    create: bool = true,
    /// Required for remote backends (HTTP). Ignored for local.
    io: ?Io = null,
};

/// Owns a local database handle or a remote Hrana session.
pub const Database = struct {
    allocator: std.mem.Allocator,
    /// Owned copy of the original open path (for diagnostics).
    path: []const u8,
    kind: path_util.Kind,
    local_db: ?*c.sqlite3 = null,
    session: ?*remote.Session = null,

    pub fn open(allocator: std.mem.Allocator, opts: OpenOptions) err.Error!Database {
        const parsed = path_util.parse(opts.path);

        const path_owned = allocator.dupe(u8, opts.path) catch return error.OutOfMemory;
        errdefer allocator.free(path_owned);

        switch (parsed.kind) {
            .remote => {
                const io = opts.io orelse return error.Unsupported;
                const session_ptr = allocator.create(remote.Session) catch return error.OutOfMemory;
                errdefer allocator.destroy(session_ptr);
                session_ptr.* = try remote.Session.open(io, allocator, opts.path, opts.auth_token);
                return .{
                    .allocator = allocator,
                    .path = path_owned,
                    .kind = .remote,
                    .session = session_ptr,
                };
            },
            .memory, .file => {
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
                    .kind = parsed.kind,
                    .local_db = db_ptr.?,
                };
            },
        }
    }

    pub fn deinit(self: *Database) void {
        if (self.local_db) |db| {
            _ = c.sqlite3_close_v2(db);
        }
        if (self.session) |s| {
            s.deinit();
            self.allocator.destroy(s);
        }
        self.allocator.free(self.path);
        self.* = undefined;
    }

    /// Non-owning connection view. Do not use after `Database.deinit`.
    pub fn connect(self: *Database) Connection {
        return switch (self.kind) {
            .remote => .{
                .allocator = self.allocator,
                .kind = .remote,
                .session = self.session,
            },
            .memory, .file => .{
                .allocator = self.allocator,
                .kind = .local,
                .db = self.local_db,
                .owns_db = false,
            },
        };
    }

    pub fn isRemote(self: *const Database) bool {
        return self.kind == .remote;
    }
};

/// Convenience: open a local path (or `:memory:`) as an owning `Connection`.
/// Remote URLs are not supported here — use `Database.open` with `io`.
pub fn open(allocator: std.mem.Allocator, path: []const u8) err.Error!Connection {
    const parsed = path_util.parse(path);
    if (parsed.kind == .remote) return error.Unsupported;

    var db = try Database.open(allocator, .{ .path = path });
    const conn = Connection{
        .allocator = allocator,
        .kind = .local,
        .db = db.local_db,
        .owns_db = true,
    };
    allocator.free(db.path);
    db.local_db = null;
    db = undefined;
    return conn;
}
