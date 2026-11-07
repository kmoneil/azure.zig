//! Entra ID's v2 token endpoint, `{authority host}{tenant}/oauth2/v2.0/token`,
//! as every credential that proves itself to Entra uses it: a form posted,
//! a token or a refusal back. The loop is a credential's own, not a
//! service's engine, since what fails here is a `TokenProvider.Error`.
//!
//! 408, 429 and 5xx, and transient transport failures, are tried again
//! with backoff, honouring `Retry-After`. A refusal's code, AADSTS message,
//! trace id and correlation id go to `Diagnostics`; nothing of a body that
//! may hold a token is ever logged.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const transport = core.transport;
const TokenProvider = core.TokenProvider;
const Cache = @import("Cache.zig");
const token_response = @import("token_response.zig");

const log = core.logging.Scoped(.azure_auth);

/// azcore's policy for token requests: four attempts, the first retry
/// within 800 ms, a server's delay honoured up to a minute.
pub const retry_policy: core.RetryPolicy = .{
    .max_attempts = 4,
    .initial_backoff_ms = 800,
    .max_backoff_ms = 60_000,
};

/// What one credential's requests go through.
pub const Exchange = struct {
    transport: transport.Transport,
    retry: core.RetryPolicy = retry_policy,
    request_timeout_ms: u32 = 30_000,
    diagnostics: ?*core.Diagnostics = null,
};

/// The token URL for `tenant` at `authority_host`, which ends in `/`.
pub fn tokenUrl(gpa: Allocator, authority_host: []const u8, tenant: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "{s}{s}/oauth2/v2.0/token", .{ authority_host, tenant });
}

/// Whether `text` is a GUID, `8-4-4-4-12` hex digits.
pub fn isGuid(text: []const u8) bool {
    if (text.len != 36) return false;
    for (text, 0..) |c, i| switch (i) {
        8, 13, 18, 23 => if (c != '-') return false,
        else => if (!std.ascii.isHex(c)) return false,
    };
    return true;
}

/// What is wrong with a tenant for an app's own sign-in, or null: a GUID,
/// or a domain such as `contoso.onmicrosoft.com`. `common`, `organizations`
/// and `consumers` choose a tenant by the user signing in, and an app has
/// none: Entra refuses them for client credentials (700016, measured).
pub fn tenantProblem(tenant: []const u8) ?[]const u8 {
    if (tenant.len == 0 or tenant.len > 256) return "a tenant is its id or a domain";
    for ([_][]const u8{ "common", "organizations", "consumers" }) |multi| {
        if (std.ascii.eqlIgnoreCase(tenant, multi)) return "an app signs in to its own tenant: give its id or domain, not common, organizations or consumers";
    }
    if (isGuid(tenant)) return null;
    for (tenant) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-')) return "a tenant is its id or a domain: letters, digits, '.' and '-'";
    if (std.mem.indexOfScalar(u8, tenant, '.') == null) return "a tenant is its id or a domain";
    return null;
}

/// Whether `scope` is one an app can ask for alone: a resource's
/// `/.default`, visible ASCII. Entra refuses anything else for an app's
/// own sign-in (1002012, measured).
pub fn isAppScope(scope: []const u8) bool {
    return std.mem.endsWith(u8, scope, "/.default") and scope.len > "/.default".len and TokenProvider.isValidToken(scope);
}

/// Posts `body` to `url` until it gives a token, fails for good, or the
/// attempts run out. `arena` is the cache's wiped scratch memory: the body
/// holds a secret, and the answer a token.
pub fn post(ex: Exchange, io: std.Io, arena: Allocator, url: []const u8, body: []const u8) TokenProvider.Error!Cache.Fetched {
    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        var asked: ?u32 = null;
        switch (try exchange(ex, io, arena, url, body, &asked)) {
            .token => |fetched| return fetched,
            .fail => |err| return err,
            .retry => |err| {
                if (attempt >= ex.retry.max_attempts) return err;
                const delay_ms = ex.retry.waitMs(attempt, core.loop.entropy(io), asked) orelse {
                    log.warn("the token endpoint failed with {t}; not retried: it asked to wait longer than {d} ms", .{ err, ex.retry.max_backoff_ms });
                    return err;
                };
                log.warn("the token endpoint failed with {t}; retrying in {d} ms (attempt {d} of {d})", .{ err, delay_ms, attempt + 1, ex.retry.max_attempts });
                try io.sleep(.fromMilliseconds(delay_ms), .awake);
            },
        }
    }
}

