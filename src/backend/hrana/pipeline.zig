//! Build and parse Hrana over HTTP `v3/pipeline` JSON bodies.

const std = @import("std");
const value = @import("../../value.zig");
const value_json = @import("value_json.zig");
const err = @import("../../error.zig");

pub const StmtResult = struct {
    cols: [][]u8,
    rows: [][]value_json.Owned,
    affected_row_count: u64,
    last_insert_rowid: i64,

    pub fn deinit(self: *StmtResult, allocator: std.mem.Allocator) void {
        for (self.cols) |c| allocator.free(c);
        allocator.free(self.cols);
        for (self.rows) |row| {
            for (row) |*cell| cell.deinit(allocator);
            allocator.free(row);
        }
        allocator.free(self.rows);
        self.* = undefined;
    }
};

pub const PipelineOutcome = struct {
    /// Owned baton string, or null if stream closed.
    baton: ?[]u8,
    /// Owned base_url override, or null to keep previous.
    base_url: ?[]u8,
    /// First execute/sequence result when applicable.
    stmt: ?StmtResult,
    /// True when a stream-level error occurred.
    failed: bool,
    /// Human message for failed (not logged with secrets).
    error_message: ?[]u8,

    pub fn deinit(self: *PipelineOutcome, allocator: std.mem.Allocator) void {
        if (self.baton) |b| allocator.free(b);
        if (self.base_url) |u| allocator.free(u);
        if (self.stmt) |*s| s.deinit(allocator);
        if (self.error_message) |m| allocator.free(m);
        self.* = undefined;
    }
};

/// Build a pipeline body with a single `execute` request.
pub fn buildExecuteBody(
    allocator: std.mem.Allocator,
    baton: ?[]const u8,
    sql: []const u8,
    args: []const value.Value,
    want_rows: bool,
) err.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    writeExecuteBody(w, baton, sql, args, want_rows) catch return error.Sql;
    return aw.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeExecuteBody(
    w: *std.Io.Writer,
    baton: ?[]const u8,
    sql: []const u8,
    args: []const value.Value,
    want_rows: bool,
) std.Io.Writer.Error!void {
    try w.writeAll("{\"baton\":");
    if (baton) |b| {
        try writeJsonString(w, b);
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"requests\":[{\"type\":\"execute\",\"stmt\":{\"sql\":");
    try writeJsonString(w, sql);
    try w.writeAll(",\"args\":[");
    for (args, 0..) |a, i| {
        if (i > 0) try w.writeAll(",");
        try value_json.writeValue(w, a);
    }
    try w.print("],\"want_rows\":{s}}}]", .{if (want_rows) "true" else "false"});
    try w.writeAll("}");
}

/// Build a pipeline body with a single `sequence` request (multi-statement, no rows).
pub fn buildSequenceBody(
    allocator: std.mem.Allocator,
    baton: ?[]const u8,
    sql: []const u8,
) err.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    writeSequenceBody(&aw.writer, baton, sql) catch return error.Sql;
    return aw.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeSequenceBody(w: *std.Io.Writer, baton: ?[]const u8, sql: []const u8) std.Io.Writer.Error!void {
    try w.writeAll("{\"baton\":");
    if (baton) |b| {
        try writeJsonString(w, b);
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"requests\":[{\"type\":\"sequence\",\"sql\":");
    try writeJsonString(w, sql);
    try w.writeAll("}]}");
}

/// Build a pipeline body with a single `close` request.
pub fn buildCloseBody(
    allocator: std.mem.Allocator,
    baton: ?[]const u8,
) err.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    writeCloseBody(&aw.writer, baton) catch return error.Sql;
    return aw.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeCloseBody(w: *std.Io.Writer, baton: ?[]const u8) std.Io.Writer.Error!void {
    try w.writeAll("{\"baton\":");
    if (baton) |b| {
        try writeJsonString(w, b);
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"requests\":[{\"type\":\"close\"}]}");
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try w.print("\\u{x:0>4}", .{ch});
                } else {
                    try w.writeByte(ch);
                }
            },
        }
    }
    try w.writeByte('"');
}

