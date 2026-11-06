//! What azure.zig relies on rest-core for, held as tests: ARM's refusals
//! through the hook, Azure's retried set and the delays it asks for,
//! credentials through the token seam (a client secret, a certificate's
//! assertion, managed identity), long-running operations and pages followed
//! on ARM's origin, and Storage's Shared Key in a call's headers. A rest-core
//! release that breaks one fails here, before any module notices.
//!
//! They began as the trial that chose rest-core over a copy of gcp.zig's
//! core. The credentials here are sketches, as small as shows that the seam
//! holds each: no refresh ahead of expiry, no retries of their own, no
//! chain. auth's own come with auth.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const rest_core = @import("rest_core");
const transport = rest_core.transport;
const Header = transport.Header;
const TokenProvider = rest_core.TokenProvider;
const Diagnostics = rest_core.Diagnostics;
const FakeTransport = rest_core.testing.FakeTransport;
const arm = @import("arm.zig");

const Engine = arm.Engine(.azure_core_test);

const arm_url = "https://management.azure.com";
const arm_scope = "https://management.azure.com/.default";
const vm_path = "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Compute/virtualMachines/vm-1?api-version=2024-07-01";

/// A fake ARM, a fake clock and a fake token, and the engine over them.
const Rig = struct {
    fake: FakeTransport,
    clock: rest_core.testing.FakeClock = .{},
    token: rest_core.testing.FakeTokenProvider = .{ .token = "eyJ0.arm-token" },
    diag: Diagnostics = .{},

    fn init(script: []const FakeTransport.Reply) Rig {
        return .{ .fake = .init(testing.allocator, script) };
    }

    fn deinit(rig: *Rig) void {
        rig.fake.deinit();
    }

    fn engine(rig: *Rig) Engine {
        return .{
            .gpa = testing.allocator,
            .io = rig.clock.io(),
            .transport = rig.fake.transport(),
            .base_url = arm_url,
            .auth_scope = arm_scope,
            .token_provider = rig.token.provider(),
            .diagnostics = &rig.diag,
            .headers = &.{.{ .name = "x-ms-return-client-request-id", .value = "true" }},
        };
    }
};

fn get(engine: Engine, response: *std.heap.ArenaAllocator, path: []const u8) Engine.Error![]const u8 {
    engine.begin();
    return engine.execute(response, .{ .method = .GET, .path = path });
}

test "rest-core: ARM's refusal reads into Diagnostics, with the provider's request id" {
    const script = [_]FakeTransport.Reply{.{ .respond = .{
        .status = 404,
        .headers = &.{
            .{ .name = "x-ms-request-id", .value = "4b5c1d2e-0000-4000-8000-000000000001" },
            .{ .name = "x-ms-correlation-request-id", .value = "9f8e7d6c-0000-4000-8000-000000000002" },
        },
        .body = "{\"error\":{\"code\":\"ResourceNotFound\",\"message\":\"The Resource 'Microsoft.Compute/virtualMachines/vm-1' under resource group 'rg-1' was not found.\"}}",
    } }};
    var rig: Rig = .init(&script);
    defer rig.deinit();
    var response: std.heap.ArenaAllocator = .init(testing.allocator);
    defer response.deinit();

    try testing.expectError(error.NotFound, get(rig.engine(), &response, vm_path));
    try testing.expectEqual(1, rig.fake.requests.items.len);
    try testing.expectEqual(404, rig.diag.http_status);
    try testing.expectEqualStrings("ResourceNotFound", rig.diag.code());
    try testing.expectStringStartsWith(rig.diag.message(), "The Resource 'Microsoft.Compute/virtualMachines/vm-1'");
    try testing.expectEqualStrings("4b5c1d2e-0000-4000-8000-000000000001", rig.diag.requestId());
    // ARM's own x-ms-correlation-request-id, the id Azure support asks for
    // first, has nowhere to go: Diagnostics keeps one id.
}

test "rest-core: a provider the subscription has not registered is an error of its own" {
    const script = [_]FakeTransport.Reply{
        .{ .respond = .{ .status = 409, .body = "{\"error\":{\"code\":\"MissingSubscriptionRegistration\",\"message\":\"The subscription is not registered to use namespace 'Microsoft.Compute'.\"}}" } },
        .{ .respond = .{ .status = 409, .body = "{\"error\":{\"code\":\"Subscription Not Registered\",\"message\":\"Please register.\"}}" } },
        .{ .respond = .{ .status = 409, .body = "{\"error\":{\"code\":\"OperationNotAllowed\",\"message\":\"in use\"}}" } },
    };
    var rig: Rig = .init(&script);
    defer rig.deinit();
    var response: std.heap.ArenaAllocator = .init(testing.allocator);
    defer response.deinit();

    try testing.expectError(error.ProviderNotRegistered, get(rig.engine(), &response, vm_path));
    try testing.expectError(error.ProviderNotRegistered, get(rig.engine(), &response, vm_path));
    try testing.expectError(error.Conflict, get(rig.engine(), &response, vm_path));
    // None is retried: a 409 is not in Azure's set.
    try testing.expectEqual(3, rig.fake.requests.items.len);
}

