# Migrating from system libsqlite3 (rusty sketch)

## Today (rusty)

```zig
// build.zig
mod.linkSystemLibrary("sqlite3", .{});
mod.link_libc = true;

// src/auth/c.zig — hand-rolled extern
// src/auth/store.zig — c.sqlite3_open / prepare / bind / step
```

## Target

```zig
// build.zig.zon
.dependencies = .{
    .zig_libsql = .{ .path = "../zig-libsql" }, // or zig fetch URL + hash
},

// build.zig
const libsql = b.dependency("zig_libsql", .{
    .target = target,
    .optimize = optimize,
});
mod.addImport("zig_libsql", libsql.module("zig_libsql"));
// drop linkSystemLibrary("sqlite3")
```

```zig
// store.zig
const libsql = @import("zig_libsql");

var db = try libsql.Database.open(allocator, .{ .path = db_path });
defer db.deinit();
var conn = db.connect();

try conn.exec(
    \\PRAGMA journal_mode=DELETE;
    \\CREATE TABLE IF NOT EXISTS session ( ... );
, .{});

var stmt = try conn.prepare(
    \\INSERT INTO session(...) VALUES(?1, ?2, ...)
    \\ON CONFLICT(id) DO UPDATE SET ...;
);
defer stmt.deinit();
try stmt.bindText(1, session.clerk_user_id);
// ...
try stmt.execute();
```

## Security still on the consumer

- `chmod 0600` on the auth DB file after open (library does not chmod by default).
- Prefer `PRAGMA journal_mode=DELETE` for token stores (no WAL sidecars).
- Never log tokens.

## API mapping

| sqlite3 C | zig_libsql |
|-----------|------------|
| `sqlite3_open` | `Database.open` / `open` |
| `sqlite3_exec` | `Connection.exec` |
| `sqlite3_prepare_v2` | `Connection.prepare` |
| `sqlite3_bind_*` | `Statement.bindInt/Text/...` or `bind(.{...})` |
| `sqlite3_step` ROW/DONE | `Statement.step` → `?Row` |
| `sqlite3_column_*` | `Row.int/text/blob/...` |
| `sqlite3_finalize` | `Statement.deinit` |
| `sqlite3_close` | `Database.deinit` |
