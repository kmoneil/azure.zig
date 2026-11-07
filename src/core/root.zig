//! core: what azure.zig's service modules share.
//!
//! Most of it is rest-core, the cloud-neutral half of a REST client: an
//! HTTP transport with a per-request time limit, the request loop with
//! retries that honour the delay a server asks for, a token-provider seam
//! through which credentials reach every service, RFC 3339 and HTTP dates,
//! RSA signing, and fakes for tests. What is Azure's own is here: its
//! clouds, Resource Manager's side of the loop, and its long-running
//! operations.

const rest_core = @import("rest_core");

pub const transport = rest_core.transport;
pub const loop = rest_core.loop;
pub const Diagnostics = rest_core.Diagnostics;
pub const TokenProvider = rest_core.TokenProvider;
pub const StaticToken = rest_core.StaticToken;
pub const RetryPolicy = rest_core.RetryPolicy;
pub const retry_after = rest_core.retry_after;
pub const query = rest_core.query;
pub const timestamp = rest_core.timestamp;
pub const http_date = rest_core.http_date;
pub const rsa = rest_core.rsa;
pub const Owned = rest_core.Owned;
pub const WipingAllocator = rest_core.WipingAllocator;
pub const logging = rest_core.logging;

/// Fakes and helpers, for tests only: rest-core's, and ARM's answers.
pub const testing = @import("testing.zig");

/// Azure's clouds: where each one's sign-in, ARM and Storage are.
pub const Cloud = @import("Cloud.zig");

/// Azure Resource Manager: its refusals, retries, pages and operation URLs.
pub const arm = @import("arm.zig");

/// Long-running ARM operations: begun, polled, waited on, and read.
pub const operation = @import("operation.zig");

/// ARM's naming rules, checked before a name goes into a path: a
/// subscription, a resource group, a location, tags.
pub const names = @import("names.zig");

/// CRC-64/NVME, Blob Storage's `x-ms-content-crc64`.
pub const crc64 = @import("crc64.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("Cloud.zig");
    _ = @import("arm.zig");
    _ = @import("operation.zig");
    _ = @import("names.zig");

    _ = @import("crc64.zig");
    _ = @import("testing.zig");
    _ = @import("rest_core_test.zig");
}