test "rest-core: a body that is not ARM's still gives the status and the request id" {
    const script = [_]FakeTransport.Reply{.{ .respond = .{
        .status = 502,
        .headers = &.{.{ .name = "x-ms-request-id", .value = "r-502" }},
        .body = "<html><body>502 Bad Gateway</body></html>",
    } }};
    var rig: Rig = .init(&script);
    defer rig.deinit();
    var response: std.heap.ArenaAllocator = .init(testing.allocator);
    defer response.deinit();
    var engine = rig.engine();
    engine.retry.max_attempts = 1;

    try testing.expectError(error.ServerError, get(engine, &response, vm_path));
    try testing.expectEqualStrings("", rig.diag.code());
    try testing.expectStringStartsWith(rig.diag.message(), "<html>");
    try testing.expectEqualStrings("r-502", rig.diag.requestId());
}

test "rest-core: Azure's retried set is the hook's: 408, 429, 500, 502, 503, 504 and transport failures" {
    for ([_]u16{ 408, 429, 500, 502, 503, 504 }) |status| {
        const script = [_]FakeTransport.Reply{
            .{ .respond = .{ .status = status } },
            .{ .respond = .{ .body = "{\"name\":\"vm-1\"}" } },
        };
        var rig: Rig = .init(&script);
        defer rig.deinit();
        var response: std.heap.ArenaAllocator = .init(testing.allocator);
        defer response.deinit();
        try testing.expectEqualStrings("{\"name\":\"vm-1\"}", try get(rig.engine(), &response, vm_path));
        try testing.expectEqual(2, rig.fake.requests.items.len);
    }
    for ([_]u16{ 400, 403, 404, 409, 412, 501, 505 }) |status| {
        const script = [_]FakeTransport.Reply{.{ .respond = .{ .status = status } }};
        var rig: Rig = .init(&script);
        defer rig.deinit();
        var response: std.heap.ArenaAllocator = .init(testing.allocator);
        defer response.deinit();
        if (get(rig.engine(), &response, vm_path)) |_| return error.TestUnexpectedResult else |_| {}
        try testing.expectEqual(1, rig.fake.requests.items.len);
    }
    const script = [_]FakeTransport.Reply{
        .{ .fail = error.ConnectionResetByPeer },
        .{ .respond = .{} },
    };
    var rig: Rig = .init(&script);
    defer rig.deinit();
    var response: std.heap.ArenaAllocator = .init(testing.allocator);
    defer response.deinit();
    _ = try get(rig.engine(), &response, vm_path);
    try testing.expectEqual(2, rig.fake.requests.items.len);
}

test "rest-core: a 429 waits what Retry-After or x-ms-retry-after-ms asks" {
    const script = [_]FakeTransport.Reply{
        .{ .respond = .{ .status = 429, .headers = &.{.{ .name = "Retry-After", .value = "2" }}, .body = "{\"error\":{\"code\":\"TooManyRequests\",\"message\":\"slow down\"}}" } },
        .{ .respond = .{ .status = 429, .headers = &.{.{ .name = "x-ms-retry-after-ms", .value = "1500" }} } },
        .{ .respond = .{} },
    };
    var rig: Rig = .init(&script);
    defer rig.deinit();
    var response: std.heap.ArenaAllocator = .init(testing.allocator);
    defer response.deinit();

    _ = try get(rig.engine(), &response, vm_path);
    try testing.expectEqual(2, rig.clock.sleep_count);
    try testing.expectEqual(2_000, rig.clock.sleepMs(0));
    try testing.expectEqual(1_500, rig.clock.sleepMs(1));
}

test "rest-core: a delay longer than the policy waits comes back at once, the delay in Diagnostics" {
    // ARM's 429s can ask for more than azcore's 60 s cap, so azure.zig picks
    // its own `max_backoff_ms`; past it the caller schedules the next try.
    const script = [_]FakeTransport.Reply{.{ .respond = .{
        .status = 429,
        .headers = &.{.{ .name = "Retry-After", .value = "120" }},
        .body = "{\"error\":{\"code\":\"TooManyRequests\",\"message\":\"slow down\"}}",
    } }};
    var rig: Rig = .init(&script);
    defer rig.deinit();
    var response: std.heap.ArenaAllocator = .init(testing.allocator);
    defer response.deinit();
    var engine = rig.engine();
    engine.retry.max_backoff_ms = 60_000;

    try testing.expectError(error.Throttled, get(engine, &response, vm_path));
    try testing.expectEqual(1, rig.fake.requests.items.len);
    try testing.expectEqual(0, rig.clock.sleep_count);
    try testing.expectEqual(120_000, rig.diag.retry_after_ms.?);
}

