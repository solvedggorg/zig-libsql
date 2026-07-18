const std = @import("std");
const libsql = @import("zig_libsql");

/// Demo CLI: `zig build run -- [path] [sql]`
/// Defaults: path=`:memory:`, sql=`select 1 as n;`
pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    // args[0] is executable name when present.
    var path: []const u8 = ":memory:";
    var sql: []const u8 = "select 1 as n;";
    if (args.len >= 2) path = args[1];
    if (args.len >= 3) sql = args[2];

    var db = libsql.Database.open(arena, .{ .path = path }) catch |e| {
        std.debug.print("open failed: {s}\n", .{@errorName(e)});
        return e;
    };
    defer db.deinit();

    var conn = db.connect();

    // Fail closed: propagate prepare errors rather than blindly re-running the
    // input through exec, which would mask syntax/allocation/database failures.
    var stmt = conn.prepare(sql) catch |e| {
        std.debug.print("prepare failed: {s}\n", .{@errorName(e)});
        return e;
    };
    defer stmt.deinit();

    var row_i: usize = 0;
    while (try stmt.step()) |row| {
        const n = row.columnCount();
        if (row_i == 0) {
        var col: usize = 0;
        while (col < n) : (col += 1) {
            if (col > 0) std.debug.print("|", .{});
            const name = try row.columnName(col);
            std.debug.print("{s}", .{name});
        }
        std.debug.print("\n", .{});
        }
        var col: usize = 0;
        while (col < n) : (col += 1) {
            if (col > 0) std.debug.print("|", .{});
            if (try row.isNull(col)) {
                std.debug.print("NULL", .{});
            } else {
                const ty = try row.columnType(col);
                switch (ty) {
                    libsql.column_type.integer => std.debug.print("{d}", .{try row.int(col)}),
                    libsql.column_type.float => std.debug.print("{d}", .{try row.float(col)}),
                    libsql.column_type.blob => {
                        const b = (try row.blob(col)) orelse &[_]u8{};
                        std.debug.print("<blob {d} bytes>", .{b.len});
                    },
                    else => {
                        const t = (try row.text(col)) orelse "";
                        std.debug.print("{s}", .{t});
                    },
                }
            }
        }
        std.debug.print("\n", .{});
        row_i += 1;
    }

    if (row_i == 0) {
        std.debug.print("ok (engine {s}, zig-libsql {s})\n", .{
            libsql.engineVersion(),
            libsql.version,
        });
    }
}

test "cli module loads" {
    try std.testing.expect(libsql.version.len > 0);
}
