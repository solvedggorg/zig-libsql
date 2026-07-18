//! On-disk client WAL index meta for classic embedded replicas.
//!
//! Layout matches `libsql-replication` `WalIndexMetaData` (little-endian):
//! `log_id: u128`, `committed_frame_no: u64`, padding 8 bytes.
//! File name next to the DB: `{basename}-client_wal_index`.

const std = @import("std");

pub const meta_size: usize = 32;

pub const WalIndexMeta = struct {
    log_id: u128,
    /// `std.math.maxInt(u64)` means “no commit yet” (official client sentinel).
    committed_frame_no: u64,

    pub const none_frame: u64 = std.math.maxInt(u64);

    pub fn encode(self: WalIndexMeta, out: *[meta_size]u8) void {
        std.mem.writeInt(u128, out[0..16], self.log_id, .little);
        std.mem.writeInt(u64, out[16..24], self.committed_frame_no, .little);
        @memset(out[24..32], 0);
    }

    pub fn decode(bytes: *const [meta_size]u8) WalIndexMeta {
        return .{
            .log_id = std.mem.readInt(u128, bytes[0..16], .little),
            .committed_frame_no = std.mem.readInt(u64, bytes[16..24], .little),
        };
    }

    pub fn currentFrameNo(self: WalIndexMeta) ?u64 {
        if (self.committed_frame_no == none_frame) return null;
        return self.committed_frame_no;
    }

    pub fn nextOffset(self: WalIndexMeta) u64 {
        return if (self.currentFrameNo()) |n| n + 1 else 0;
    }
};

/// `{dir}/{basename}-client_wal_index` for a db path like `/tmp/foo.db`.
pub fn indexPathAlloc(allocator: std.mem.Allocator, db_path: []const u8) error{OutOfMemory}![]u8 {
    const base = std.fs.path.basename(db_path);
    const dir = std.fs.path.dirname(db_path) orelse ".";
    return std.fmt.allocPrint(allocator, "{s}/{s}-client_wal_index", .{ dir, base });
}

test "wal index meta round-trip" {
    const m = WalIndexMeta{
        .log_id = 0x11223344556677889900aabbccddeeff,
        .committed_frame_no = 7,
    };
    var buf: [meta_size]u8 = undefined;
    m.encode(&buf);
    const d = WalIndexMeta.decode(&buf);
    try std.testing.expectEqual(m.log_id, d.log_id);
    try std.testing.expectEqual(m.committed_frame_no, d.committed_frame_no);
    try std.testing.expectEqual(@as(?u64, 7), d.currentFrameNo());
    try std.testing.expectEqual(@as(u64, 8), d.nextOffset());
}

test "none frame sentinel" {
    const m = WalIndexMeta{ .log_id = 1, .committed_frame_no = WalIndexMeta.none_frame };
    try std.testing.expect(m.currentFrameNo() == null);
    try std.testing.expectEqual(@as(u64, 0), m.nextOffset());
}

test "index path" {
    const gpa = std.testing.allocator;
    const p = try indexPathAlloc(gpa, "/var/lib/app/replica.db");
    defer gpa.free(p);
    try std.testing.expectEqualStrings("/var/lib/app/replica.db-client_wal_index", p);
}