test "rest-core: one x-ms-client-request-id on every attempt of a call" {
    const script = [_]FakeTransport.Reply{
        .{ .respond = .{ .status = 503 } },
        .{ .respond = .{} },
    };
    var rig: Rig = .init(&script);
    defer rig.deinit();
    var response: std.heap.ArenaAllocator = .init(testing.allocator);
    defer response.deinit();
    const id = "0f9e8d7c-6b5a-4c3d-8e2f-1a0b9c8d7e6f";

    const engine = rig.engine();
    engine.begin();
    _ = try engine.execute(&response, .{
        .method = .GET,
        .path = vm_path,
        .headers = &.{.{ .name = "x-ms-client-request-id", .value = id }},
    });
    try testing.expectEqual(2, rig.fake.requests.items.len);
    for (rig.fake.requests.items) |r| {
        try testing.expectEqualStrings(id, r.header("x-ms-client-request-id").?);
        try testing.expectEqualStrings("true", r.header("x-ms-return-client-request-id").?);
        try testing.expectEqualStrings("eyJ0.arm-token", r.bearer.?);
    }
}

test "rest-core: a 401 gets one more try, with a fresh token" {
    const script = [_]FakeTransport.Reply{
        .{ .respond = .{ .status = 401, .body = "{\"error\":{\"code\":\"ExpiredAuthenticationToken\",\"message\":\"The access token expiry UTC time is earlier than current UTC time.\"}}" } },
        .{ .respond = .{} },
    };
    var rig: Rig = .init(&script);
    defer rig.deinit();
    rig.token.next_token = "eyJ0.fresh-token";
    var response: std.heap.ArenaAllocator = .init(testing.allocator);
    defer response.deinit();

    _ = try get(rig.engine(), &response, vm_path);
    try testing.expectEqual(1, rig.token.invalidations);
    try testing.expectEqualStrings("eyJ0.fresh-token", (try rig.fake.request(1)).bearer.?);
}

