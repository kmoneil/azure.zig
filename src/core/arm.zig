//! Azure Resource Manager's side of rest-core's request loop: how a refused
//! response reads, which failures are tried again, and the paths that ARM's
//! next pages and long-running operations are followed on.
//!
//! ARM's error body is `{"error":{"code","message","target","details",
//! "additionalInfo"}}`. It is read leniently: a body of another shape, as a
//! gateway's HTML page is, still gives the status and the request id, and
//! a provider that sends `code` and `message` at the top level is read too.

const std = @import("std");
const Allocator = std.mem.Allocator;
const rest_core = @import("rest_core");
const transport = rest_core.transport;
const Diagnostics = rest_core.Diagnostics;
const origin = @import("origin.zig");

const log = rest_core.logging.Scoped(.azure_arm);

/// The request loop over ARM, logging under `log_scope`.
pub fn Engine(comptime log_scope: @EnumLiteral()) type {
    return rest_core.Engine(log_scope, Hook);
}

/// ARM's retry policy, as azcore's: four attempts, the first retry within
/// 800 ms, and a server's delay honoured up to a minute. ARM's 429s can ask
/// for longer; such a call returns at once, the delay in `Diagnostics`, for
/// the caller to schedule.
pub const retry_policy: rest_core.RetryPolicy = .{
    .max_attempts = 4,
    .initial_backoff_ms = 800,
    .max_backoff_ms = 60_000,
};

/// The engine's headers for every ARM call: ARM echoes the call's own
/// `x-ms-client-request-id` when asked to.
pub const engine_headers = [_]transport.Header{
    .{ .name = "x-ms-return-client-request-id", .value = "true" },
};

/// A fresh `x-ms-client-request-id`, a random (version 4) UUID: one per
/// call, the same on each of its attempts, so a call can be matched to
/// ARM's records of it.
pub fn clientRequestId(io: std.Io) [36]u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(bytes, .lower);
    var out: [36]u8 = undefined;
    var at: usize = 0;
    for ([_][2]usize{ .{ 0, 8 }, .{ 8, 12 }, .{ 12, 16 }, .{ 16, 20 }, .{ 20, 32 } }, 0..) |span, i| {
        if (i > 0) {
            out[at] = '-';
            at += 1;
        }
        @memcpy(out[at..][0 .. span[1] - span[0]], hex[span[0]..span[1]]);
        at += span[1] - span[0];
    }
    return out;
}

/// What rest-core's loop asks of a cloud, answered for ARM.
pub const Hook = struct {
    /// What a refused response is.
    pub const RefusalError = error{
        /// 400: the request is malformed, or names something that cannot be.
        BadRequest,
        /// 401, after the loop's one more try with a fresh token.
        Unauthenticated,
        /// 403: the principal lacks a role, as `AuthorizationFailed` says.
        PermissionDenied,
        NotFound,
        /// 408.
        RequestTimeout,
        /// 409: another operation holds the resource, or it exists already.
        Conflict,
        PreconditionFailed,
        /// 429: a throttle, ARM's or a resource provider's, or a lock
        /// (`RetryableErrorDueToAnotherOperation`).
        Throttled,
        /// 5xx.
        ServerError,
        /// The subscription has not registered the resource provider, which
        /// only a principal with rights at subscription scope can do.
        ProviderNotRegistered,
        /// Any other status.
        Refused,
    };

    /// Reads a refused response into `diagnostics` and returns its error.
    pub fn refusal(scratch: Allocator, res: transport.Response, diagnostics: ?*Diagnostics) (RefusalError || Allocator.Error) {
        const body = try readError(scratch, res.body);
        record(res, body, diagnostics);
        if (body.code) |code| if (isUnregistered(code)) return error.ProviderNotRegistered;
        return errorFor(res.status);
    }

    /// The refusal in `diagnostics`, with its two ids: the resource
    /// provider's `x-ms-request-id`, and ARM's own
    /// `x-ms-correlation-request-id`, the one Azure support asks for first.
    /// Both are logged at debug level, escaped, since a server wrote them.
    fn record(res: transport.Response, body: ErrorBody, diagnostics: ?*Diagnostics) void {
        const request_id = res.header("x-ms-request-id");
        const correlation_id = res.header("x-ms-correlation-request-id");
        log.debug("refused {d}: request {f}, correlation {f}", .{
            res.status, rest_core.logging.escaped(request_id orelse "-"), rest_core.logging.escaped(correlation_id orelse "-"),
        });
        const d = diagnostics orelse return;
        d.set(res.status, body.code orelse "", body.message orelse res.body);
        if (request_id) |id| d.setRequestId(id);
        if (correlation_id) |id| d.setCorrelationId(id);
    }

    fn errorFor(status: u16) RefusalError {
        return switch (status) {
            400 => error.BadRequest,
            401 => error.Unauthenticated,
            403 => error.PermissionDenied,
            404 => error.NotFound,
            408 => error.RequestTimeout,
            409 => error.Conflict,
            412 => error.PreconditionFailed,
            429 => error.Throttled,
            500...599 => error.ServerError,
            else => error.Refused,
        };
    }

    /// Azure's retried set, as azcore's: 408, 429, 500, 502, 503 and 504,
    /// and the transport's own transient failures.
    pub fn retryable(err: anyerror, http_status: u16) bool {
        if (http_status == 0) return rest_core.isRetryable(err);
        return switch (http_status) {
            408, 429, 500, 502, 503, 504 => true,
            else => false,
        };
    }

    /// ARM's bodies carry no retry delay; its headers do.
    pub fn bodyDelayMs(scratch: Allocator, body: []const u8) Allocator.Error!?u32 {
        _ = scratch;
        _ = body;
        return null;
    }
};

