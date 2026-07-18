const std = @import("std");
const c = @import("c/sqlite.zig");
const err = @import("error.zig");

/// A single row from a stepped statement. Borrowed: invalid after next step/reset/deinit.
pub const Row = struct {
    stmt: *c.sqlite3_stmt,

    pub fn columnCount(self: Row) usize {
        return @intCast(c.sqlite3_column_count(self.stmt));
    }

    pub fn columnType(self: Row, col: usize) err.Error!c_int {
        _ = try self.checkCol(col);
        return c.sqlite3_column_type(self.stmt, @intCast(col));
    }

    pub fn isNull(self: Row, col: usize) err.Error!bool {
        return (try self.columnType(col)) == c.SQLITE_NULL;
    }

    pub fn int(self: Row, col: usize) err.Error!i64 {
        _ = try self.checkCol(col);
        return c.sqlite3_column_int64(self.stmt, @intCast(col));
    }

    pub fn float(self: Row, col: usize) err.Error!f64 {
        _ = try self.checkCol(col);
        return c.sqlite3_column_double(self.stmt, @intCast(col));
    }

    /// Text valid until the next step/reset/finalize on the parent statement.
    pub fn text(self: Row, col: usize) err.Error!?[]const u8 {
        _ = try self.checkCol(col);
        if (c.sqlite3_column_type(self.stmt, @intCast(col)) == c.SQLITE_NULL) return null;
        const ptr = c.sqlite3_column_text(self.stmt, @intCast(col)) orelse return null;
        const n = c.sqlite3_column_bytes(self.stmt, @intCast(col));
        if (n < 0) return null;
        return ptr[0..@intCast(n)];
    }

    /// Blob valid until the next step/reset/finalize on the parent statement.
    pub fn blob(self: Row, col: usize) err.Error!?[]const u8 {
        _ = try self.checkCol(col);
        if (c.sqlite3_column_type(self.stmt, @intCast(col)) == c.SQLITE_NULL) return null;
        const n = c.sqlite3_column_bytes(self.stmt, @intCast(col));
        if (n <= 0) {
            // empty blob vs null already handled
            if (n == 0) return &[_]u8{};
            return null;
        }
        const ptr = c.sqlite3_column_blob(self.stmt, @intCast(col)) orelse return &[_]u8{};
        return ptr[0..@intCast(n)];
    }

    pub fn columnName(self: Row, col: usize) err.Error![]const u8 {
        _ = try self.checkCol(col);
        const name = c.sqlite3_column_name(self.stmt, @intCast(col)) orelse return error.Sql;
        return std.mem.span(name);
    }

    fn checkCol(self: Row, col: usize) err.Error!void {
        const n: usize = @intCast(c.sqlite3_column_count(self.stmt));
        if (col >= n) return error.Bind;
    }
};