test "rest-core: a list's next pages are followed on ARM's origin, and only there" {
    try testing.expectEqualStrings(
        "/subscriptions?api-version=2022-12-01&%24skiptoken=abc",
        (try arm.nextPagePath(arm_url, "https://management.azure.com/subscriptions?api-version=2022-12-01&%24skiptoken=abc")).?,
    );
    try testing.expectEqual(null, try arm.nextPagePath(arm_url, null));
    try testing.expectEqual(null, try arm.nextPagePath(arm_url, ""));
    for ([_][]const u8{
        "https://evil.example/subscriptions",
        "https://management.azure.com.evil.example/subscriptions",
        "https://management.azure.com@evil.example/subscriptions",
        "http://management.azure.com/subscriptions",
    }) |link| try testing.expectError(error.InvalidEndpoint, arm.nextPagePath(arm_url, link));
    // rest-core's own compares bytes, so the default port written out, as
    // the Retail Prices API writes every next page, or the host in another
    // case, is another origin to it (rest-core t39); core's compares
    // origins, and takes both.
    try testing.expectEqual(null, rest_core.loop.pathOnOrigin(arm_url, "https://management.azure.com:443/subscriptions"));
    try testing.expectEqualStrings("/subscriptions", (try arm.nextPagePath(arm_url, "https://management.azure.com:443/subscriptions")).?);
    try testing.expectEqualStrings("/subscriptions", (try arm.nextPagePath(arm_url, "https://Management.Azure.com/subscriptions")).?);

    // Through the loop: two pages, the second ending the list.
    const script = [_]FakeTransport.Reply{
        .{ .respond = .{ .body = "{\"value\":[{\"subscriptionId\":\"s-1\"}],\"nextLink\":\"https://management.azure.com/subscriptions?api-version=2022-12-01&%24skiptoken=p2\"}" } },
        .{ .respond = .{ .body = "{\"value\":[{\"subscriptionId\":\"s-2\"}]}" } },
    };
    var rig: Rig = .init(&script);
    defer rig.deinit();
    var response: std.heap.ArenaAllocator = .init(testing.allocator);
    defer response.deinit();
    var pages: std.heap.ArenaAllocator = .init(testing.allocator);
    defer pages.deinit();

    const Page = struct {
        value: []const struct { subscriptionId: []const u8 },
        nextLink: ?[]const u8 = null,
    };
    var seen: std.ArrayList([]const u8) = .empty;
    var path: ?[]const u8 = "/subscriptions?api-version=2022-12-01";
    while (path) |p| {
        const body = try get(rig.engine(), &response, p);
        // Copied out, so the response can be reset before the next page.
        const page = try std.json.parseFromSliceLeaky(Page, pages.allocator(), body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        for (page.value) |s| try seen.append(pages.allocator(), s.subscriptionId);
        path = try arm.nextPagePath(arm_url, page.nextLink);
        _ = response.reset(.retain_capacity);
    }
    try testing.expectEqual(2, seen.items.len);
    try testing.expectEqualStrings("s-2", seen.items[1]);
    try testing.expectEqualStrings("https://management.azure.com/subscriptions?api-version=2022-12-01&%24skiptoken=p2", (try rig.fake.request(1)).url);
}

/// The delay a 2xx asks for before the next poll, or ARM's default.
fn pollDelayMs(io: std.Io, headers: []const Header) u32 {
    return rest_core.retry_after.serverDelayMs(Header, headers, std.Io.Clock.real.now(io)) orelse 30_000;
}

test "rest-core: a long-running PUT is polled at its Azure-AsyncOperation URL, waiting what each answer asks" {
    const op_url = "https://management.azure.com/subscriptions/sub-1/providers/Microsoft.Compute/locations/eastus/operations/op-1?api-version=2024-07-01";
    const script = [_]FakeTransport.Reply{
        .{ .respond = .{
            .status = 201,
            .headers = &.{ .{ .name = "Azure-AsyncOperation", .value = op_url }, .{ .name = "Retry-After", .value = "5" } },
            .body = "{\"name\":\"vm-1\",\"properties\":{\"provisioningState\":\"Creating\"}}",
        } },
        .{ .respond = .{ .headers = &.{.{ .name = "Retry-After", .value = "3" }}, .body = "{\"status\":\"InProgress\"}" } },
        .{ .respond = .{ .body = "{\"status\":\"Succeeded\",\"startTime\":\"2026-11-06T22:00:00Z\"}" } },
        .{ .respond = .{ .body = "{\"name\":\"vm-1\",\"properties\":{\"provisioningState\":\"Succeeded\"}}" } },
    };
    var rig: Rig = .init(&script);
    defer rig.deinit();
    var response: std.heap.ArenaAllocator = .init(testing.allocator);
    defer response.deinit();
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const engine = rig.engine();
    const io = rig.clock.io();

    // `execute` gives back the body alone, so a call whose status and
    // headers matter, as every ARM write's do, goes through `executeStream`.
    engine.begin();
    const created = try engine.executeStream(&response, .{
        .method = .PUT,
        .path = vm_path,
        .content_type = "application/json",
        .body = .{ .segments = &.{"{\"location\":\"eastus\"}"} },
    });
    try testing.expectEqual(201, created.status);
    const poll = arm.pollOf(created.headers).?;
    try testing.expectEqual(.async_operation, poll.kind);
    const poll_path = try state.allocator().dupe(u8, rest_core.loop.pathOnOrigin(arm_url, poll.url).?);
    var delay_ms = pollDelayMs(io, created.headers);
    _ = response.reset(.retain_capacity);

    const Status = struct { status: []const u8 = "" };
    while (true) {
        try io.sleep(.fromMilliseconds(delay_ms), .awake);
        engine.begin();
        const answer = try engine.executeStream(&response, .{ .method = .GET, .path = poll_path });
        const status = try std.json.parseFromSliceLeaky(Status, state.allocator(), answer.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        delay_ms = pollDelayMs(io, answer.headers);
        _ = response.reset(.retain_capacity);
        switch (arm.operationState(status.status)) {
            .running => continue,
            .succeeded => break,
            .failed, .canceled => return error.TestUnexpectedResult,
        }
    }
    // A PUT's result is the resource itself, read again.
    const vm = try get(engine, &response, vm_path);
    try testing.expectStringEndsWith(vm, "\"provisioningState\":\"Succeeded\"}}");

    try testing.expectEqual(2, rig.clock.sleep_count);
    try testing.expectEqual(5_000, rig.clock.sleepMs(0));
    try testing.expectEqual(3_000, rig.clock.sleepMs(1));
    try testing.expectEqualStrings(op_url, (try rig.fake.streamRequest(1)).url);
    try testing.expectEqualStrings("application/json", (try rig.fake.streamRequest(0)).content_type.?);
}

test "rest-core: a Location poll is told apart by its status, which only executeStream returns" {
    const location = "https://management.azure.com/subscriptions/sub-1/operationresults/op-2?api-version=2021-04-01";
    const script = [_]FakeTransport.Reply{
        .{ .respond = .{ .status = 202, .headers = &.{ .{ .name = "Location", .value = location }, .{ .name = "Retry-After", .value = "1" } }, .body = "" } },
        .{ .respond = .{ .status = 202, .headers = &.{ .{ .name = "Location", .value = location }, .{ .name = "Retry-After", .value = "1" } }, .body = "" } },
        .{ .respond = .{ .status = 204, .body = "" } },
    };
    var rig: Rig = .init(&script);
    defer rig.deinit();
    var response: std.heap.ArenaAllocator = .init(testing.allocator);
    defer response.deinit();
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const engine = rig.engine();
    const io = rig.clock.io();

    engine.begin();
    const accepted = try engine.executeStream(&response, .{ .method = .DELETE, .path = "/subscriptions/sub-1/resourcegroups/rg-1?api-version=2021-04-01" });
    try testing.expectEqual(202, accepted.status);
    const poll = arm.pollOf(accepted.headers).?;
    try testing.expectEqual(.location, poll.kind);
    const poll_path = try state.allocator().dupe(u8, rest_core.loop.pathOnOrigin(arm_url, poll.url).?);
    var delay_ms = pollDelayMs(io, accepted.headers);
    _ = response.reset(.retain_capacity);

    var polls: usize = 0;
    while (true) {
        try io.sleep(.fromMilliseconds(delay_ms), .awake);
        engine.begin();
        const answer = try engine.executeStream(&response, .{ .method = .GET, .path = poll_path });
        polls += 1;
        delay_ms = pollDelayMs(io, answer.headers);
        const running = answer.status == 202;
        _ = response.reset(.retain_capacity);
        // To `execute`, a 202 and a 204 are both an empty body.
        if (!running) break;
    }
    try testing.expectEqual(2, polls);
    try testing.expectEqual(1_000, rig.clock.sleepMs(1));
}

/// A client secret's token from Entra's token endpoint: a sketch, to show
/// the seam holds one.
const ClientSecret = struct {
    transport: transport.Transport,
    token_url: []const u8,
    client_id: []const u8,
    secret: []const u8,
    /// Where Entra's refusal goes: a provider explains its own failure
    /// better than the loop can, and the loop leaves what it wrote.
    diagnostics: ?*Diagnostics = null,
    cached: [8192]u8 = undefined,
    cached_len: usize = 0,

    fn provider(self: *ClientSecret) TokenProvider {
        return .{ .ptr = self, .vtable = &.{ .getToken = getToken, .invalidate = invalidate } };
    }

    fn getToken(ptr: *anyopaque, io: std.Io, arena: Allocator, scopes: []const []const u8) TokenProvider.Error![]const u8 {
        _ = io;
        const self: *ClientSecret = @ptrCast(@alignCast(ptr));
        if (self.cached_len > 0) return arena.dupe(u8, self.cached[0..self.cached_len]);
        var form: std.Io.Writer.Allocating = .init(arena);
        writeForm(&form.writer, &.{
            .{ "client_id", self.client_id },
            .{ "scope", scopes[0] },
            .{ "client_secret", self.secret },
            .{ "grant_type", "client_credentials" },
        }) catch return error.OutOfMemory;
        const res = try self.transport.send(.{ .method = .POST, .url = self.token_url, .body = form.written(), .content_type = .form }, arena);
        const token = try readToken(arena, res, self.diagnostics);
        if (token.len > self.cached.len) return error.InvalidTokenResponse;
        @memcpy(self.cached[0..token.len], token);
        self.cached_len = token.len;
        return token;
    }

    fn invalidate(ptr: *anyopaque) void {
        const self: *ClientSecret = @ptrCast(@alignCast(ptr));
        std.crypto.secureZero(u8, self.cached[0..self.cached_len]);
        self.cached_len = 0;
    }
};

/// An `application/x-www-form-urlencoded` body.
fn writeForm(w: *std.Io.Writer, fields: []const [2][]const u8) std.Io.Writer.Error!void {
    for (fields, 0..) |field, i| {
        if (i > 0) try w.writeByte('&');
        try rest_core.query.writeValue(w, field[0]);
        try w.writeByte('=');
        try rest_core.query.writeValue(w, field[1]);
    }
}

/// The access token in a token endpoint's answer, or what its refusal is.
/// `expires_in` comes as a number from Entra and as a string from IMDS and
/// App Service: either is read.
fn readToken(arena: Allocator, res: transport.Response, diagnostics: ?*Diagnostics) TokenProvider.Error![]const u8 {
    const value: ?std.json.Value = std.json.parseFromSliceLeaky(std.json.Value, arena, res.body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    const object: ?std.json.ObjectMap = if (value) |v| switch (v) {
        .object => |o| o,
        else => null,
    } else null;
    if (res.status < 200 or res.status >= 300) {
        if (diagnostics) |d| d.set(res.status, stringField(object, "error") orelse "", stringField(object, "error_description") orelse res.body);
        return error.TokenEndpointRejected;
    }
    const token = stringField(object, "access_token") orelse return error.InvalidTokenResponse;
    const lifetime = (object orelse return error.InvalidTokenResponse).get("expires_in") orelse return error.InvalidTokenResponse;
    _ = switch (lifetime) {
        .integer => |n| n,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch return error.InvalidTokenResponse,
        else => return error.InvalidTokenResponse,
    };
    return token;
}

fn stringField(object: ?std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const o = object orelse return null;
    return switch (o.get(name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

const token_url = "https://login.microsoftonline.com/tenant-1/oauth2/v2.0/token";

test "rest-core: a client secret's token, fetched through the transport and sent by the loop" {
    const script = [_]FakeTransport.Reply{
        .{ .respond = .{ .body = "{\"token_type\":\"Bearer\",\"expires_in\":3599,\"ext_expires_in\":3599,\"access_token\":\"eyJ0.from-entra\"}" } },
        .{ .respond = .{ .status = 401, .body = "{\"error\":{\"code\":\"InvalidAuthenticationToken\",\"message\":\"The access token is invalid.\"}}" } },
        .{ .respond = .{ .body = "{\"token_type\":\"Bearer\",\"expires_in\":\"3599\",\"access_token\":\"eyJ0.again\"}" } },
        .{ .respond = .{} },
    };
    var rig: Rig = .init(&script);
    defer rig.deinit();
    var secret: ClientSecret = .{
        .transport = rig.fake.transport(),
        .token_url = token_url,
        .client_id = "app-1",
        .secret = "s3cr&t/=",
    };
    var engine = rig.engine();
    engine.token_provider = secret.provider();
    var response: std.heap.ArenaAllocator = .init(testing.allocator);
    defer response.deinit();

    _ = try get(engine, &response, vm_path);
    const asked = try rig.fake.request(0);
    try testing.expectEqual(.POST, asked.method);
    try testing.expectEqualStrings(token_url, asked.url);
    try testing.expectEqual(.form, asked.content_type);
    try testing.expectEqual(null, asked.bearer);
    try testing.expectEqualStrings(
        "client_id=app-1&scope=https%3A%2F%2Fmanagement.azure.com%2F.default&client_secret=s3cr%26t%2F%3D&grant_type=client_credentials",
        asked.body.?,
    );
    try testing.expectEqualStrings("eyJ0.from-entra", (try rig.fake.request(1)).bearer.?);
    // The 401 dropped the cached token, so the retry carries a new one.
    try testing.expectEqualStrings("eyJ0.again", (try rig.fake.request(3)).bearer.?);
    try testing.expectEqual(4, rig.fake.requests.items.len);
}

test "rest-core: Entra's refusal is the call's error, explained in Diagnostics by the provider" {
    const script = [_]FakeTransport.Reply{.{ .respond = .{
        .status = 401,
        .body = "{\"error\":\"invalid_client\",\"error_description\":\"AADSTS7000215: Invalid client secret provided.\",\"error_codes\":[7000215],\"trace_id\":\"t-1\",\"correlation_id\":\"c-1\"}",
    } }};
    var rig: Rig = .init(&script);
    defer rig.deinit();
    var secret: ClientSecret = .{
        .transport = rig.fake.transport(),
        .token_url = token_url,
        .client_id = "app-1",
        .secret = "wrong",
        .diagnostics = &rig.diag,
    };
    var engine = rig.engine();
    engine.token_provider = secret.provider();
    var response: std.heap.ArenaAllocator = .init(testing.allocator);
    defer response.deinit();

    try testing.expectError(error.TokenEndpointRejected, get(engine, &response, vm_path));
    try testing.expectEqual(1, rig.fake.requests.items.len);
    try testing.expectEqual(401, rig.diag.http_status);
    try testing.expectEqualStrings("invalid_client", rig.diag.code());
    try testing.expectStringStartsWith(rig.diag.message(), "AADSTS7000215");
}

/// A certificate credential's client assertion: a JWT signed PS256 (RSA-PSS,
/// SHA-256, a 32-byte salt), naming the certificate by its SHA-256
/// thumbprint, as Entra asks.
fn clientAssertion(
    arena: Allocator,
    io: std.Io,
    key: *const rest_core.rsa.PrivateKey,
    cert_der: []const u8,
    audience: []const u8,
    client_id: []const u8,
) ![]const u8 {
    var thumbprint: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(cert_der, &thumbprint, .{});
    var jti: [16]u8 = undefined;
    io.random(&jti);
    const now = std.Io.Clock.real.now(io).toSeconds();

    const header = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{
        .alg = "PS256",
        .typ = "JWT",
        .@"x5t#S256" = try base64Url(arena, &thumbprint),
    }, .{})});
    const payload = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{
        .aud = audience,
        .iss = client_id,
        .sub = client_id,
        .jti = &std.fmt.bytesToHex(jti, .lower),
        .nbf = now,
        .exp = now + 600,
    }, .{})});
    const signing_input = try std.mem.concat(arena, u8, &.{ try base64Url(arena, header), ".", try base64Url(arena, payload) });

    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(signing_input, &digest, .{});
    var salt: [Sha256.digest_length]u8 = undefined;
    io.random(&salt);
    var signature: [rest_core.rsa.max_modulus_bytes]u8 = undefined;
    const signed = try key.signPss(io, .sha256, &digest, &salt, &signature);
    return std.mem.concat(arena, u8, &.{ signing_input, ".", try base64Url(arena, signed) });
}

