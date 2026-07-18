//! HTTP transport for Hrana over HTTP (JSON, v3/pipeline).

const std = @import("std");
const Io = std.Io;
const err = @import("../../error.zig");

pub fn postPipeline(
    io: Io,
    allocator: std.mem.Allocator,
    pipeline_url: []const u8,
    auth_token: ?[]const u8,
    body: []const u8,
) err.Error![]u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var auth_buf: [512]u8 = undefined;
    var headers_buf: [2]std.http.Header = undefined;
    var header_count: usize = 1;
    headers_buf[0] = .{ .name = "content-type", .value = "application/json" };

    if (auth_token) |tok| {
        if (tok.len + "Bearer ".len >= auth_buf.len) return error.Sql;
        const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{tok}) catch return error.Sql;
        headers_buf[1] = .{ .name = "authorization", .value = auth };
        header_count = 2;
    }

    // Bound the response body so a large or malicious Hrana reply can't exhaust
    // memory. Back it with a fixed heap buffer: pages are committed lazily as the
    // body streams in, and `fixed` returns error.WriteFailed once the cap is hit
    // (surfaced by fetch and mapped to error.Sql below).
    const max_response_bytes = 32 * 1024 * 1024; // 32 MiB cap for a v3/pipeline reply
    const resp_buf = allocator.alloc(u8, max_response_bytes) catch return error.OutOfMemory;
    defer allocator.free(resp_buf);
    var resp_writer: std.Io.Writer = .fixed(resp_buf);

    const result = client.fetch(.{
        .location = .{ .url = pipeline_url },
        .method = .POST,
        .payload = body,
        .extra_headers = headers_buf[0..header_count],
        .response_writer = &resp_writer,
        // Do not follow redirects with POST body blindly.
        .redirect_behavior = .not_allowed,
    }) catch return error.Sql;

    const status: u16 = @intFromEnum(result.status);
    if (status < 200 or status >= 300) return error.Sql;

    return allocator.dupe(u8, resp_writer.buffered()) catch return error.OutOfMemory;
}

/// Join base URL (no trailing slash preferred) with `/v3/pipeline`.
pub fn pipelineUrl(allocator: std.mem.Allocator, base: []const u8) err.Error![]u8 {
    const trimmed = std.mem.trimEnd(u8, base, "/");
    return std.fmt.allocPrint(allocator, "{s}/v3/pipeline", .{trimmed}) catch return error.OutOfMemory;
}

test "pipeline url join" {
    const gpa = std.testing.allocator;
    const u = try pipelineUrl(gpa, "https://example.turso.io/");
    defer gpa.free(u);
    try std.testing.expectEqualStrings("https://example.turso.io/v3/pipeline", u);
}