const Result = union(enum) {
    token: Cache.Fetched,
    /// Worth another attempt.
    retry: TokenProvider.Error,
    fail: TokenProvider.Error,
};

fn exchange(ex: Exchange, io: std.Io, arena: Allocator, url: []const u8, body: []const u8, asked: *?u32) Allocator.Error!Result {
    const res = ex.transport.send(.{
        .method = .POST,
        .url = url,
        .body = body,
        .content_type = .form,
        .timeout_ms = ex.request_timeout_ms,
    }, arena) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (ex.diagnostics) |d| d.print("the token endpoint could not be reached: {t}", .{err});
        return if (core.isRetryable(err)) .{ .retry = err } else .{ .fail = err };
    };
    if (res.status == 200) {
        const now_s = std.Io.Clock.real.now(io).toSeconds();
        const fetched = token_response.parse(arena, res.body, now_s) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidTokenResponse => {
                if (ex.diagnostics) |d| d.print("the token endpoint's answer has no usable access_token and expiry", .{});
                return .{ .fail = error.InvalidTokenResponse };
            },
        };
        if (ex.diagnostics) |d| d.clear();
        return .{ .token = fetched };
    }
    const refusal = try token_response.parseRefusal(arena, res.body);
    record(ex.diagnostics, res, refusal);
    asked.* = core.retry_after.serverDelayMs(transport.Header, res.headers, std.Io.Clock.real.now(io));
    return switch (res.status) {
        408, 429, 500...599 => .{ .retry = error.TokenUnavailable },
        else => .{ .fail = errorFor(refusal) },
    };
}

/// An expired secret, or a grant Entra will no longer honour, needs a new
/// credential, not another try; any other refusal is the endpoint's.
fn errorFor(refusal: ?token_response.Refusal) TokenProvider.Error {
    const r = refusal orelse return error.TokenEndpointRejected;
    if (std.mem.eql(u8, r.code, "invalid_grant")) return error.ReauthenticationRequired;
    // 7000222: the secret has expired.
    if (r.hasCode(7000222)) return error.ReauthenticationRequired;
    return error.TokenEndpointRejected;
}

fn record(diagnostics: ?*core.Diagnostics, res: transport.Response, refusal: ?token_response.Refusal) void {
    const d = diagnostics orelse return;
    if (refusal) |r| {
        d.set(res.status, r.code, r.message);
        if (r.trace_id.len > 0) d.setRequestId(r.trace_id) else if (res.header("x-ms-request-id")) |id| d.setRequestId(id);
        if (r.correlation_id.len > 0) d.setCorrelationId(r.correlation_id);
    } else {
        d.set(res.status, "", "the token endpoint refused the request without an Entra error body");
        if (res.header("x-ms-request-id")) |id| d.setRequestId(id);
    }
}

const testing = std.testing;
const FakeTransport = core.testing.FakeTransport;

fn ok(body: []const u8) FakeTransport.Reply {
    return .{ .respond = .{ .status = 200, .body = body } };
}

fn refused(status: u16, body: []const u8) FakeTransport.Reply {
    return .{ .respond = .{ .status = status, .body = body } };
}

test "tenants, GUIDs and scopes" {
    try testing.expect(isGuid("0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"));
    for ([_][]const u8{ "", "0a1b2c3d4e5f4a6b8c7d9e0f1a2b3c4d", "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4g", "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4" }) |bad| try testing.expect(!isGuid(bad));
    for ([_][]const u8{ "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", "contoso.onmicrosoft.com", "example.com" }) |ok_tenant| try testing.expectEqual(null, tenantProblem(ok_tenant));
    for ([_][]const u8{ "", "common", "Organizations", "consumers", "contoso", "a/b.com", "a b.com", "evil.com/../x", "x.com?y" }) |bad| {
        errdefer std.debug.print("accepted {s}\n", .{bad});
        try testing.expect(tenantProblem(bad) != null);
    }
    try testing.expect(isAppScope("https://management.core.windows.net//.default"));
    try testing.expect(isAppScope("https://storage.azure.com/.default"));
    for ([_][]const u8{ "/.default", "https://management.azure.com/user_impersonation", "a b/.default", "" }) |bad| try testing.expect(!isAppScope(bad));
}