fn base64Url(arena: Allocator, bytes: []const u8) Allocator.Error![]const u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out = try arena.alloc(u8, encoder.calcSize(bytes.len));
    return encoder.encode(out, bytes);
}

fn base64UrlDecode(arena: Allocator, text: []const u8) ![]u8 {
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const out = try arena.alloc(u8, try decoder.calcSizeForSlice(text));
    try decoder.decode(out, text);
    return out;
}

test "rest-core: a certificate's client assertion, signed PS256 with rest-core's rsa" {
    var clock: rest_core.testing.FakeClock = .{ .now_ns = 1_762_466_400 * std.time.ns_per_s };
    const io = clock.io();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var key = try rest_core.rsa.parsePem(rest_core.rsa.test_key_2048);
    defer key.deinit();

    const jwt = try clientAssertion(a, io, &key, "a certificate's DER", token_url, "app-1");
    var parts = std.mem.splitScalar(u8, jwt, '.');
    const header_b64 = parts.next().?;
    const payload_b64 = parts.next().?;
    const signature_b64 = parts.next().?;
    try testing.expectEqual(null, parts.next());

    const Head = struct { alg: []const u8, typ: []const u8, @"x5t#S256": []const u8 };
    const head = try std.json.parseFromSliceLeaky(Head, a, try base64UrlDecode(a, header_b64), .{});
    try testing.expectEqualStrings("PS256", head.alg);
    try testing.expectEqual(43, head.@"x5t#S256".len);
    const Claims = struct { aud: []const u8, iss: []const u8, sub: []const u8, jti: []const u8, nbf: i64, exp: i64 };
    const claims = try std.json.parseFromSliceLeaky(Claims, a, try base64UrlDecode(a, payload_b64), .{});
    try testing.expectEqualStrings(token_url, claims.aud);
    try testing.expectEqualStrings("app-1", claims.sub);
    try testing.expectEqual(1_762_466_400, claims.nbf);
    try testing.expectEqual(600, claims.exp - claims.nbf);

    // The signature checks out as PSS over SHA-256 with the key's public half.
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(jwt[0 .. header_b64.len + 1 + payload_b64.len], &digest, .{});
    try key.publicKey().verifyPss(.sha256, &digest, try base64UrlDecode(a, signature_b64));
}

