//! Remote libSQL backend (Hrana over HTTP) — Phase 2.
//!
//! Local MVP fails closed with `error.Unsupported` when a remote URI is opened.
//! Implement Hrana JSON client here without pulling Rust/cargo.

const err = @import("../error.zig");

pub fn notImplemented() err.Error {
    return error.Unsupported;
}
