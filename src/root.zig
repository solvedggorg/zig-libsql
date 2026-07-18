//! zig-libsql — pure(as)-Zig libSQL / SQLite adapter.
//!
//! Local engine: vendored SQLite amalgamation compiled by Zig.
//! Remote (Hrana HTTP): Phase 2.
//! Named params + batch: Phase 3 — see docs/ROADMAP.md.
//! Optional rusty bridge for classic embedded replica sync (Phase 4 / R1):
//! `-Denable-rust-bridge=true` — see docs/rust-bridge.md.
//! Pure Zig replica wire codecs (R2): `src/backend/replication/` (not public sync yet).

const std = @import("std");
const c = @import("c/sqlite.zig");

pub const version = "0.2.0";

pub const Error = @import("error.zig").Error;
pub const Value = @import("value.zig").Value;
pub const Database = @import("database.zig").Database;
pub const OpenOptions = @import("database.zig").OpenOptions;
pub const SyncResult = @import("database.zig").SyncResult;
pub const open = @import("database.zig").open;
pub const Connection = @import("connection.zig").Connection;
pub const Statement = @import("statement.zig").Statement;
pub const Row = @import("rows.zig").Row;
pub const BatchStep = @import("batch.zig").Step;
pub const BatchResult = @import("batch.zig").Result;
pub const NamedArg = @import("batch.zig").NamedArg;
pub const rust_bridge_enabled = @import("backend/bridge.zig").isCompileEnabled;

/// SQLite fundamental datatype codes as returned by `Row.columnType`.
pub const column_type = struct {
    pub const integer: c_int = c.SQLITE_INTEGER;
    pub const float: c_int = c.SQLITE_FLOAT;
    pub const text: c_int = c.SQLITE_TEXT;
    pub const blob: c_int = c.SQLITE_BLOB;
    pub const @"null": c_int = c.SQLITE_NULL;
};

/// SQLite amalgamation version string from the linked engine.
pub fn engineVersion() []const u8 {
    return std.mem.span(c.sqlite3_libversion());
}