/// Managed identity on a VM, from IMDS's token endpoint: a sketch, to show
/// the seam holds one. No retries of its own (IMDS asks for about 97 s of
/// them) and no probe.
const Imds = struct {
    transport: transport.Transport,
    endpoint: []const u8 = "http://169.254.169.254",

    fn provider(self: *Imds) TokenProvider {
        return .{ .ptr = self, .vtable = &.{ .getToken = getToken, .invalidate = invalidate } };
    }

    fn getToken(ptr: *anyopaque, io: std.Io, arena: Allocator, scopes: []const []const u8) TokenProvider.Error![]const u8 {
        _ = io;
        const self: *Imds = @ptrCast(@alignCast(ptr));
        // IMDS takes a resource, not a v2 scope: the scope without `.default`.
        const scope = scopes[0];
        const resource = if (std.mem.endsWith(u8, scope, "/.default")) scope[0 .. scope.len - ".default".len] else scope;
        var url: std.Io.Writer.Allocating = .init(arena);
        writeUrl(&url.writer, self.endpoint, resource) catch return error.OutOfMemory;
        const res = self.transport.send(.{
            .method = .GET,
            .url = url.written(),
            .headers = &.{.{ .name = "Metadata", .value = "true" }},
            .timeout_ms = 2_000,
        }, arena) catch |err| switch (err) {
            // Nothing answers where IMDS would: this is not an Azure VM.
            error.ConnectionRefused,
            error.ConnectionTimedOut,
            error.NetworkUnreachable,
            error.TimedOut,
            => return error.CredentialSourceUnavailable,
            else => |e| return e,
        };
        return readToken(arena, res, null);
    }

    fn writeUrl(w: *std.Io.Writer, endpoint: []const u8, resource: []const u8) std.Io.Writer.Error!void {
        try w.print("{s}/metadata/identity/oauth2/token", .{endpoint});
        var params: rest_core.query.Params = .init(w);
        try params.add("api-version", "2018-02-01");
        try params.add("resource", resource);
    }

    fn invalidate(ptr: *anyopaque) void {
        _ = ptr;
    }
};

