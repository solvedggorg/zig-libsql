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

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    const result = client.fetch(.{
        .location = .{ .url = pipeline_url },
        .method = .POST,
        .payload = body,
        .extra_headers = headers_buf[0..header_count],
        .response_writer = &aw.writer,
        // Do not follow redirects with POST body blindly.
        .redirect_behavior = .not_allowed,
    }) catch return error.Sql;

    const status: u16 = @intFromEnum(result.status);
    if (status < 200 or status >= 300) {
        aw.deinit();
        return error.Sql;
    }

    return aw.toOwnedSlice() catch return error.OutOfMemory;
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
