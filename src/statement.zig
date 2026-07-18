const std = @import("std");
const c = @import("c/sqlite.zig");
const err = @import("error.zig");
const value = @import("value.zig");
const rows = @import("rows.zig");
const remote = @import("backend/remote.zig");
const pipeline = @import("backend/hrana/pipeline.zig");

pub const Statement = struct {
    kind: enum { local, remote },
    allocator: std.mem.Allocator,

    // local
    db: ?*c.sqlite3 = null,
    stmt: ?*c.sqlite3_stmt = null,

    // remote
    session: ?*remote.Session = null,
    sql: ?[]u8 = null,
    binds: std.ArrayListUnmanaged(value.Value) = .empty,
    /// Owned string/blob storage for bind values that need ownership.
    bind_storage: std.ArrayListUnmanaged([]u8) = .empty,
    result: ?pipeline.StmtResult = null,
    row_index: usize = 0,

    done: bool = false,

    pub fn deinit(self: *Statement) void {
        switch (self.kind) {
            .local => {
                if (self.stmt) |s| _ = c.sqlite3_finalize(s);
            },
            .remote => {
                if (self.result) |*r| r.deinit(self.allocator);
                if (self.sql) |s| self.allocator.free(s);
                for (self.bind_storage.items) |s| self.allocator.free(s);
                self.bind_storage.deinit(self.allocator);
                self.binds.deinit(self.allocator);
            },
        }
        self.* = undefined;
    }

    pub fn reset(self: *Statement) err.Error!void {
        switch (self.kind) {
            .local => {
                try err.mapRc(c.sqlite3_reset(self.stmt.?));
            },
            .remote => {
                if (self.result) |*r| {
                    r.deinit(self.allocator);
                    self.result = null;
                }
                self.row_index = 0;
            },
        }
        self.done = false;
    }

    pub fn clearBindings(self: *Statement) err.Error!void {
        switch (self.kind) {
            .local => try err.mapRc(c.sqlite3_clear_bindings(self.stmt.?)),
            .remote => {
                for (self.bind_storage.items) |s| self.allocator.free(s);
                self.bind_storage.clearRetainingCapacity();
                self.binds.clearRetainingCapacity();
            },
        }
    }

    pub fn bindNull(self: *Statement, idx: usize) err.Error!void {
        switch (self.kind) {
            .local => try err.mapRc(c.sqlite3_bind_null(self.stmt.?, @intCast(idx))),
            .remote => try self.remoteSet(idx, .{ .null = {} }),
        }
    }

    pub fn bindInt(self: *Statement, idx: usize, v: i64) err.Error!void {
        switch (self.kind) {
            .local => try err.mapRc(c.sqlite3_bind_int64(self.stmt.?, @intCast(idx), v)),
            .remote => try self.remoteSet(idx, .{ .integer = v }),
        }
    }

    pub fn bindFloat(self: *Statement, idx: usize, v: f64) err.Error!void {
        switch (self.kind) {
            .local => try err.mapRc(c.sqlite3_bind_double(self.stmt.?, @intCast(idx), v)),
            .remote => try self.remoteSet(idx, .{ .float = v }),
        }
    }

    pub fn bindText(self: *Statement, idx: usize, text: []const u8) err.Error!void {
        switch (self.kind) {
            .local => {
                const destructor: ?*const anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, c.SQLITE_TRANSIENT))));
                const rc = c.sqlite3_bind_text(
                    self.stmt.?,
                    @intCast(idx),
                    if (text.len == 0) "" else text.ptr,
                    @intCast(text.len),
                    destructor,
                );
                try err.mapRc(rc);
            },
            .remote => {
                if (idx == 0) return error.Bind;
                const owned = self.allocator.dupe(u8, text) catch return error.OutOfMemory;
                errdefer self.allocator.free(owned);
                // Reserve capacity in both collections before mutating either, so
                // no grow can fail after bind_storage has taken ownership of
                // `owned` (which would double-free it via deinit).
                try self.binds.ensureTotalCapacity(self.allocator, idx);
                try self.bind_storage.ensureUnusedCapacity(self.allocator, 1);
                self.bind_storage.appendAssumeCapacity(owned);
                self.remoteSetAssumeCapacity(idx, .{ .text = owned });
            },
        }
    }

    pub fn bindBlob(self: *Statement, idx: usize, blob: []const u8) err.Error!void {
        switch (self.kind) {
            .local => {
                const destructor: ?*const anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, c.SQLITE_TRANSIENT))));
                // Always pass a non-null data pointer: a null pointer makes a
                // zero-length blob bind as SQL NULL instead of an empty blob.
                const data: [*]const u8 = if (blob.len == 0) &[_]u8{} else blob.ptr;
                const rc = c.sqlite3_bind_blob(
                    self.stmt.?,
                    @intCast(idx),
                    data,
                    @intCast(blob.len),
                    destructor,
                );
                try err.mapRc(rc);
            },
            .remote => {
                if (idx == 0) return error.Bind;
                const owned = self.allocator.dupe(u8, blob) catch return error.OutOfMemory;
                errdefer self.allocator.free(owned);
                // Reserve capacity in both collections before mutating either, so
                // no grow can fail after bind_storage has taken ownership of
                // `owned` (which would double-free it via deinit).
                try self.binds.ensureTotalCapacity(self.allocator, idx);
                try self.bind_storage.ensureUnusedCapacity(self.allocator, 1);
                self.bind_storage.appendAssumeCapacity(owned);
                self.remoteSetAssumeCapacity(idx, .{ .blob = owned });
            },
        }
    }

    pub fn bindValue(self: *Statement, idx: usize, v: value.Value) err.Error!void {
        switch (v) {
            .null => try self.bindNull(idx),
            .integer => |i| try self.bindInt(idx, i),
            .float => |f| try self.bindFloat(idx, f),
            .text => |t| try self.bindText(idx, t),
            .blob => |b| try self.bindBlob(idx, b),
        }
    }

    fn remoteSet(self: *Statement, idx: usize, v: value.Value) err.Error!void {
        if (idx == 0) return error.Bind;
        const i = idx - 1;
        while (self.binds.items.len <= i) {
            try self.binds.append(self.allocator, .{ .null = {} });
        }
        self.binds.items[i] = v;
    }

    /// Like `remoteSet` but assumes `binds` already has capacity for `idx`
    /// elements (caller must `ensureTotalCapacity(idx)` first), so it cannot
    /// fail and cannot leave partially-owned storage behind.
    fn remoteSetAssumeCapacity(self: *Statement, idx: usize, v: value.Value) void {
        const i = idx - 1;
        while (self.binds.items.len <= i) self.binds.appendAssumeCapacity(.{ .null = {} });
        self.binds.items[i] = v;
    }

    pub fn bind(self: *Statement, args: anytype) err.Error!void {
        const Args = @TypeOf(args);
        const info = @typeInfo(Args);
        switch (info) {
            .@"struct" => |s| {
                // Fail closed: the argument count must match the statement's
                // parameter count so omitted values are not silently bound NULL.
                if (s.fields.len != self.parameterCount()) return error.Bind;
                inline for (s.fields, 0..) |field, i| {
                    const idx = i + 1;
                    const field_val = @field(args, field.name);
                    try bindAny(self, idx, field_val);
                }
            },
            else => @compileError("bind expects a tuple or struct of bind values"),
        }
    }

    fn bindAny(self: *Statement, idx: usize, field_val: anytype) err.Error!void {
        const T = @TypeOf(field_val);
        if (T == value.Value) {
            try self.bindValue(idx, field_val);
            return;
        }
        if (T == @TypeOf(null)) {
            try self.bindNull(idx);
            return;
        }
        const ti = @typeInfo(T);
        switch (ti) {
            .null => try self.bindNull(idx),
            .optional => {
                if (field_val) |v| {
                    try bindAny(self, idx, v);
                } else {
                    try self.bindNull(idx);
                }
            },
            .int, .comptime_int => try self.bindInt(idx, @intCast(field_val)),
            .float, .comptime_float => try self.bindFloat(idx, @floatCast(field_val)),
            .pointer => |ptr| {
                if (ptr.size == .slice and ptr.child == u8) {
                    try self.bindText(idx, field_val);
                    return;
                }
                if (ptr.size == .one) {
                    const child = @typeInfo(ptr.child);
                    if (child == .array and child.array.child == u8) {
                        try self.bindText(idx, field_val.*[0..]);
                        return;
                    }
                }
                @compileError("unsupported bind pointer type: " ++ @typeName(T));
            },
            .array => |arr| {
                if (arr.child == u8) {
                    try self.bindText(idx, field_val[0..]);
                    return;
                }
                @compileError("unsupported bind array type: " ++ @typeName(T));
            },
            else => @compileError("unsupported bind type: " ++ @typeName(T)),
        }
    }

    pub fn step(self: *Statement) err.Error!?rows.Row {
        if (self.done) return null;
        switch (self.kind) {
            .local => {
                const rc = c.sqlite3_step(self.stmt.?);
                switch (rc) {
                    c.SQLITE_ROW => return rows.Row{ .kind = .local, .local_stmt = self.stmt },
                    c.SQLITE_DONE => {
                        self.done = true;
                        return null;
                    },
                    else => {
                        try err.mapRc(rc);
                        unreachable;
                    },
                }
            },
            .remote => {
                if (self.result == null) {
                    try self.fetchRemote(true);
                }
                const res = self.result.?;
                if (self.row_index >= res.rows.len) {
                    self.done = true;
                    return null;
                }
                const row = rows.Row{
                    .kind = .remote,
                    .remote_cells = res.rows[self.row_index],
                    .remote_col_names = res.cols,
                };
                self.row_index += 1;
                return row;
            },
        }
    }

    pub fn execute(self: *Statement) err.Error!void {
        // sqlite3_step auto-resets a completed statement, so guard against
        // re-running the same DML on a second execute() call.
        if (self.done) return;
        switch (self.kind) {
            .local => {
                while (true) {
                    const rc = c.sqlite3_step(self.stmt.?);
                    switch (rc) {
                        c.SQLITE_DONE => {
                            self.done = true;
                            return;
                        },
                        c.SQLITE_ROW => {
                            // Drain unexpected rows then error.
                            while (c.sqlite3_step(self.stmt.?) == c.SQLITE_ROW) {}
                            return error.Sql;
                        },
                        else => {
                            try err.mapRc(rc);
                            unreachable;
                        },
                    }
                }
            },
            .remote => {
                try self.fetchRemote(false);
                self.done = true;
            },
        }
    }

    fn fetchRemote(self: *Statement, want_rows: bool) err.Error!void {
        if (self.result) |*r| {
            r.deinit(self.allocator);
            self.result = null;
        }
        const session = self.session.?;
        const sql = self.sql.?;
        const result = try session.execute(sql, self.binds.items, want_rows);
        self.result = result;
        self.row_index = 0;
    }

    pub fn parameterCount(self: *Statement) usize {
        return switch (self.kind) {
            .local => @intCast(c.sqlite3_bind_parameter_count(self.stmt.?)),
            // Remote statements have no prepared handle to query, so count the
            // placeholders in the SQL itself rather than reporting how many slots
            // happen to be bound.
            .remote => countSqlParameters(self.sql orelse ""),
        };
    }
};

