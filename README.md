# zig-libsql

Zig adapter for **libSQL** / SQLite-compatible databases, built for solved.gg
toolchains written in pure(as) Zig (rusty, scripty, hasky, …).

- **Local:** vendored SQLite amalgamation compiled by Zig (not system `libsqlite3`)
- **Remote:** Hrana client planned (pure Zig) — see [docs/ROADMAP.md](docs/ROADMAP.md)
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
}
```

Add as a dependency via path or `zig fetch` and import module **`zig_libsql`**.

## Design

| Layer | Implementation |
|-------|----------------|
| Public API | Idiomatic Zig (`Database`, `Connection`, `Statement`) |
| Local engine | `vendor/sqlite3.c` compiled into the module |
| Remote | Phase 2 — Hrana over HTTP |
| Rust | Not default; rusty-built bridge only if unavoidable |

See [AGENTS.md](AGENTS.md) for engineering rules.

## License

MIT — see [LICENSE](LICENSE). Vendored SQLite is public domain
([copyright](https://www.sqlite.org/copyright.html)); pin recorded in
`vendor/VERSION`.
