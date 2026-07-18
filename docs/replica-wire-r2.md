# R2 / R2.1 — Pure Zig classic replica wire + pull client

**Status:** codecs + gRPC-Web unary pull client + meta disk I/O (no public pure sync)  
**Depends on:** protocol spike (`docs/replica-protocol-spike.md`)

## Scope

| Included | Excluded |
|----------|----------|
| Frame header + 4 KiB page layout | WAL inject / libsql-sqlite3 |
| `wal_log` protobuf (Hello, LogOffset, Frame, Frames) | `Proxy` write RPCs |
| `{db}-client_wal_index` meta layout + load/save | Streaming `LogEntries` / `Snapshot` |
| gRPC-Web framing (`application/grpc-web+proto`) | Public pure-Zig `Database.sync()` |
| Unary `Hello` + `BatchLogEntries` over HTTPS | Claiming stock SQLite can apply frames |

## Modules

| Path | Role |
|------|------|
| `src/backend/replication/frame.zig` | LE `FrameHeader` + fixed `Frame` |
| `src/backend/replication/pb.zig` | Minimal protobuf varint / length fields |
| `src/backend/replication/wal_log.zig` | Hello / LogOffset / Frames codecs |
| `src/backend/replication/meta.zig` | Client WAL index layout, path, load/save |
| `src/backend/replication/grpc_web.zig` | Request/response framing + trailer status |
| `src/backend/replication/http.zig` | HTTPS POST unary + replica auth headers |
| `src/backend/replication/client.zig` | `Client.hello` / `batchLogEntries` / `pullUntilCaughtUp` |

## Client usage (internal)

```zig
var client = try replication.Client.open(io, allocator, sync_url, auth_token, "default");
defer client.deinit();

_ = try client.hello();
var batch = try client.batchLogEntries(meta.nextOffset());
defer batch.deinit();
// frames ready for inject (R1 bridge or future R3) — do not open public sync yet
```

Auth headers (never logged): `x-authorization`, `x-namespace-bin` (base64),
`x-libsql-client-version`, `x-session-token` after Hello.

TLS: auth token requires `https://` origin (`libsql://` maps to HTTPS).

## Meta disk

- Path: `{basename}-client_wal_index` beside the DB file  
- `load` → `null` if missing (caller must not auto-delete an existing user DB)  
- `save` writes temp then renames  
- Advance `committed_frame_no` only after successful inject (not in this slice)

## Next (R3)

1. `Snapshot` stream when `NEED_SNAPSHOT`  
2. libsql engine pin + WAL inject  
3. Wire client → inject → meta; then pure public `Database.sync()`  
4. Apply only via R1 bridge until then — never claim stock SQLite inject  

## Security

- Do not log session tokens, auth tokens, or full frame payloads.  
- Codecs and transport treat secrets as opaque bytes.  
