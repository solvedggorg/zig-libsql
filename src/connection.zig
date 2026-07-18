const std = @import("std");
const c = @import("c/sqlite.zig");
const err = @import("error.zig");
const Statement = @import("statement.zig").Statement;
const remote = @import("backend/remote.zig");

/// SQL session over a local or remote database handle.
/// Does not own the underlying handle when obtained via `Database.connect`
/// (unless `owns_db` is true for the local convenience opener).
pub const Connection = struct {
    allocator: std.mem.Allocator,
    kind: enum { local, remote },
    // local
    db: ?*c.sqlite3 = null,
    owns_db: bool = false,
    // remote (pointer into Database-owned Session)
    session: ?*remote.Session = null,

    pub fn deinit(self: *Connection) void {
        if (self.kind == .local and self.owns_db) {
            _ = c.sqlite3_close_v2(self.db.?);
        }
        self.* = undefined;
    }

    /// Execute one or more SQL statements with no result rows expected.
    /// `args` is reserved; pass `{}`.
    pub fn exec(self: *Connection, sql: []const u8, args: anytype) err.Error!void {
        _ = args;
        switch (self.kind) {
            .local => {
                const zsql = self.allocator.dupeZ(u8, sql) catch return error.OutOfMemory;
                defer self.allocator.free(zsql);

                var errmsg_c: ?[*:0]u8 = null;
                const rc = c.sqlite3_exec(self.db.?, zsql.ptr, null, null, &errmsg_c);
                if (rc != c.SQLITE_OK) {
                    if (errmsg_c) |e| c.sqlite3_free(e);
                    if (rc == c.SQLITE_NOMEM) return error.OutOfMemory;
                    return error.Sql;
                }
            },
            .remote => try self.session.?.sequence(sql),
        }
    }

    pub fn prepare(self: *Connection, sql: []const u8) err.Error!Statement {
        switch (self.kind) {
            .local => {
                var stmt: ?*c.sqlite3_stmt = null;
                const rc = c.sqlite3_prepare_v2(
                    self.db.?,
                    sql.ptr,
                    @intCast(sql.len),
                    &stmt,
                    null,
                );
                if (rc != c.SQLITE_OK or stmt == null) {
                    if (rc == c.SQLITE_NOMEM) return error.OutOfMemory;
                    return error.Sql;
                }
                return .{
                    .kind = .local,
                    .allocator = self.allocator,
                    .db = self.db,
                    .stmt = stmt.?,
                };
            },
            .remote => {
                const sql_owned = self.allocator.dupe(u8, sql) catch return error.OutOfMemory;
                return .{
                    .kind = .remote,
                    .allocator = self.allocator,
                    .session = self.session,
                    .sql = sql_owned,
                };
            },
        }
    }

    /// Prepare, optional bind tuple, execute to completion, finalize.
    /// Pass `.{}` when there are no bind parameters.
    pub fn execute(self: *Connection, sql: []const u8, bind_args: anytype) err.Error!void {
        var stmt = try self.prepare(sql);
        defer stmt.deinit();
        // Bind unconditionally so empty args and invalid shapes are validated
        // against the statement's parameter count (fail closed).
        try stmt.bind(bind_args);
        try stmt.execute();
    }

    pub fn begin(self: *Connection) err.Error!void {
        try self.exec("BEGIN;", .{});
    }

    pub fn commit(self: *Connection) err.Error!void {
        try self.exec("COMMIT;", .{});
    }

    pub fn rollback(self: *Connection) err.Error!void {
        try self.exec("ROLLBACK;", .{});
    }

    pub fn changes(self: *Connection) i64 {
        return switch (self.kind) {
            .local => c.sqlite3_changes(self.db.?),
            .remote => self.session.?.last_affected,
        };
    }

    pub fn lastInsertRowid(self: *Connection) i64 {
        return switch (self.kind) {
            .local => c.sqlite3_last_insert_rowid(self.db.?),
            .remote => self.session.?.last_insert_rowid,
        };
    }
};
