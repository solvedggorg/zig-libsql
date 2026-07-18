const std = @import("std");
const c = @import("c/sqlite.zig");
const err = @import("error.zig");
const value = @import("value.zig");
const rows = @import("rows.zig");

pub const Statement = struct {
    db: *c.sqlite3,
    stmt: *c.sqlite3_stmt,
    /// Set when the last step returned SQLITE_DONE (no more rows).
    done: bool = false,

    pub fn deinit(self: *Statement) void {
        _ = c.sqlite3_finalize(self.stmt);
        self.* = undefined;
    }

    pub fn reset(self: *Statement) err.Error!void {
        const rc = c.sqlite3_reset(self.stmt);
        self.done = false;
        try err.mapRc(rc);
    }

    pub fn clearBindings(self: *Statement) err.Error!void {
        const rc = c.sqlite3_clear_bindings(self.stmt);
        try err.mapRc(rc);
    }

    pub fn bindNull(self: *Statement, idx: usize) err.Error!void {
        try err.mapRc(c.sqlite3_bind_null(self.stmt, @intCast(idx)));
    }

    pub fn bindInt(self: *Statement, idx: usize, v: i64) err.Error!void {
        try err.mapRc(c.sqlite3_bind_int64(self.stmt, @intCast(idx), v));
    }

    pub fn bindFloat(self: *Statement, idx: usize, v: f64) err.Error!void {
        try err.mapRc(c.sqlite3_bind_double(self.stmt, @intCast(idx), v));
    }

    pub fn bindText(self: *Statement, idx: usize, text: []const u8) err.Error!void {
        // SQLITE_TRANSIENT: SQLite copies the bytes.
        const destructor: ?*const anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, c.SQLITE_TRANSIENT))));
        const rc = c.sqlite3_bind_text(
            self.stmt,
            @intCast(idx),
            if (text.len == 0) "" else text.ptr,
            @intCast(text.len),
            destructor,
        );
        try err.mapRc(rc);
    }

    pub fn bindBlob(self: *Statement, idx: usize, blob: []const u8) err.Error!void {
        const destructor: ?*const anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, c.SQLITE_TRANSIENT))));
        // Pass a non-NULL pointer for the zero-length case so an empty blob binds
        // as an empty BLOB rather than SQL NULL (mirrors bindText).
        const ptr: [*]const u8 = if (blob.len == 0) &[_]u8{} else blob.ptr;
        const rc = c.sqlite3_bind_blob(
            self.stmt,
            @intCast(idx),
            ptr,
            @intCast(blob.len),
            destructor,
        );
        try err.mapRc(rc);
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

    /// Bind a tuple/struct of values positionally starting at index 1.
    /// Supported field types: `null` void, integers, floats, `[]const u8`, `?[]const u8`, `Value`.
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
                    // *const [N:0]u8 etc.
                    switch (@typeInfo(ptr.child)) {
                        .array => |a| {
                            if (a.child == u8) {
                                try self.bindText(idx, field_val.*[0..]);
                                return;
                            }
                        },
                        else => {},
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

    /// Step once. Returns a Row when SQLITE_ROW, null when DONE.
    pub fn step(self: *Statement) err.Error!?rows.Row {
        if (self.done) return null;
        const rc = c.sqlite3_step(self.stmt);
        switch (rc) {
            c.SQLITE_ROW => return rows.Row{ .stmt = self.stmt },
            c.SQLITE_DONE => {
                self.done = true;
                return null;
            },
            else => {
                try err.mapRc(rc);
                unreachable;
            },
        }
    }

    /// Run to completion (for INSERT/UPDATE/DELETE). Errors if a row is produced.
    pub fn execute(self: *Statement) err.Error!void {
        // sqlite3_step auto-resets a completed statement, so guard against
        // re-running the same DML on a second execute() call.
        if (self.done) return;
        while (true) {
            const rc = c.sqlite3_step(self.stmt);
            switch (rc) {
                c.SQLITE_DONE => {
                    self.done = true;
                    return;
                },
                c.SQLITE_ROW => {
                    // Drain unexpected rows then error.
                    while (c.sqlite3_step(self.stmt) == c.SQLITE_ROW) {}
                    return error.Sql;
                },
                else => {
                    try err.mapRc(rc);
                    unreachable;
                },
            }
        }
    }

    pub fn parameterCount(self: *Statement) usize {
        return @intCast(c.sqlite3_bind_parameter_count(self.stmt));
    }
};
