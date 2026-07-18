const std = @import("std");
const Io = std.Io;
const c = @import("c/sqlite.zig");
const err = @import("error.zig");
const path_util = @import("util/path.zig");
const Connection = @import("connection.zig").Connection;
const remote = @import("backend/remote.zig");
const bridge = @import("backend/bridge.zig");

pub const OpenOptions = struct {
    /// File path, `:memory:`, `file:…`, or remote URL (`libsql://`, `https://`, …).
    path: []const u8,
    /// When set with a local `path`, enables classic embedded-replica mode:
    /// local file for reads + `Database.sync()` via the optional rusty bridge.
    /// Remote-only opens use `path` as the URL instead.
    sync_url: ?[]const u8 = null,
    /// Remote auth token (never logged). Required for most remote servers and
    /// required when `sync_url` is set (replica open).
    auth_token: ?[]const u8 = null,
    /// Allow a remote connection over plaintext (`http://` / `ws://`) transport.
    /// Off by default (fail closed): plaintext exposes SQL and results in
    /// cleartext. A bearer token is rejected over plaintext even when this is
    /// set — tokens always require HTTPS. Remote only; ignored for local.
    allow_insecure: bool = false,
    /// Open read-only (local only).
    read_only: bool = false,
    /// Create file if missing (local only; default true when not read_only).
    create: bool = true,
    /// Required for remote backends (HTTP). Ignored for pure local.
    /// Not required for replica open (sync uses the rusty cdylib, not Hrana).
    io: ?Io = null,
    /// Classic RYW while the libsql handle is alive during `sync()` (passed to bridge).
    read_your_writes: bool = true,
};

pub const SyncResult = bridge.SyncResult;

