//! Remote libSQL backend — Hrana over HTTP (JSON).
//!
//! Pure Zig: no Rust, no cargo. Auth tokens are never logged.

const std = @import("std");
const Io = std.Io;
const err = @import("../error.zig");
const value = @import("../value.zig");
const path_util = @import("../util/path.zig");
const pipeline = @import("hrana/pipeline.zig");
const http = @import("hrana/http.zig");

pub const Session = struct {
    allocator: std.mem.Allocator,
    io: Io,
    /// Current HTTP origin for stream requests (may be rewritten by server).
    base_url: []u8,
    baton: ?[]u8,
    auth_token: ?[]u8,
    last_affected: i64 = 0,
    last_insert_rowid: i64 = 0,
    closed: bool = false,

    pub fn open(
        io: Io,
        allocator: std.mem.Allocator,
        url: []const u8,
        auth_token: ?[]const u8,
    ) err.Error!Session {
        const http_base = path_util.toHttpBase(allocator, url) catch return error.InvalidPath;
        errdefer allocator.free(http_base);

        var token_owned: ?[]u8 = null;
        errdefer if (token_owned) |t| allocator.free(t);
        if (auth_token) |t| {
            token_owned = allocator.dupe(u8, t) catch return error.OutOfMemory;
        }

        return .{
            .allocator = allocator,
            .io = io,
            .base_url = http_base,
            .baton = null,
            .auth_token = token_owned,
        };
    }

    pub fn deinit(self: *Session) void {
        if (!self.closed) {
            self.closeStream() catch {};
        }
        if (self.baton) |b| self.allocator.free(b);
        if (self.auth_token) |t| self.allocator.free(t);
        self.allocator.free(self.base_url);
        self.* = undefined;
    }

    pub fn closeStream(self: *Session) err.Error!void {
        if (self.closed) return;
        if (self.baton == null) {
            self.closed = true;
            return;
        }
        const body = try pipeline.buildCloseBody(self.allocator, self.baton);
        defer self.allocator.free(body);
        var out = try self.roundTrip(body);
        defer out.deinit(self.allocator);
        if (out.failed) return error.Sql;
        self.closed = true;
    }

    /// Execute multi-statement SQL; rows discarded (Hrana `sequence`).
    pub fn sequence(self: *Session, sql: []const u8) err.Error!void {
        if (self.closed) return error.Sql;
        const body = try pipeline.buildSequenceBody(self.allocator, self.baton, sql);
        defer self.allocator.free(body);
        var out = try self.roundTrip(body);
        defer out.deinit(self.allocator);
        if (out.failed) return error.Sql;
    }

    /// Execute a single statement with binds; optionally return rows.
    pub fn execute(
        self: *Session,
        sql: []const u8,
        args: []const value.Value,
        want_rows: bool,
    ) err.Error!pipeline.StmtResult {
        if (self.closed) return error.Sql;
        const body = try pipeline.buildExecuteBody(self.allocator, self.baton, sql, args, want_rows);
        defer self.allocator.free(body);
        var out = try self.roundTrip(body);
        // Transfer stmt ownership; free the rest.
        const stmt = out.stmt orelse {
            const failed = out.failed;
            out.stmt = null;
            out.deinit(self.allocator);
            if (failed) return error.Sql;
            // execute with no result payload — empty slices must be allocator-owned for deinit safety
            return .{
                .cols = try self.allocator.alloc([]u8, 0),
                .rows = try self.allocator.alloc([]@import("hrana/value_json.zig").Owned, 0),
                .affected_row_count = 0,
                .last_insert_rowid = 0,
            };
        };
        out.stmt = null;
        self.last_affected = @intCast(stmt.affected_row_count);
        self.last_insert_rowid = stmt.last_insert_rowid;
        out.deinit(self.allocator);
        return stmt;
    }

    fn roundTrip(self: *Session, body: []const u8) err.Error!pipeline.PipelineOutcome {
        const url = try http.pipelineUrl(self.allocator, self.base_url);
        defer self.allocator.free(url);

        const resp_body = try http.postPipeline(
            self.io,
            self.allocator,
            url,
            self.auth_token,
            body,
        );
        defer self.allocator.free(resp_body);

        var out = try pipeline.parsePipelineResponse(self.allocator, resp_body);

        // Update baton
        if (self.baton) |old| self.allocator.free(old);
        self.baton = out.baton;
        out.baton = null;

        // Update base URL if server redirected the stream
        if (out.base_url) |new_base| {
            self.allocator.free(self.base_url);
            self.base_url = new_base;
            out.base_url = null;
        }

        if (self.baton == null) {
            // Stream closed by server
            self.closed = true;
        }

        return out;
    }
};

test "session open maps libsql url" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.open(io, gpa, "libsql://db.example.com", "tok");
    defer s.deinit();
    try std.testing.expectEqualStrings("https://db.example.com", s.base_url);
}
