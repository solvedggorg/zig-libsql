# R2 — Pure Zig classic replica wire codecs

**Status:** codecs + unit tests (no public sync path)  
**Depends on:** protocol spike (`docs/replica-protocol-spike.md`)

## Scope

| Included | Excluded |
|----------|----------|
| Frame header + 4 KiB page layout | gRPC-Web / HTTP transport |
| `wal_log` protobuf (Hello, LogOffset, Frame, Frames) | `Proxy` write RPCs |
| `{db}-client_wal_index` meta layout | WAL inject / libsql-sqlite3 |
| Session token UUID shape check | Public `Database.sync()` pure path |

## Modules

| Path | Role |
|------|------|
| `src/backend/replication/frame.zig` | LE `FrameHeader` + fixed `Frame` |
| `src/backend/replication/pb.zig` | Minimal protobuf varint / length fields |
| `src/backend/replication/wal_log.zig` | Hello / LogOffset / Frames codecs |
| `src/backend/replication/meta.zig` | Client WAL index file layout + path helper |

## Next (R2.1 / R3)

1. gRPC-Web client: `Hello` + `BatchLogEntries` over HTTPS with auth headers from the spike.  
2. Persist/load `WalIndexMeta` on disk around sync.  
3. Apply only via R1 bridge or future libsql inject — never claim stock SQLite inject.

## Security

- Do not log session tokens, auth tokens, or full frame payloads in production logs.  
- Codecs never touch secrets beyond opaque byte fields.
