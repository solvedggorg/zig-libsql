# ROADMAP

## One-liner

**zig-libsql** is a pure(as)-Zig libSQL adapter: Zig API, Zig-compiled local
engine, pure Zig remote (Hrana) — not a cargo wrapper.

## Status matrix

| Capability | Status | Notes |
|------------|--------|-------|
| Local file DB | **MVP** | Vendored SQLite 3.49.1 amalgamation |
| In-memory DB | **MVP** | `:memory:` |
| Prepare / bind / step | **MVP** | Positional + **named** binds |
| Transactions | **MVP** | begin / commit / rollback |
| Batch | **MVP** | Phase 3 — local txn + remote Hrana batch |
| Remote Hrana HTTP | **MVP** | Phase 2 — JSON `v3/pipeline` |
| Hrana WebSocket | later | |
| Embedded replicas | design | `docs/embedded-replicas.md` |
| libSQL SQL extensions | deferred | Stay on stock SQLite until needed (`docs/libsql-engine.md`) |
| System libsqlite3 backend | non-goal | Debug-only option only if ever added |
| Rust C FFI default | non-goal | Optional bridge only (Phase 4) |

## Phases

### Phase 0 — Identity ✅

README, AGENTS, ROADMAP, package scaffold.

### Phase 1 — Local adapter ✅

- Vendor amalgamation, Zig `extern` surface, idiomatic API
- Tests + demo CLI
- rusty migration sketch

### Phase 2 — Remote ✅

- URI: `libsql://`, `https://`, `http://` (+ `ws`/`wss` mapped to HTTP)
- Auth token in `OpenOptions.auth_token` (never logged); `OpenOptions.io` required
- Hrana over HTTP JSON (`POST …/v3/pipeline`) with baton stream state
- Same public `Connection` / `Statement` / `Row` surface (materialized rows)
- Live smoke test gated on `LIBSQL_URL` / `LIBSQL_AUTH_TOKEN`

### Phase 3 — Completeness (current)

- [x] Named parameters (local SQLite + remote `named_args`)
- [x] `Connection.batch` (local transaction; remote Hrana batch + BEGIN/COMMIT)
- [x] Embedded replica **design** (`docs/embedded-replicas.md`)
- [x] Engine pin policy (`docs/libsql-engine.md`) — keep SQLite until fork needed
- [ ] Replica implementation (follow-on after protocol spike)

### Phase 4 — Optional Rust interop

Only if pure path cannot deliver a required feature:

```sh
rusty init libsql_bridge -lib -y
```

Gated build option; documented removal criteria.

## Non-goals

- Pure Zig rewrite of the SQLite VM as v1
- Cargo as the default build
- Full Turso Cloud feature marketing claims before implementation
- Shipping `libsql-server` from this package

## First consumer

**rusty** product auth (`$RUSTY_HOME/auth.db`) currently uses system
`libsqlite3`. Target: `@import("zig_libsql")` with path/git dep.