test "rest-core: managed identity where no IMDS answers is CredentialSourceUnavailable, and nothing goes to ARM" {
    const script = [_]FakeTransport.Reply{.{ .fail = error.ConnectionRefused }};
    var rig: Rig = .init(&script);
    defer rig.deinit();
    var imds: Imds = .{ .transport = rig.fake.transport() };
    var engine = rig.engine();
    engine.token_provider = imds.provider();
    var response: std.heap.ArenaAllocator = .init(testing.allocator);
    defer response.deinit();

    try testing.expectError(error.CredentialSourceUnavailable, get(engine, &response, vm_path));
    try testing.expectEqual(1, rig.fake.requests.items.len);
    const asked = try rig.fake.request(0);
    try testing.expectEqualStrings(
        "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F",
        asked.url,
    );
    try testing.expectEqualStrings("true", asked.header("Metadata").?);
    try testing.expectEqual(null, asked.bearer);
    try testing.expectEqualStrings("the token provider failed: CredentialSourceUnavailable", rig.diag.message());
}

test "rest-core: managed identity's token, every number in it a string, reaches ARM" {
    const script = [_]FakeTransport.Reply{
        .{ .respond = .{ .body = "{\"access_token\":\"eyJ0.from-imds\",\"refresh_token\":\"\",\"expires_in\":\"3599\",\"expires_on\":\"1762470000\",\"not_before\":\"1762466400\",\"resource\":\"https://management.azure.com/\",\"token_type\":\"Bearer\"}" } },
        .{ .respond = .{} },
    };
    var rig: Rig = .init(&script);
    defer rig.deinit();
    var imds: Imds = .{ .transport = rig.fake.transport() };
    var engine = rig.engine();
    engine.token_provider = imds.provider();
    var response: std.heap.ArenaAllocator = .init(testing.allocator);
    defer response.deinit();

    _ = try get(engine, &response, vm_path);
    try testing.expectEqualStrings("eyJ0.from-imds", (try rig.fake.request(1)).bearer.?);
}

