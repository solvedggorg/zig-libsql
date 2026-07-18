const std = @import("std");
const c = @import("c/sqlite.zig");
const err = @import("error.zig");
const value = @import("value.zig");
const rows = @import("rows.zig");
const remote = @import("backend/remote.zig");
const pipeline = @import("backend/hrana/pipeline.zig");
const batch_mod = @import("batch.zig");

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
    named_binds: std.ArrayListUnmanaged(batch_mod.NamedArg) = .empty,
    /// Owned string/blob storage for bind values that need ownership.
    bind_storage: std.ArrayListUnmanaged([]u8) = .empty,
    /// Owned copies of named parameter names.
    name_storage: std.ArrayListUnmanaged([]u8) = .empty,
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
                for (self.name_storage.items) |s| self.allocator.free(s);
                self.name_storage.deinit(self.allocator);
                self.binds.deinit(self.allocator);
                self.named_binds.deinit(self.allocator);
            },
        }
        self.* = undefined;
    }

    pub fn reset(self: *Statement) err.Error!void {
        switch (self.kind) {
            .local => try err.mapRc(c.sqlite3_reset(self.stmt.?)),
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
                for (self.name_storage.items) |s| self.allocator.free(s);
                self.name_storage.clearRetainingCapacity();
                self.binds.clearRetainingCapacity();
                self.named_binds.clearRetainingCapacity();
            },
        }
    }

    // --- positional binds ---

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
                try err.mapRc(c.sqlite3_bind_text(
                    self.stmt.?,
                    @intCast(idx),
                    if (text.len == 0) "" else text.ptr,
                    @intCast(text.len),
                    destructor,
                ));
            },
            .remote => {
                const owned = self.allocator.dupe(u8, text) catch return error.OutOfMemory;
                errdefer self.allocator.free(owned);
                try self.bind_storage.append(self.allocator, owned);
                // Undo the append if the set below fails, so `owned` is freed
                // exactly once (here) and not again by deinit.
                errdefer _ = self.bind_storage.pop();
                try self.remoteSet(idx, .{ .text = owned });
            },
        }
    }

    pub fn bindBlob(self: *Statement, idx: usize, blob: []const u8) err.Error!void {
        switch (self.kind) {
            .local => {
                const destructor: ?*const anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, c.SQLITE_TRANSIENT))));
                // Pass a non-NULL pointer for the zero-length case so an empty
                // blob binds as an empty BLOB rather than SQL NULL (mirrors
                // bindText).
                const ptr: [*]const u8 = if (blob.len == 0) &[_]u8{} else blob.ptr;
                try err.mapRc(c.sqlite3_bind_blob(
                    self.stmt.?,
                    @intCast(idx),
                    ptr,
                    @intCast(blob.len),
                    destructor,
                ));
            },
            .remote => {
                const owned = self.allocator.dupe(u8, blob) catch return error.OutOfMemory;
                errdefer self.allocator.free(owned);
                try self.bind_storage.append(self.allocator, owned);
                // Undo the append if the set below fails, so `owned` is freed
                // exactly once (here) and not again by deinit.
                errdefer _ = self.bind_storage.pop();
                try self.remoteSet(idx, .{ .blob = owned });
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

    // --- named binds ---

    pub fn bindNamedNull(self: *Statement, name: []const u8) err.Error!void {
        try self.bindNamedValue(name, .{ .null = {} });
    }

    pub fn bindNamedInt(self: *Statement, name: []const u8, v: i64) err.Error!void {
        try self.bindNamedValue(name, .{ .integer = v });
    }

    pub fn bindNamedFloat(self: *Statement, name: []const u8, v: f64) err.Error!void {
        try self.bindNamedValue(name, .{ .float = v });
    }

    pub fn bindNamedText(self: *Statement, name: []const u8, text: []const u8) err.Error!void {
        switch (self.kind) {
            .local => {
                const idx = try self.resolveName(name);
                try self.bindText(@intCast(idx), text);
            },
            .remote => {
                const owned = self.allocator.dupe(u8, text) catch return error.OutOfMemory;
                errdefer self.allocator.free(owned);
                try self.bind_storage.append(self.allocator, owned);
                // Undo the append if the set below fails, so `owned` is freed
                // exactly once (here) and not again by deinit.
                errdefer _ = self.bind_storage.pop();
                try self.remoteNamedSet(name, .{ .text = owned });
            },
        }
    }

    pub fn bindNamedBlob(self: *Statement, name: []const u8, blob: []const u8) err.Error!void {
        switch (self.kind) {
            .local => {
                const idx = try self.resolveName(name);
                try self.bindBlob(@intCast(idx), blob);
            },
            .remote => {
                const owned = self.allocator.dupe(u8, blob) catch return error.OutOfMemory;
                errdefer self.allocator.free(owned);
                try self.bind_storage.append(self.allocator, owned);
                // Undo the append if the set below fails, so `owned` is freed
                // exactly once (here) and not again by deinit.
                errdefer _ = self.bind_storage.pop();
                try self.remoteNamedSet(name, .{ .blob = owned });
            },
        }
    }

    pub fn bindNamedValue(self: *Statement, name: []const u8, v: value.Value) err.Error!void {
        switch (self.kind) {
            .local => {
                const idx = try self.resolveName(name);
                try self.bindValue(@intCast(idx), v);
            },
            .remote => switch (v) {
                .text => |t| try self.bindNamedText(name, t),
                .blob => |b| try self.bindNamedBlob(name, b),
                else => try self.remoteNamedSet(name, v),
            },
        }
    }

    /// Resolve a parameter name to a 1-based index (local only).
    /// Tries `name` as given, then `:name`, `@name`, `$name` if no prefix.
    pub fn resolveName(self: *Statement, name: []const u8) err.Error!c_int {
        if (self.kind != .local) return error.Unsupported;
        var buf: [256]u8 = undefined;
        if (name.len >= buf.len) return error.Bind;

        // As given
        {
            const z = self.allocator.dupeZ(u8, name) catch return error.OutOfMemory;
            defer self.allocator.free(z);
            const idx = c.sqlite3_bind_parameter_index(self.stmt.?, z.ptr);
            if (idx != 0) return idx;
        }

        // With common prefixes when name has none
        if (name.len > 0 and name[0] != ':' and name[0] != '@' and name[0] != '$' and name[0] != '?') {
            const prefixes = [_]u8{ ':', '@', '$' };
            for (prefixes) |p| {
                const z = std.fmt.bufPrintZ(&buf, "{c}{s}", .{ p, name }) catch return error.Bind;
                const idx = c.sqlite3_bind_parameter_index(self.stmt.?, z.ptr);
                if (idx != 0) return idx;
            }
        }
        return error.Bind;
    }

    fn remoteSet(self: *Statement, idx: usize, v: value.Value) err.Error!void {
        if (idx == 0) return error.Bind;
        const i = idx - 1;
        while (self.binds.items.len <= i) {
            try self.binds.append(self.allocator, .{ .null = {} });
        }
        self.binds.items[i] = v;
    }

    fn remoteNamedSet(self: *Statement, name: []const u8, v: value.Value) err.Error!void {
        const name_owned = self.allocator.dupe(u8, name) catch return error.OutOfMemory;
        errdefer self.allocator.free(name_owned);
        try self.name_storage.append(self.allocator, name_owned);
        // Undo the append if the named_binds append fails, so `name_owned` is
        // freed exactly once (here) and not again by deinit.
        errdefer _ = self.name_storage.pop();
        try self.named_binds.append(self.allocator, .{ .name = name_owned, .value = v });
    }

    /// Bind a tuple positionally, or a non-tuple struct by field name.
    pub fn bind(self: *Statement, args: anytype) err.Error!void {
        const Args = @TypeOf(args);
        const info = @typeInfo(Args);
        switch (info) {
            .@"struct" => |s| {
                // Fail closed: for local statements the number of bind values must
                // match the statement's declared parameter count so omitted values
                // are not silently left bound to NULL. Remote statements do not
                // expose a declared parameter count, so this only runs locally.
                if (self.kind == .local and s.fields.len != try self.parameterCount()) {
                    return error.Bind;
                }
                if (s.is_tuple) {
                    inline for (s.fields, 0..) |field, i| {
                        try bindAny(self, i + 1, @field(args, field.name));
                    }
                } else {
                    inline for (s.fields) |field| {
                        try bindAnyNamed(self, field.name, @field(args, field.name));
                    }
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

    fn bindAnyNamed(self: *Statement, name: []const u8, field_val: anytype) err.Error!void {
        const T = @TypeOf(field_val);
        if (T == value.Value) {
            try self.bindNamedValue(name, field_val);
            return;
        }
        if (T == @TypeOf(null)) {
            try self.bindNamedNull(name);
            return;
        }
        const ti = @typeInfo(T);
        switch (ti) {
            .null => try self.bindNamedNull(name),
            .optional => {
                if (field_val) |v| {
                    try bindAnyNamed(self, name, v);
                } else {
                    try self.bindNamedNull(name);
                }
            },
            .int, .comptime_int => try self.bindNamedInt(name, @intCast(field_val)),
            .float, .comptime_float => try self.bindNamedFloat(name, @floatCast(field_val)),
            .pointer => |ptr| {
                if (ptr.size == .slice and ptr.child == u8) {
                    try self.bindNamedText(name, field_val);
                    return;
                }
                if (ptr.size == .one) {
                    const child = @typeInfo(ptr.child);
                    if (child == .array and child.array.child == u8) {
                        try self.bindNamedText(name, field_val.*[0..]);
                        return;
                    }
                }
                @compileError("unsupported named bind pointer type: " ++ @typeName(T));
            },
            .array => |arr| {
                if (arr.child == u8) {
                    try self.bindNamedText(name, field_val[0..]);
                    return;
                }
                @compileError("unsupported named bind array type: " ++ @typeName(T));
            },
            else => @compileError("unsupported named bind type: " ++ @typeName(T)),
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
        // re-running the same DML on a second execute() call (idempotent).
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
        const result = try self.session.?.execute(
            self.sql.?,
            self.binds.items,
            self.named_binds.items,
            want_rows,
        );
        self.result = result;
        self.row_index = 0;
    }

    pub fn parameterCount(self: *Statement) err.Error!usize {
        return switch (self.kind) {
            .local => @intCast(c.sqlite3_bind_parameter_count(self.stmt.?)),
            // Remote statements do not expose the SQL's declared parameter count;
            // the bind lists only reflect what has been bound so far, which is a
            // different quantity. Fail closed rather than return a misleading value.
            .remote => error.Unsupported,
        };
    }
};
