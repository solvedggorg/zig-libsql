# Embedded replicas — design (Phase 3)

## Goal

Let Zig consumers open a **local** database file that stays in sync with a
**remote** libSQL primary (Turso Cloud or self-hosted), with optional write
forwarding to the primary.

This is a design note for a later implementation slice. Phase 3 ships named
params + batch; replica *code* is not required to exit Phase 3.

## Background

libSQL embedded replicas typically:

1. Keep a local SQLite-compatible file (WAL-aware).
2. Periodically (or on demand) **sync** frames / pages from the primary over
   Hrana or a dedicated sync protocol.
3. Serve reads from local storage for low latency.
4. Route writes either to local-then-sync or directly to the primary
   (“read your writes” policies vary).

Official clients often use the **Rust** libSQL core for the full replica stack.
Our constraint is pure(as) Zig — prefer reimplementing the wire protocol, and
only fall back to a rusty-built bridge (Phase 4) if the pure path cannot meet
correctness.

## Proposed public API (not yet implemented)

```zig
var db = try libsql.Database.open(allocator, .{
    .path = "replica.db",                 // local file
    .url = "libsql://primary.example",    // remote primary
    .auth_token = token,
    .io = io,
    .sync_interval_ms = 60_000,           // 0 = manual only
    .read_your_writes = true,
});
defer db.deinit();

try db.sync(); // manual pull from primary
var conn = db.connect();
// reads hit local; writes policy TBD
```

## Architecture options

### A. Pure Zig sync client (preferred)

```text
OpenOptions{path + url}
  → local sqlite3 open (existing)
  → remote Session (existing Hrana HTTP)
  → SyncEngine:
       - handshake / checkpoint metadata
       - pull WAL frames or page diff (protocol TBD vs Turso)
       - apply to local file under a write lock
```

**Pros:** no Rust, matches org DNA.  
**Cons:** must reverse-engineer / track sync protocol; high correctness bar.

### B. Hrana-only “soft replica”

Local file is a cache of query results, not a full binary replica.

**Pros:** reuses Phase 2 pipeline only.  
**Cons:** not a true embedded replica; weak offline story.

### C. rusty-built staticlib bridge (Phase 4)

Link Turso’s C/Rust core only when `-Denable-rust-bridge=true`.

**Pros:** full parity sooner.  
**Cons:** second toolchain; must stay opt-in and documented for removal.

## Decision for Phase 3 exit

| Item | Status |
|------|--------|
| Named params | **implemented** |
| Batch | **implemented** |
| Replica design | **this doc** |
| Replica code | **not started** — next slice after sync protocol spike |
| Engine pin (libsql-sqlite3) | see `docs/libsql-engine.md` |

## Spike checklist (before coding replicas)

1. Capture wire traffic from an official client doing embedded sync.
2. Document frame format, auth, and conflict behavior.
3. Decide write path: local apply + push vs primary-only writes.
4. Define crash recovery (partial apply must not corrupt local file).
5. Fail closed if `url` set without `io` / token (already pattern for remote).

## Security

- Never log `auth_token` or batons.
- Local replica files should recommend `0600` (consumer responsibility, same as auth.db).
- Sync must verify TLS for remote origins (`https` only in production guidance).