/// Owns a local database handle, a remote Hrana session, and/or replica sync config.
pub const Database = struct {
    allocator: std.mem.Allocator,
    /// Owned copy of the original open path (for diagnostics / local file).
    path: []const u8,
    kind: path_util.Kind,
    local_db: ?*c.sqlite3 = null,
    session: ?*remote.Session = null,
    /// Replica: owned primary URL for `sync()` (null if not a replica).
    sync_url: ?[]const u8 = null,
    /// Owned token for replica sync (never logged).
    auth_token: ?[]const u8 = null,
    read_your_writes: bool = true,
    /// Local open flags restored after `sync()` reopens the file.
    local_flags: c_int = 0,

    pub fn open(allocator: std.mem.Allocator, opts: OpenOptions) err.Error!Database {
        const parsed = path_util.parse(opts.path);

        // Classic embedded replica: local file + sync_url.
        if (opts.sync_url) |surl| {
            if (parsed.kind != .file) return error.InvalidPath;
            if (opts.auth_token == null) return error.InvalidPath;
            if (surl.len == 0) return error.InvalidPath;
            // Fail closed if bridge was not compiled in.
            if (!bridge.isCompileEnabled()) return error.Unsupported;

            const path_owned = allocator.dupe(u8, parsed.path) catch return error.OutOfMemory;
            errdefer allocator.free(path_owned);
            const surl_owned = allocator.dupe(u8, surl) catch return error.OutOfMemory;
            errdefer allocator.free(surl_owned);
            const token_owned = allocator.dupe(u8, opts.auth_token.?) catch return error.OutOfMemory;
            errdefer allocator.free(token_owned);

            var flags: c_int = 0;
            if (opts.read_only) {
                flags |= c.SQLITE_OPEN_READONLY;
            } else {
                flags |= c.SQLITE_OPEN_READWRITE;
                if (opts.create) flags |= c.SQLITE_OPEN_CREATE;
            }
            flags |= c.SQLITE_OPEN_URI;
            flags |= c.SQLITE_OPEN_FULLMUTEX;

            const local = try openLocalPath(allocator, path_owned, flags);
            return .{
                .allocator = allocator,
                .path = path_owned,
                .kind = .file,
                .local_db = local,
                .sync_url = surl_owned,
                .auth_token = token_owned,
                .read_your_writes = opts.read_your_writes,
                .local_flags = flags,
            };
        }

        const path_owned = allocator.dupe(u8, opts.path) catch return error.OutOfMemory;
        errdefer allocator.free(path_owned);

        switch (parsed.kind) {
            .remote => {
                const io = opts.io orelse return error.Unsupported;
                // Fail-closed transport is enforced inside Session.open
                // (token always requires HTTPS; tokenless plaintext needs allow_insecure).
                const session_ptr = allocator.create(remote.Session) catch return error.OutOfMemory;
                errdefer allocator.destroy(session_ptr);
                session_ptr.* = try remote.Session.open(io, allocator, opts.path, opts.auth_token, opts.allow_insecure);
                return .{
                    .allocator = allocator,
                    .path = path_owned,
                    .kind = .remote,
                    .session = session_ptr,
                };
            },
            .memory, .file => {
                const open_path = if (parsed.kind == .memory) ":memory:" else parsed.path;
                var flags: c_int = 0;
                if (opts.read_only) {
                    flags |= c.SQLITE_OPEN_READONLY;
                } else {
                    flags |= c.SQLITE_OPEN_READWRITE;
                    if (opts.create) flags |= c.SQLITE_OPEN_CREATE;
                }
                flags |= c.SQLITE_OPEN_URI;
                flags |= c.SQLITE_OPEN_FULLMUTEX;

                const local = try openLocalPath(allocator, open_path, flags);
                return .{
                    .allocator = allocator,
                    .path = path_owned,
                    .kind = parsed.kind,
                    .local_db = local,
                    .local_flags = flags,
                };
            },
        }
    }

    pub fn deinit(self: *Database) void {
        if (self.local_db) |db| {
            _ = c.sqlite3_close_v2(db);
            self.local_db = null;
        }
        if (self.session) |s| {
            s.deinit();
            self.allocator.destroy(s);
        }
        if (self.sync_url) |u| self.allocator.free(u);
        if (self.auth_token) |t| self.allocator.free(t);
        self.allocator.free(self.path);
        self.* = undefined;
    }

    /// Non-owning connection view. Do not use after `Database.deinit` or during `sync()`.
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

    pub fn isReplica(self: *const Database) bool {
        return self.sync_url != null;
    }

    /// Classic embedded replica pull via the rusty bridge (R1).
    ///
    /// Closes the local SQLite handle for the duration of sync (official clients
    /// forbid concurrent open during inject), then reopens it.
    ///
    /// Requires `-Denable-rust-bridge=true` and a loadable `liblibsql_bridge` cdylib.
    pub fn sync(self: *Database) err.Error!SyncResult {
        const surl = self.sync_url orelse return error.Unsupported;
        const token = self.auth_token orelse return error.Unsupported;

        // Exclusive: no concurrent local use during inject.
        if (self.local_db) |db| {
            _ = c.sqlite3_close_v2(db);
            self.local_db = null;
        }

        const result = bridge.syncOnce(self.path, surl, token, self.read_your_writes) catch |e| {
            // Best-effort reopen so the Database remains usable after a failed sync.
            self.local_db = openLocalPath(self.allocator, self.path, self.local_flags) catch null;
            return e;
        };

        self.local_db = try openLocalPath(self.allocator, self.path, self.local_flags);
        return result;
    }
};

fn openLocalPath(allocator: std.mem.Allocator, open_path: []const u8, flags: c_int) err.Error!*c.sqlite3 {
    const zpath = allocator.dupeZ(u8, open_path) catch return error.OutOfMemory;
    defer allocator.free(zpath);

    var db_ptr: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open_v2(zpath.ptr, &db_ptr, flags, null);
    if (rc != c.SQLITE_OK or db_ptr == null) {
        if (db_ptr) |d| _ = c.sqlite3_close(d);
        if (rc == c.SQLITE_NOMEM) return error.OutOfMemory;
        return error.Open;
    }
    return db_ptr.?;
}

/// Convenience: open a local path (or `:memory:`) as an owning `Connection`.
/// Remote URLs and replica mode are not supported here — use `Database.open`.
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

test "replica open without bridge is Unsupported" {
    if (bridge.isCompileEnabled()) return;
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.Unsupported, Database.open(gpa, .{
        .path = "/tmp/zig-libsql-replica-test.db",
        .sync_url = "libsql://example.turso.io",
        .auth_token = "secret",
    }));
}

test "replica open requires auth_token" {
    if (!bridge.isCompileEnabled()) return;
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidPath, Database.open(gpa, .{
        .path = "/tmp/zig-libsql-replica-test.db",
        .sync_url = "libsql://example.turso.io",
    }));
}
