const std = @import("std");
const c = @import("c/sqlite.zig");
const err = @import("error.zig");
const Statement = @import("statement.zig").Statement;

/// SQL session over a local (or later remote) database handle.
/// Does not own the underlying handle when obtained via `Database.connect`.
pub const Connection = struct {
    db: *c.sqlite3,
    allocator: std.mem.Allocator,
    /// When true, `deinit` closes the handle (standalone open helper).
    owns_db: bool = false,

    pub fn deinit(self: *Connection) void {
        if (self.owns_db) {
            _ = c.sqlite3_close_v2(self.db);
        }
        self.* = undefined;
    }

    /// Execute one or more SQL statements with no result rows expected.
    /// `args` is currently unused (reserved for future expansion); pass `{}`.
    pub fn exec(self: *Connection, sql: []const u8, args: anytype) err.Error!void {
        _ = args;
        const zsql = self.allocator.dupeZ(u8, sql) catch return error.OutOfMemory;
        defer self.allocator.free(zsql);

        var errmsg_c: ?[*:0]u8 = null;
        const rc = c.sqlite3_exec(self.db, zsql.ptr, null, null, &errmsg_c);
        if (rc != c.SQLITE_OK) {
            if (errmsg_c) |e| {
                // Intentionally not logging content (may contain user data).
                c.sqlite3_free(e);
            }
            if (rc == c.SQLITE_NOMEM) return error.OutOfMemory;
            return error.Sql;
        }
    }

    pub fn prepare(self: *Connection, sql: []const u8) err.Error!Statement {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(
            self.db,
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
            .db = self.db,
            .stmt = stmt.?,
        };
    }

    /// Prepare, optional bind tuple, execute to completion, finalize.
    /// Pass `.{}` when there are no bind parameters.
    pub fn execute(self: *Connection, sql: []const u8, bind_args: anytype) err.Error!void {
        var stmt = try self.prepare(sql);
        defer stmt.deinit();
        const Args = @TypeOf(bind_args);
        const info = @typeInfo(Args);
        if (info == .@"struct" and info.@"struct".fields.len > 0) {
            try stmt.bind(bind_args);
        }
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
        return c.sqlite3_changes(self.db);
    }

    pub fn lastInsertRowid(self: *Connection) i64 {
        return c.sqlite3_last_insert_rowid(self.db);
    }
};