test "rest-core: Shared Key signs in the call's headers, once for every attempt" {
    // Storage's Shared Key signs each request, its method, headers and path
    // and an x-ms-date among them, instead of sending a token. The loop's
    // only place for it is the call's headers: no token provider, and the
    // Authorization the module computed, which the transport takes when it
    // sends no bearer token.
    const script = [_]FakeTransport.Reply{
        .{ .respond = .{ .status = 503, .headers = &.{.{ .name = "x-ms-error-code", .value = "ServerBusy" }}, .body = "" } },
        .{ .respond = .{} },
    };
    var rig: Rig = .init(&script);
    defer rig.deinit();
    var engine = rig.engine();
    engine.base_url = "https://acct.blob.core.windows.net";
    engine.auth_scope = "https://storage.azure.com/.default";
    engine.token_provider = null;
    engine.headers = &.{};
    var response: std.heap.ArenaAllocator = .init(testing.allocator);
    defer response.deinit();
    const date = "Fri, 06 Nov 2026 22:00:00 GMT";
    const authorization = "SharedKey acct:c2lnbmVkIG9uY2U=";

    engine.begin();
    _ = try engine.execute(&response, .{
        .method = .GET,
        .path = "/container-1/blob-1?comp=metadata",
        .headers = &.{
            .{ .name = "x-ms-date", .value = date },
            .{ .name = "x-ms-version", .value = "2026-02-06" },
            .{ .name = "Authorization", .value = authorization },
        },
    });
    // The retry repeats the first attempt's date and signature. Azure takes
    // a request up to 15 minutes old, far past the policy's waits, so it
    // holds; azcore signs each attempt afresh.
    try testing.expectEqual(2, rig.fake.requests.items.len);
    for (rig.fake.requests.items) |r| {
        try testing.expectEqual(null, r.bearer);
        try testing.expectEqualStrings(authorization, r.header("Authorization").?);
        try testing.expectEqualStrings(date, r.header("x-ms-date").?);
    }
}