/// What a refused response's body says, as far as it can be read.
const ErrorBody = struct {
    code: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

fn readError(scratch: Allocator, body: []const u8) Allocator.Error!ErrorBody {
    const Wrapped = struct {
        @"error": ?ErrorBody = null,
        code: ?[]const u8 = null,
        message: ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSliceLeaky(Wrapped, scratch, body, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{},
    };
    if (parsed.@"error") |inner| return inner;
    return .{ .code = parsed.code, .message = parsed.message };
}

/// The four ways ARM spells an unregistered provider, in any case.
fn isUnregistered(code: []const u8) bool {
    const spellings = [_][]const u8{
        "MissingSubscriptionRegistration",
        "MissingRegistrationForResourceProvider",
        "Subscription Not Registered",
        "SubscriptionNotRegistered",
    };
    for (spellings) |s| if (std.ascii.eqlIgnoreCase(code, s)) return true;
    return false;
}

/// The path of a list's next page, from its `nextLink`, which ARM gives as
/// an absolute URL to be followed exactly: null when there is none (the
/// link missing, null or empty), and `error.InvalidEndpoint` when it names
/// another origin than `base_url`, so the bearer token never follows a link
/// off ARM.
pub fn nextPagePath(base_url: []const u8, next_link: ?[]const u8) error{InvalidEndpoint}!?[]const u8 {
    const link = next_link orelse return null;
    if (link.len == 0) return null;
    return origin.pathOnOrigin(base_url, link) orelse error.InvalidEndpoint;
}

/// Where a long-running operation is polled, and how its answer reads.
pub const Poll = struct {
    kind: Kind,
    url: []const u8,

    pub const Kind = enum {
        /// `Azure-AsyncOperation`: the body's `status` says the state.
        async_operation,
        /// `Operation-Location`: read as `Azure-AsyncOperation` is.
        operation_location,
        /// `Location`: 202 while running, another 2xx when done.
        location,
    };
};

/// The URL a 201 or 202 says to poll: `Azure-AsyncOperation`, then
/// `Operation-Location`, then `Location`. Null when it names none, and the
/// resource's own `provisioningState` is what to poll.
pub fn pollOf(headers: []const transport.Header) ?Poll {
    const order = [_]struct { []const u8, Poll.Kind }{
        .{ "azure-asyncoperation", .async_operation },
        .{ "operation-location", .operation_location },
        .{ "location", .location },
    };
    for (order) |entry| {
        for (headers) |h| if (std.ascii.eqlIgnoreCase(h.name, entry[0])) return .{ .kind = entry[1], .url = h.value };
    }
    return null;
}

pub const OperationState = enum { running, succeeded, failed, canceled };

/// An operation's `status`, or a resource's `provisioningState`, in any
/// case: Succeeded and Completed are success, Failed fails, Canceled and
/// Cancelled are canceled, and anything else (Accepted, Creating,
/// InProgress, Updating) is still running.
pub fn operationState(status: []const u8) OperationState {
    if (std.ascii.eqlIgnoreCase(status, "Succeeded") or std.ascii.eqlIgnoreCase(status, "Completed")) return .succeeded;
    if (std.ascii.eqlIgnoreCase(status, "Failed")) return .failed;
    if (std.ascii.eqlIgnoreCase(status, "Canceled") or std.ascii.eqlIgnoreCase(status, "Cancelled")) return .canceled;
    return .running;
}

const testing = std.testing;

test "readError: ARM's body, a top-level one, and what is neither" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const wrapped = try readError(a, "{\"error\":{\"code\":\"ResourceNotFound\",\"message\":\"gone\",\"target\":\"vm\",\"details\":[{\"code\":\"X\",\"message\":\"y\"}],\"additionalInfo\":[{\"type\":\"PolicyViolation\",\"info\":{\"a\":1}}]}}");
    try testing.expectEqualStrings("ResourceNotFound", wrapped.code.?);
    try testing.expectEqualStrings("gone", wrapped.message.?);

    const top = try readError(a, "{\"code\":\"InvalidApiVersionParameter\",\"message\":\"no such api-version\"}");
    try testing.expectEqualStrings("InvalidApiVersionParameter", top.code.?);

    for ([_][]const u8{ "<html>502 Bad Gateway</html>", "", "{\"error\":\"invalid_client\"}", "{\"error\":{\"code\":7}}" }) |body| {
        const none = try readError(a, body);
        try testing.expectEqual(null, none.code);
        try testing.expectEqual(null, none.message);
    }
}

test "isUnregistered: the four spellings, in any case" {
    try testing.expect(isUnregistered("MissingSubscriptionRegistration"));
    try testing.expect(isUnregistered("missingregistrationforresourceprovider"));
    try testing.expect(isUnregistered("Subscription Not Registered"));
    try testing.expect(isUnregistered("SUBSCRIPTIONNOTREGISTERED"));
    try testing.expect(!isUnregistered("AuthorizationFailed"));
    try testing.expect(!isUnregistered(""));
}

test "operationState: terminal states in any case, the rest running" {
    try testing.expectEqual(.succeeded, operationState("succeeded"));
    try testing.expectEqual(.succeeded, operationState("Completed"));
    try testing.expectEqual(.failed, operationState("FAILED"));
    try testing.expectEqual(.canceled, operationState("Canceled"));
    try testing.expectEqual(.canceled, operationState("Cancelled"));
    for ([_][]const u8{ "InProgress", "Accepted", "Creating", "Updating", "" }) |s| {
        try testing.expectEqual(.running, operationState(s));
    }
}

test "clientRequestId: a version 4 UUID, new each time" {
    var clock: rest_core.testing.FakeClock = .{};
    const a = clientRequestId(clock.io());
    const b = clientRequestId(clock.io());
    try testing.expect(!std.mem.eql(u8, &a, &b));
    for ([_]usize{ 8, 13, 18, 23 }) |i| try testing.expectEqual('-', a[i]);
    try testing.expectEqual('4', a[14]);
    try testing.expect(std.mem.indexOfScalar(u8, "89ab", a[19]) != null);
    for (a, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) continue;
        try testing.expect(std.ascii.isHex(c) and !std.ascii.isUpper(c));
    }
}

test "pollOf: Azure-AsyncOperation before Operation-Location before Location" {
    const all = [_]transport.Header{
        .{ .name = "Location", .value = "https://management.azure.com/l" },
        .{ .name = "Operation-Location", .value = "https://management.azure.com/o" },
        .{ .name = "azure-asyncoperation", .value = "https://management.azure.com/a" },
    };
    try testing.expectEqual(.async_operation, pollOf(&all).?.kind);
    try testing.expectEqualStrings("https://management.azure.com/a", pollOf(&all).?.url);
    try testing.expectEqual(.operation_location, pollOf(all[0..2]).?.kind);
    try testing.expectEqual(.location, pollOf(all[0..1]).?.kind);
    try testing.expectEqual(null, pollOf(&.{.{ .name = "Retry-After", .value = "5" }}));
}
