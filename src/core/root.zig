//! core: what azure.zig's service modules share.
//!
//! An HTTP transport with a per-request time limit, retries with
//! full-jitter backoff that honour the delay Azure asks for, ARM's error
//! bodies, pages and long-running operations, a token-provider seam through
//! which credentials reach every service, RFC 3339 and RFC 1123 time, and
//! fakes for tests. It imports nothing but std.
//!
//! Nothing is here yet.

test {
    @import("std").testing.refAllDecls(@This());
}