pub fn parsePipelineResponse(allocator: std.mem.Allocator, body: []const u8) err.Error!PipelineOutcome {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.Sql;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.Sql,
    };

    var outcome: PipelineOutcome = .{
        .baton = null,
        .base_url = null,
        .stmt = null,
        .failed = false,
        .error_message = null,
    };
    errdefer outcome.deinit(allocator);

    if (root.get("baton")) |baton_v| {
        switch (baton_v) {
            .string => |s| outcome.baton = try allocator.dupe(u8, s),
            .null => {},
            else => {},
        }
    }
    if (root.get("base_url")) |url_v| {
        switch (url_v) {
            .string => |s| outcome.base_url = try allocator.dupe(u8, s),
            .null => {},
            else => {},
        }
    }

    const results_v = root.get("results") orelse return error.Sql;
    const results = switch (results_v) {
        .array => |a| a,
        else => return error.Sql,
    };

    if (results.items.len == 0) return outcome;

    // Process first result (we send single-request pipelines).
    const first = results.items[0];
    const robj = switch (first) {
        .object => |o| o,
        else => return error.Sql,
    };
    const rtype = robj.get("type") orelse return error.Sql;
    const rtype_s = switch (rtype) {
        .string => |s| s,
        else => return error.Sql,
    };

    if (std.mem.eql(u8, rtype_s, "error")) {
        outcome.failed = true;
        if (robj.get("error")) |e| {
            if (e == .object) {
                if (e.object.get("message")) |m| {
                    if (m == .string) {
                        outcome.error_message = try allocator.dupe(u8, m.string);
                    }
                }
            }
        }
        return outcome;
    }

    if (!std.mem.eql(u8, rtype_s, "ok")) return error.Sql;
    const response = robj.get("response") orelse return error.Sql;
    const resp_obj = switch (response) {
        .object => |o| o,
        else => return error.Sql,
    };
    const resp_type = resp_obj.get("type") orelse return error.Sql;
    const resp_type_s = switch (resp_type) {
        .string => |s| s,
        else => return error.Sql,
    };

    if (std.mem.eql(u8, resp_type_s, "execute")) {
        const result = resp_obj.get("result") orelse return error.Sql;
        outcome.stmt = try parseStmtResult(allocator, result);
    } else if (std.mem.eql(u8, resp_type_s, "sequence") or std.mem.eql(u8, resp_type_s, "close")) {
        // no rows
    } else {
        // Other response types: ignore body for now
    }

    return outcome;
}

fn parseStmtResult(allocator: std.mem.Allocator, v: std.json.Value) err.Error!StmtResult {
    const obj = switch (v) {
        .object => |o| o,
        else => return error.Sql,
    };

    var cols: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (cols.items) |c| allocator.free(c);
        cols.deinit(allocator);
    }
    if (obj.get("cols")) |cols_v| {
        const arr = switch (cols_v) {
            .array => |a| a,
            else => return error.Sql,
        };
        for (arr.items) |col| {
            const cobj = switch (col) {
                .object => |o| o,
                else => return error.Sql,
            };
            const name_v = cobj.get("name") orelse {
                try cols.append(allocator, try allocator.dupe(u8, ""));
                continue;
            };
            switch (name_v) {
                .string => |s| try cols.append(allocator, try allocator.dupe(u8, s)),
                .null => try cols.append(allocator, try allocator.dupe(u8, "")),
                else => try cols.append(allocator, try allocator.dupe(u8, "")),
            }
        }
    }

    var rows: std.ArrayListUnmanaged([]value_json.Owned) = .empty;
    errdefer {
        for (rows.items) |row| {
            for (row) |*cell| cell.deinit(allocator);
            allocator.free(row);
        }
        rows.deinit(allocator);
    }
    if (obj.get("rows")) |rows_v| {
        const arr = switch (rows_v) {
            .array => |a| a,
            else => return error.Sql,
        };
        for (arr.items) |row_v| {
            const cells = switch (row_v) {
                .array => |a| a,
                else => return error.Sql,
            };
            const owned_row = try allocator.alloc(value_json.Owned, cells.items.len);
            errdefer allocator.free(owned_row);
            var filled: usize = 0;
            errdefer {
                var i: usize = 0;
                while (i < filled) : (i += 1) owned_row[i].deinit(allocator);
            }
            for (cells.items, 0..) |cell, i| {
                owned_row[i] = value_json.Owned.fromJson(allocator, cell) catch return error.Sql;
                filled = i + 1;
            }
            try rows.append(allocator, owned_row);
        }
    }

    var affected: u64 = 0;
    if (obj.get("affected_row_count")) |a| {
        affected = switch (a) {
            .integer => |i| @intCast(@max(i, 0)),
            else => 0,
        };
    }

    var last_id: i64 = 0;
    if (obj.get("last_insert_rowid")) |lid| {
        switch (lid) {
            .string => |s| last_id = std.fmt.parseInt(i64, s, 10) catch 0,
            .integer => |i| last_id = i,
            .null => {},
            else => {},
        }
    }

    return .{
        .cols = try cols.toOwnedSlice(allocator),
        .rows = try rows.toOwnedSlice(allocator),
        .affected_row_count = affected,
        .last_insert_rowid = last_id,
    };
}

test "build execute body has sql" {
    const gpa = std.testing.allocator;
    const body = try buildExecuteBody(gpa, null, "select 1", &.{}, true);
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "select 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"baton\":null") != null);
}

test "parse execute ok response" {
    const gpa = std.testing.allocator;
    const body =
        \\{"baton":"abc","base_url":null,"results":[{"type":"ok","response":{"type":"execute","result":{"cols":[{"name":"n","decltype":null}],"rows":[[{"type":"integer","value":"1"}]],"affected_row_count":0,"last_insert_rowid":null}}}]}
    ;
    var out = try parsePipelineResponse(gpa, body);
    defer out.deinit(gpa);
    try std.testing.expectEqualStrings("abc", out.baton.?);
    try std.testing.expect(out.stmt != null);
    try std.testing.expectEqual(@as(usize, 1), out.stmt.?.rows.len);
    try std.testing.expectEqual(@as(i64, 1), out.stmt.?.rows[0][0].integer);
}
