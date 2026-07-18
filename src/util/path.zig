//! Open-target path / URI classification for Database.open.

const std = @import("std");

pub const Kind = enum {
    memory,
    file,
    remote,
};

pub const Parsed = struct {
    kind: Kind,
    /// For `.file`: filesystem path (no `file:` prefix).
    /// For `.memory`: empty or ignored.
    /// For `.remote`: original URL (token never stored here).
    path: []const u8,
};

/// Classify an open path string.
///
/// Accepted:
/// - `:memory:` → memory
/// - `file:PATH` or plain path → file
/// - `libsql://…`, `https://…`, `http://…` → remote (Phase 2)
pub fn parse(path: []const u8) Parsed {
    if (std.mem.eql(u8, path, ":memory:")) {
        return .{ .kind = .memory, .path = path };
    }
    if (std.mem.startsWith(u8, path, "libsql://") or
        std.mem.startsWith(u8, path, "https://") or
        std.mem.startsWith(u8, path, "http://") or
        std.mem.startsWith(u8, path, "wss://") or
        std.mem.startsWith(u8, path, "ws://"))
    {
        return .{ .kind = .remote, .path = path };
    }
    if (std.mem.startsWith(u8, path, "file:")) {
        const rest = path["file:".len..];
        // file:/abs or file:rel — strip single leading slash only when `file:///`.
        if (std.mem.startsWith(u8, rest, "///")) {
            return .{ .kind = .file, .path = rest[2..] }; // keep one leading /
        }
        if (std.mem.startsWith(u8, rest, "//")) {
            // file://host/path — treat as path after host for local-only simplicity:
            // file:///tmp/x already handled; file://localhost/tmp/x → /tmp/x
            if (std.mem.indexOfScalar(u8, rest[2..], '/')) |idx| {
                return .{ .kind = .file, .path = rest[2 + idx ..] };
            }
            return .{ .kind = .file, .path = rest };
        }
        return .{ .kind = .file, .path = rest };
    }
    return .{ .kind = .file, .path = path };
}

test "parse memory" {
    const p = parse(":memory:");
    try std.testing.expect(p.kind == .memory);
}

test "parse plain file" {
    const p = parse("/tmp/x.db");
    try std.testing.expect(p.kind == .file);
    try std.testing.expectEqualStrings("/tmp/x.db", p.path);
}

test "parse file uri" {
    const p = parse("file:///tmp/x.db");
    try std.testing.expect(p.kind == .file);
    try std.testing.expectEqualStrings("/tmp/x.db", p.path);
}

test "parse remote" {
    const p = parse("libsql://example.turso.io");
    try std.testing.expect(p.kind == .remote);
}