test "post: a token, after a throttled answer and a dropped connection" {
    var fake: FakeTransport = .init(testing.allocator, &.{
        .{ .respond = .{ .status = 429, .body = "{\"error\":\"temporarily_unavailable\"}", .headers = &.{.{ .name = "Retry-After", .value = "1" }} } },
        .{ .fail = error.ConnectionResetByPeer },
        ok(token_response.recorded.token),
    });
    defer fake.deinit();
    var clock: core.testing.FakeClock = .{};
    var diag: core.Diagnostics = .{};
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try post(.{ .transport = fake.transport(), .diagnostics = &diag }, clock.io(), arena.allocator(), "https://login.microsoftonline.com/t/oauth2/v2.0/token", "grant_type=client_credentials");
    try testing.expectEqual(3599, got.expires_in);
    try testing.expectEqual(3, fake.requests.items.len);
    const sent = try fake.request(0);
    try testing.expectEqual(.POST, sent.method);
    try testing.expectEqual(.form, sent.content_type);
    try testing.expectEqualStrings("grant_type=client_credentials", sent.body.?);
    try testing.expectEqual(0, diag.http_status);
}

test "post: Entra's refusals, as m0 recorded them, into Diagnostics and the error" {
    var clock: core.testing.FakeClock = .{};
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Case = struct { status: u16, body: []const u8, err: TokenProvider.Error, code: []const u8 };
    for ([_]Case{
        .{ .status = 401, .body = token_response.recorded.bad_secret, .err = error.TokenEndpointRejected, .code = "invalid_client" },
        .{ .status = 400, .body = token_response.recorded.unknown_app, .err = error.TokenEndpointRejected, .code = "unauthorized_client" },
        .{ .status = 400, .body = token_response.recorded.bad_scope, .err = error.TokenEndpointRejected, .code = "invalid_scope" },
        .{ .status = 401, .body = "{\"error\":\"invalid_client\",\"error_description\":\"AADSTS7000222: The provided client secret keys for app 'x' are expired.\",\"error_codes\":[7000222]}", .err = error.ReauthenticationRequired, .code = "invalid_client" },
        .{ .status = 400, .body = "{\"error\":\"invalid_grant\",\"error_description\":\"AADSTS700082: The refresh token has expired.\",\"error_codes\":[700082]}", .err = error.ReauthenticationRequired, .code = "invalid_grant" },
        .{ .status = 403, .body = "<html>no</html>", .err = error.TokenEndpointRejected, .code = "" },
    }) |case| {
        var fake: FakeTransport = .init(testing.allocator, &.{refused(case.status, case.body)});
        defer fake.deinit();
        var diag: core.Diagnostics = .{};
        try testing.expectError(case.err, post(.{ .transport = fake.transport(), .diagnostics = &diag }, clock.io(), arena.allocator(), "https://login.microsoftonline.com/t/oauth2/v2.0/token", "b"));
        try testing.expectEqual(1, fake.requests.items.len);
        try testing.expectEqual(case.status, diag.http_status);
        try testing.expectEqualStrings(case.code, diag.code());
    }
    var fake: FakeTransport = .init(testing.allocator, &.{refused(401, token_response.recorded.bad_secret)});
    defer fake.deinit();
    var diag: core.Diagnostics = .{};
    _ = post(.{ .transport = fake.transport(), .diagnostics = &diag }, clock.io(), arena.allocator(), "https://login.microsoftonline.com/t/oauth2/v2.0/token", "b") catch {};
    try testing.expectStringStartsWith(diag.message(), "AADSTS7000215: Invalid client secret provided.");
    try testing.expectEqualStrings("519f89dc-fb52-4a06-83f2-a0aa73094200", diag.requestId());
    try testing.expectEqualStrings("66aa9c7a-670c-4c8b-8672-2619acdc74ca", diag.correlationId());
}

test "post: a server that stays down is TokenUnavailable after four attempts" {
    const down = refused(503, "");
    var fake: FakeTransport = .init(testing.allocator, &.{ down, down, down, down, down });
    defer fake.deinit();
    var clock: core.testing.FakeClock = .{};
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.TokenUnavailable, post(.{ .transport = fake.transport() }, clock.io(), arena.allocator(), "https://login.microsoftonline.com/t/oauth2/v2.0/token", "b"));
    try testing.expectEqual(4, fake.requests.items.len);
}