/// Count positional bind parameters (`?` and `?NNN`) in `sql`, mirroring
/// SQLite's rule that the parameter count is the largest parameter index used.
/// String/blob literals, quoted identifiers (`"..."`, `` `...` ``, `[...]`), and
/// `--` / `/* */` comments are skipped. Named parameters (`:x`, `@x`, `$x`) are
/// not supported by the remote binder and are intentionally not counted.
fn countSqlParameters(sql: []const u8) usize {
    var max_index: usize = 0;
    var i: usize = 0;
    while (i < sql.len) {
        switch (sql[i]) {
            '\'', '"', '`' => {
                const q = sql[i];
                i += 1;
                while (i < sql.len) : (i += 1) {
                    if (sql[i] == q) {
                        if (i + 1 < sql.len and sql[i + 1] == q) {
                            i += 1; // doubled-quote escape
                        } else break;
                    }
                }
                i += 1;
            },
            '[' => {
                i += 1;
                while (i < sql.len and sql[i] != ']') i += 1;
                i += 1;
            },
            '-' => {
                if (i + 1 < sql.len and sql[i + 1] == '-') {
                    i += 2;
                    while (i < sql.len and sql[i] != '\n') i += 1;
                } else i += 1;
            },
            '/' => {
                if (i + 1 < sql.len and sql[i + 1] == '*') {
                    i += 2;
                    while (i + 1 < sql.len and !(sql[i] == '*' and sql[i + 1] == '/')) i += 1;
                    i += 2;
                } else i += 1;
            },
            '?' => {
                i += 1;
                if (i < sql.len and std.ascii.isDigit(sql[i])) {
                    var n: usize = 0;
                    while (i < sql.len and std.ascii.isDigit(sql[i])) : (i += 1) {
                        n = n * 10 + (sql[i] - '0');
                    }
                    if (n > max_index) max_index = n;
                } else {
                    max_index += 1;
                }
            },
            else => i += 1,
        }
    }
    return max_index;
}

test "countSqlParameters positional forms" {
    try std.testing.expectEqual(@as(usize, 0), countSqlParameters("select 1"));
    try std.testing.expectEqual(@as(usize, 1), countSqlParameters("select ?1"));
    try std.testing.expectEqual(@as(usize, 2), countSqlParameters("select ?, ?"));
    try std.testing.expectEqual(@as(usize, 3), countSqlParameters("select ?, ?3"));
    // Placeholders inside literals/comments/identifiers are ignored.
    try std.testing.expectEqual(@as(usize, 1), countSqlParameters("select '?', \"?\", ? -- ?\n"));
    try std.testing.expectEqual(@as(usize, 0), countSqlParameters("select 'a?b' /* ? */"));
}
