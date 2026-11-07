//! Blob Storage's side of rest-core's request loop: how a refused response
//! reads, and which failures are tried again.
//!
//! A refusal's code is in `x-ms-error-code`, a HEAD's included, which has
//! no body; the body, when there is one, is XML,
//! `<Error><Code>..</Code><Message>..</Message></Error>`, after the byte
//! order mark production always sends. A body of another shape, as a
//! gateway's page is, still gives the status and the request id.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const transport = core.transport;
const Diagnostics = core.Diagnostics;
const xml = @import("xml.zig");

const log = core.logging.Scoped(.azure_storage);

/// The request loop over Blob Storage, logging under `azure_storage`.
pub const Engine = core.loop.Engine(.azure_storage, Hook);

/// azcore's: four attempts, the first retry within 800 ms, and a server's
/// delay honoured up to a minute.
pub const retry_policy: core.RetryPolicy = .{
    .max_attempts = 4,
    .initial_backoff_ms = 800,
    .max_backoff_ms = 60_000,
};

pub const Hook = struct {
    pub const RefusalError = error{
        /// 400: the request is malformed, or its CRC-64 or MD5 is not the
        /// bytes'.
        BadRequest,
        /// 401, after the loop's one more try with a fresh token.
        Unauthenticated,
        /// 403: the principal lacks a data role, the signature is wrong or
        /// stale (`AuthenticationFailed`), the account refuses Shared Key,
        /// or its firewall refuses the caller.
        PermissionDenied,
        /// 404 `BlobNotFound`, and any other 404 but a container's.
        NotFound,
        /// 404 `ContainerNotFound`: the container named is not there.
        ContainerNotFound,
        /// 409 `ContainerAlreadyExists`.
        ContainerAlreadyExists,
        /// 409 for anything else: a container being deleted, a lease.
        Conflict,
        /// 412, and 409 `BlobAlreadyExists`, which a create-only write
        /// whose blob exists is answered with.
        PreconditionFailed,
        /// 304: a read's `if_none_match` or `if_modified_since` unmet.
        NotModified,
        /// 416: a range past the blob's end.
        InvalidRange,
        /// 408.
        RequestTimeout,
        /// 429, and 503 `ServerBusy`: the account's limits.
        Throttled,
        /// Any other 5xx.
        ServerError,
        /// 500 `FeatureNotSupported`, Azurite's answer to what it does not
        /// emulate; never tried again.
        FeatureNotSupported,
        /// Any other status.
        Refused,
    };

    pub fn refusal(scratch: Allocator, res: transport.Response, diagnostics: ?*Diagnostics) (RefusalError || Allocator.Error) {
        const body = try readError(scratch, res.body);
        const code = res.header("x-ms-error-code") orelse body.code orelse "";
        const request_id = res.header("x-ms-request-id");
        log.debug("refused {d} {f}: request {f}", .{ res.status, core.logging.escaped(code), core.logging.escaped(request_id orelse "-") });
        if (diagnostics) |d| {
            d.set(res.status, code, body.message orelse res.body);
            if (request_id) |id| d.setRequestId(id);
        }
        return errorFor(res.status, code);
    }

    pub fn errorFor(status: u16, code: []const u8) RefusalError {
        return switch (status) {
            304 => error.NotModified,
            400 => error.BadRequest,
            401 => error.Unauthenticated,
            403 => error.PermissionDenied,
            404 => if (std.mem.eql(u8, code, "ContainerNotFound")) error.ContainerNotFound else error.NotFound,
            408 => error.RequestTimeout,
            409 => if (std.mem.eql(u8, code, "BlobAlreadyExists"))
                error.PreconditionFailed
            else if (std.mem.eql(u8, code, "ContainerAlreadyExists"))
                error.ContainerAlreadyExists
            else
                error.Conflict,
            412 => error.PreconditionFailed,
            416 => error.InvalidRange,
            429 => error.Throttled,
            500 => if (std.mem.eql(u8, code, "FeatureNotSupported")) error.FeatureNotSupported else error.ServerError,
            503 => error.Throttled,
            501...502, 504...599 => error.ServerError,
            else => error.Refused,
        };
    }

    /// azcore's retried set: 408, 429, 500, 502, 503 and 504, and the
    /// transport's transient failures; never Azurite's `FeatureNotSupported`.
    pub fn retryable(err: anyerror, http_status: u16) bool {
        if (err == error.FeatureNotSupported) return false;
        if (http_status == 0) return core.isRetryable(err);
        return switch (http_status) {
            408, 429, 500, 502, 503, 504 => true,
            else => false,
        };
    }

    /// Blob Storage's bodies carry no retry delay; its headers may.
    pub fn bodyDelayMs(scratch: Allocator, body: []const u8) Allocator.Error!?u32 {
        _ = scratch;
        _ = body;
        return null;
    }
};

const ErrorBody = struct {
    code: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

/// The code and the message's first line, from an `<Error>` body; nothing
/// from any other.
fn readError(scratch: Allocator, body: []const u8) Allocator.Error!ErrorBody {
    const root = xml.parse(scratch, body) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidResponse => return .{},
    };
    if (!std.mem.eql(u8, root.name, "Error")) return .{};
    const message = root.childText("Message");
    return .{
        .code = root.childText("Code"),
        // The service adds RequestId and Time lines, which Diagnostics
        // keeps on their own.
        .message = if (message) |m| m[0 .. std.mem.indexOfScalar(u8, m, '\n') orelse m.len] else null,
    };
}

const testing = std.testing;

