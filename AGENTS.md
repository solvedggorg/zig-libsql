# zig-libsql — agent instructions

## 0. Absolute rules

### Pure(as) Zig

This package is the libSQL/SQLite adapter for solved.gg Zig toolchains (rusty,
scripty, hasky, …). Prefer:

1. **Zig API** as the only consumer surface.
2. **Zig-compiled C** for the local engine (vendored amalgamation under `vendor/`).
3. **Pure Zig** for network protocols (Hrana over HTTP, landed in Phase 2).

Forbidden as the default path:

- `linkSystemLibrary("sqlite3")` / host package SQLite
- Cargo / wrapping Turso’s experimental Rust C bindings
- Claiming full Turso Cloud parity before it is implemented

### Rust only via rusty

If a feature truly requires a Rust artifact (document why in `docs/ROADMAP.md`):

```sh
rusty init <name> -lib -y   # or -cli
```

Build with **rusty**, never as a cargo-only product path. Gate behind a
build option (e.g. `-Denable-rust-bridge=true`). Mark removal criteria.

### Take requests literally

No “thin system-sqlite wrapper forever.” Local MVP must compile the vendored
amalgamation. Remote is pure Zig Hrana when implemented.

### Platform

Primary development target is **Linux** (sibling toolchains are Linux-only).
The library itself may build elsewhere if amalgamation + libc work; do not
expand CI/support claims without an explicit decision.

---

## 1. Product identity

**zig-libsql** is a Zig package:

- local SQLite-compatible database (vendored amalgamation)
- remote libSQL via Hrana over HTTP (Phase 2)
- future: embedded replicas (evaluate pure vs rusty bridge)

It is **not** a reimplementation of the full SQLite VM in Zig (v1).
It is **not** a cargo wrapper around `libsql` crates.

Version strings (`build.zig.zon`, `src/root.zig`) must stay in sync.

---

## 2. Module layout

| Path | Role |
|------|------|
| `src/root.zig` | Public exports + version |
| `src/database.zig` | Open modes, `Database` |
| `src/connection.zig` | exec / prepare / batch / tx |
| `src/statement.zig` | positional + named bind / step / reset |
| `src/batch.zig` | `BatchStep` / `BatchResult` types |
| `src/rows.zig` | Row iteration + typed getters |
| `src/value.zig` | Value / bind types |
| `src/error.zig` | Error set + mapping |
| `src/c/sqlite.zig` | Minimal explicit `extern` surface |
| `src/util/path.zig` | Path / URI parsing |
| `src/backend/remote.zig` | Hrana HTTP session (Phase 2) |
| `src/backend/hrana/` | Pipeline JSON + HTTP transport |
| `vendor/` | Pinned amalgamation — integrity in `vendor/VERSION` |
| `src/main.zig` | Demo CLI only (not library surface) |
| `docs/embedded-replicas.md` | Replica design (not implemented) |
| `docs/libsql-engine.md` | Engine pin policy |

---

## 3. Security

- Never log auth tokens or URLs containing secrets.
- Prefer fail-closed errors over silent fallbacks.
- Consumers (e.g. rusty auth.db) own file modes (`0600`); this library does
  not chmod by default unless API opts in later.

---

## 4. Build & test

```sh
zig build
zig build test
zig build run -- :memory: "select 1 as n;"
```

Default module must **not** link system `sqlite3`.

---

## 5. Vendor policy

- Pin amalgamation under `vendor/` with checksums in `vendor/VERSION`.
- Bumping SQLite/libSQL engine is an intentional change (update VERSION + notes).
- Prefer offline builds (no network required after clone).
