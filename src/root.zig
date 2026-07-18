//! zig-libsql — pure(as)-Zig libSQL / SQLite adapter.
//!
//! Local engine: vendored SQLite amalgamation compiled by Zig.
//! Remote (Hrana): Phase 2 — see docs/ROADMAP.md.

const std = @import("std");
const c = @import("c/sqlite.zig");

pub const version = "0.1.0";

pub const Error = @import("error.zig").Error;
pub const Value = @import("value.zig").Value;
pub const Database = @import("database.zig").Database;
pub const OpenOptions = @import("database.zig").OpenOptions;
pub const open = @import("database.zig").open;
pub const Connection = @import("connection.zig").Connection;
pub const Statement = @import("statement.zig").Statement;
pub const Row = @import("rows.zig").Row;

/// SQLite fundamental datatype codes as returned by `Row.columnType`.
pub const column_type = struct {
    pub const integer: c_int = c.SQLITE_INTEGER;
    pub const float: c_int = c.SQLITE_FLOAT;
    pub const text: c_int = c.SQLITE_TEXT;
    pub const blob: c_int = c.SQLITE_BLOB;
    pub const @"null": c_int = c.SQLITE_NULL;
};

/// SQLite amalgamation version string from the linked engine.
pub fn engineVersion() []const u8 {
    return std.mem.span(c.sqlite3_libversion());
}

test {
    _ = @import("util/path.zig");
    _ = @import("error.zig");
    _ = @import("value.zig");
    _ = @import("rows.zig");
    _ = @import("statement.zig");
    _ = @import("connection.zig");
    _ = @import("database.zig");
    _ = @import("backend/remote.zig");
}

test "engine version non-empty" {
    const v = engineVersion();
    try std.testing.expect(v.len > 0);
}

test "memory create insert select" {
    const gpa = std.testing.allocator;
    var db = try Database.open(gpa, .{ .path = ":memory:" });
    defer db.deinit();
    var conn = db.connect();

    try conn.exec(
        \\create table t(id integer primary key, name text not null, score real, blob blob);
    , .{});

    var ins = try conn.prepare("insert into t(name, score, blob) values (?1, ?2, ?3);");
    defer ins.deinit();
    try ins.bind(.{ "alice", 3.5, "hi" });
    try ins.execute();
    try std.testing.expectEqual(@as(i64, 1), conn.changes());
    try std.testing.expectEqual(@as(i64, 1), conn.lastInsertRowid());

    var sel = try conn.prepare("select id, name, score, blob from t where id = ?1;");
    defer sel.deinit();
    try sel.bindInt(1, 1);
    const row = (try sel.step()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 1), try row.int(0));
    try std.testing.expectEqualStrings("alice", (try row.text(1)).?);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), try row.float(2), 0.0001);
    try std.testing.expectEqualStrings("hi", (try row.blob(3)).?);
    try std.testing.expect((try sel.step()) == null);
}

test "null bind and column" {
    const gpa = std.testing.allocator;
    var db = try Database.open(gpa, .{ .path = ":memory:" });
    defer db.deinit();
    var conn = db.connect();
    try conn.exec("create table t(id integer primary key, note text);", .{});
    var ins = try conn.prepare("insert into t(note) values (?1);");
    defer ins.deinit();
    try ins.bindNull(1);
    try ins.execute();

    var sel = try conn.prepare("select note from t where id = 1;");
    defer sel.deinit();
    const row = (try sel.step()) orelse return error.TestUnexpectedResult;
    try std.testing.expect(try row.isNull(0));
    try std.testing.expect((try row.text(0)) == null);
}

test "transaction rollback" {
    const gpa = std.testing.allocator;
    var db = try Database.open(gpa, .{ .path = ":memory:" });
    defer db.deinit();
    var conn = db.connect();
    try conn.exec("create table t(x integer);", .{});
    try conn.begin();
    try conn.exec("insert into t(x) values (1);", .{});
    try conn.rollback();

    var sel = try conn.prepare("select count(*) from t;");
    defer sel.deinit();
    const row = (try sel.step()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 0), try row.int(0));
}

test "file durability" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // Unique path under /tmp so parallel tests do not clash.
    const db_path = try std.fmt.allocPrint(gpa, "/tmp/zig-libsql-test-{d}-{d}.db", .{
        std.os.linux.getpid(),
        std.testing.random_seed,
    });
    defer {
        std.Io.Dir.cwd().deleteFile(io, db_path) catch {};
        gpa.free(db_path);
    }

    {
        var db = try Database.open(gpa, .{ .path = db_path });
        defer db.deinit();
        var conn = db.connect();
        try conn.exec("create table t(x text);", .{});
        try conn.execute("insert into t(x) values (?1);", .{"persist"});
    }

    {
        var db = try Database.open(gpa, .{ .path = db_path, .create = false });
        defer db.deinit();
        var conn = db.connect();
        var sel = try conn.prepare("select x from t;");
        defer sel.deinit();
        const row = (try sel.step()) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("persist", (try row.text(0)).?);
    }
}

test "remote open unsupported" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.Unsupported, Database.open(gpa, .{
        .path = "libsql://example.turso.io",
        .auth_token = "secret",
    }));
}

test "convenience open owns handle" {
    const gpa = std.testing.allocator;
    var conn = try open(gpa, ":memory:");
    defer conn.deinit();
    try conn.exec("select 1;", .{});
}

test "optional text bind" {
    const gpa = std.testing.allocator;
    var db = try Database.open(gpa, .{ .path = ":memory:" });
    defer db.deinit();
    var conn = db.connect();
    try conn.exec("create table t(a text, b text);", .{});
    const missing: ?[]const u8 = null;
    try conn.execute("insert into t(a, b) values (?1, ?2);", .{ "x", missing });
    var sel = try conn.prepare("select a, b from t;");
    defer sel.deinit();
    const row = (try sel.step()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("x", (try row.text(0)).?);
    try std.testing.expect(try row.isNull(1));
}
