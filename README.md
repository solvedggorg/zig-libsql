# zig-libsql

Zig adapter for **libSQL** / SQLite-compatible databases, built for solved.gg
toolchains written in pure(as) Zig (rusty, scripty, hasky, …).

- **Local:** vendored SQLite amalgamation compiled by Zig (not system `libsqlite3`)
- **Remote:** pure Zig **Hrana over HTTP** (JSON `v3/pipeline`) — see [docs/ROADMAP.md](docs/ROADMAP.md)
- **No cargo** on the default path. If a Rust bridge is ever required, build it
  with [rusty](https://github.com/solvedggorg/rusty).

## Requirements

- Zig **0.16.x**
- libc (linked for the local engine)

## Build

```sh
zig build
zig build test
zig build run -- :memory: "select 1 as n;"
```

## Library usage

```zig
const std = @import("std");
const libsql = @import("zig_libsql");

pub fn example(allocator: std.mem.Allocator) !void {
    var db = try libsql.Database.open(allocator, .{ .path = ":memory:" });
    defer db.deinit();

    var conn = db.connect();
    try conn.exec("create table t(id integer primary key, name text);", .{});
    try conn.exec("insert into t(name) values ('alice');", .{});

    var stmt = try conn.prepare("select id, name from t where id = ?1;");
    defer stmt.deinit();
    try stmt.bindInt(1, 1);

    while (try stmt.step()) |row| {
        const id = try row.int(0);
        const name = try row.text(1);
        std.debug.print("{d} {s}\n", .{ id, name.? });
    }

    // Named parameters (Phase 3)
    try conn.execute(
        "insert into t(id, name) values (:id, :name);",
        .{ .id = @as(i64, 2), .name = "bob" },
    );

    // Batch (Phase 3) — transactional locally; Hrana batch remotely
    _ = try conn.batch(&.{
        .{ .sql = "insert into t(id, name) values (3, 'c')" },
        .{ .sql = "insert into t(id, name) values (4, 'd')" },
    });
}
```

### Remote (Hrana HTTP)

```zig
var db = try libsql.Database.open(allocator, .{
    .path = "libsql://your-db.turso.io",
    .auth_token = token, // never log
    .io = io,            // required for remote
});
defer db.deinit();
var conn = db.connect();
try conn.exec("create table if not exists t(x int);", .{});
var stmt = try conn.prepare("select x from t where x = ?1;");
defer stmt.deinit();
try stmt.bind(.{42});
while (try stmt.step()) |row| {
    _ = try row.int(0);
}
```

`libsql://` and `wss://` map to `https://` for the HTTP pipeline.

### Depend (production)

```sh
zig fetch --save https://github.com/solvedggorg/zig-libsql/archive/refs/tags/v0.2.0.tar.gz
```

Import module **`zig_libsql`**. Full consumer guide: [docs/CONSUMING.md](docs/CONSUMING.md).

Local path deps are for development only.

## Design

| Layer | Implementation |
|-------|----------------|
| Public API | Idiomatic Zig (`Database`, `Connection`, `Statement`, `batch`) |
| Local engine | `vendor/sqlite3.c` (default) or `vendor/libsql/` via `-Dengine=libsql` |
| Remote | Hrana over HTTP JSON (`src/backend/hrana/`) |
| Replicas | Wire + pull landed; inject R3b in progress — `docs/ROADMAP.md` |
| Rust | Optional rusty cdylib for classic replica **sync** — `docs/rust-bridge.md` (`-Denable-rust-bridge`) |

See [AGENTS.md](AGENTS.md) for engineering rules.

## License

MIT — see [LICENSE](LICENSE). Vendored SQLite is public domain
([copyright](https://www.sqlite.org/copyright.html)); pin recorded in
`vendor/VERSION`.
