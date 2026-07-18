# Local engine pin — SQLite vs libSQL fork

## Current pin

| Field | Value |
|-------|--------|
| Engine | SQLite amalgamation **3.49.1** |
| Location | `vendor/sqlite3.c`, `vendor/sqlite3.h` |
| Built by | Zig C compilation (not system `libsqlite3`) |
| Record | `vendor/VERSION` (checksums) |

This is **SQLite-compatible** and sufficient for:

- rusty auth stores and similar local apps
- full prepare / bind / step / transaction surface
- remote Hrana (engine is on the server)

## When to switch to libSQL-sqlite3

Consider vendoring Turso’s **libsql-sqlite3** amalgamation (or equivalent
single-TU build) when we need local features that stock SQLite lacks, e.g.:

- libSQL-specific SQL extensions (column type changes, etc.)
- Virtual WAL hooks required for **embedded replica apply**
- Other fork-only pragmas used by primary/replica tooling

## Policy

1. **Default remains stock SQLite** until a concrete feature needs the fork.
2. Any engine bump is intentional: update `vendor/VERSION`, checksums, ROADMAP.
3. Do not claim “libSQL extensions locally” while still on stock SQLite.
4. System `libsqlite3` stays a non-goal for the default module.

## Build shape (future)

```zig
// hypothetical
const engine = b.option(enum { sqlite, libsql }, "engine", "local engine") orelse .sqlite;
// addCSourceFile vendor/sqlite3.c  OR  vendor/libsql/sqlite3.c
```

Feature detection via `engineVersion()` + a package-level `engine_kind` enum
exported from `root.zig` when dual engines land.