/// Bodies as production sent them on 2026-11-07 (t14's m0), the request
/// ids and times kept.
const recorded = struct {
    const blob_already_exists = xml.bom ++ "<?xml version=\"1.0\" encoding=\"utf-8\"?><Error><Code>BlobAlreadyExists</Code><Message>The specified blob already exists.\nRequestId:0869ae09-901e-0069-2cb8-6e8396000000\nTime:2026-11-07T13:00:53.1046211Z</Message></Error>";
    const condition_not_met = xml.bom ++ "<?xml version=\"1.0\" encoding=\"utf-8\"?><Error><Code>ConditionNotMet</Code><Message>The condition specified using HTTP conditional header(s) is not met.\nRequestId:43310566-101e-0058-7cb8-6e6285000000\nTime:2026-11-07T13:00:53.3188252Z</Message></Error>";
    const invalid_range = xml.bom ++ "<?xml version=\"1.0\" encoding=\"utf-8\"?><Error><Code>InvalidRange</Code><Message>The range specified is invalid for the current size of the resource.\nRequestId:4d17a1e5-c01e-0016-0cb8-6e4c0d000000\nTime:2026-11-07T13:00:56.3793657Z</Message></Error>";
    const container_not_found = xml.bom ++ "<?xml version=\"1.0\" encoding=\"utf-8\"?><Error><Code>ContainerNotFound</Code><Message>The specified container does not exist.\nRequestId:0a8fd009-901e-0046-1cb8-6e8e5d000000\nTime:2026-11-07T13:00:57.8421706Z</Message></Error>";
    const authentication_failed = xml.bom ++ "<?xml version=\"1.0\" encoding=\"utf-8\"?><Error><Code>AuthenticationFailed</Code><Message>Server failed to authenticate the request. Make sure the value of Authorization header is formed correctly including the signature.\nRequestId:2cafb099-c01e-005b-2fb8-6e83e1000000\nTime:2026-11-07T13:00:55.5483553Z</Message><AuthenticationErrorDetail>The MAC signature found in the HTTP request 'x' is not the same as any computed signature.</AuthenticationErrorDetail></Error>";
};

fn refusalOf(status: u16, code: ?[]const u8, body: []const u8, diag: *Diagnostics) anyerror {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var headers: [2]transport.Header = undefined;
    var n: usize = 0;
    headers[n] = .{ .name = "x-ms-request-id", .value = "r-1" };
    n += 1;
    if (code) |c| {
        headers[n] = .{ .name = "x-ms-error-code", .value = c };
        n += 1;
    }
    return Hook.refusal(arena.allocator(), .{ .status = status, .body = body, .headers = headers[0..n] }, diag);
}

test "production's refusals: the code, the message's first line, the request id" {
    var diag: Diagnostics = .{};
    try testing.expectEqual(error.PreconditionFailed, refusalOf(409, "BlobAlreadyExists", recorded.blob_already_exists, &diag));
    try testing.expectEqualStrings("BlobAlreadyExists", diag.code());
    try testing.expectEqualStrings("The specified blob already exists.", diag.message());
    try testing.expectEqualStrings("r-1", diag.requestId());
    try testing.expectEqual(409, diag.http_status);

    try testing.expectEqual(error.PreconditionFailed, refusalOf(412, "ConditionNotMet", recorded.condition_not_met, &diag));
    try testing.expectEqual(error.InvalidRange, refusalOf(416, "InvalidRange", recorded.invalid_range, &diag));
    try testing.expectEqual(error.ContainerNotFound, refusalOf(404, "ContainerNotFound", recorded.container_not_found, &diag));
    try testing.expectEqual(error.PermissionDenied, refusalOf(403, "AuthenticationFailed", recorded.authentication_failed, &diag));
    try testing.expectStringStartsWith(diag.message(), "Server failed to authenticate the request.");

    // The code from the body alone, when the header is missing.
    try testing.expectEqual(error.ContainerNotFound, refusalOf(404, null, recorded.container_not_found, &diag));
    try testing.expectEqualStrings("ContainerNotFound", diag.code());
    // A HEAD's refusal: the header and no body.
    try testing.expectEqual(error.NotFound, refusalOf(404, "BlobNotFound", "", &diag));
    try testing.expectEqualStrings("BlobNotFound", diag.code());
    // A gateway's page: the status, and the body as the message.
    try testing.expectEqual(error.ServerError, refusalOf(502, null, "<html>Bad Gateway</html>", &diag));
    try testing.expectEqualStrings("", diag.code());
    try testing.expectEqualStrings("<html>Bad Gateway</html>", diag.message());
}

test "statuses and codes to errors" {
    try testing.expectEqual(error.NotModified, Hook.errorFor(304, ""));
    try testing.expectEqual(error.ContainerAlreadyExists, Hook.errorFor(409, "ContainerAlreadyExists"));
    try testing.expectEqual(error.Conflict, Hook.errorFor(409, "ContainerBeingDeleted"));
    try testing.expectEqual(error.Throttled, Hook.errorFor(503, "ServerBusy"));
    try testing.expectEqual(error.Throttled, Hook.errorFor(429, ""));
    try testing.expectEqual(error.ServerError, Hook.errorFor(500, "OperationTimedOut"));
    try testing.expectEqual(error.FeatureNotSupported, Hook.errorFor(500, "FeatureNotSupported"));
    try testing.expectEqual(error.Refused, Hook.errorFor(418, ""));
}

test "retried: azcore's statuses and transient transport failures, never FeatureNotSupported" {
    for ([_]u16{ 408, 429, 500, 502, 503, 504 }) |s| try testing.expect(Hook.retryable(error.ServerError, s));
    for ([_]u16{ 400, 403, 404, 409, 412, 416, 501 }) |s| try testing.expect(!Hook.retryable(error.BadRequest, s));
    try testing.expect(!Hook.retryable(error.FeatureNotSupported, 500));
    try testing.expect(Hook.retryable(error.ConnectionResetByPeer, 0));
}
