//! ClientSecret against FakeEntra: tokens, the cache per scope, refusals,
//! and what is refused before anything is sent.

const std = @import("std");
const testing = std.testing;
const core = @import("core");
const auth = @import("root.zig");
const ClientSecret = auth.ClientSecret;
const FakeEntra = auth.testing.FakeEntra;

const tenant = "00000000-0000-4000-8000-00000000aaaa";
const app = "00000000-0000-4000-8000-00000000a99a";
const arm = "https://management.core.windows.net//.default";
const blob = "https://storage.azure.com/.default";

const Rig = struct {
    fake: FakeEntra,
    clock: auth.testing.FakeClock,
    diag: core.Diagnostics,
    cred: ClientSecret,
    arena: std.heap.ArenaAllocator,

    fn init(rig: *Rig, secret: []const u8) !void {
        rig.fake = .init(testing.allocator);
        errdefer rig.fake.deinit();
        try rig.fake.addApp(tenant, app, "the-secret");
        rig.clock = .{};
        rig.diag = .{};
        rig.arena = .init(testing.allocator);
        rig.cred = try .init(testing.allocator, rig.clock.io(), .{
            .tenant_id = tenant,
            .client_id = app,
            .secret = secret,
            .transport = rig.fake.transport(),
            .diagnostics = &rig.diag,
        });
    }

    fn deinit(rig: *Rig) void {
        rig.cred.deinit();
        rig.arena.deinit();
        rig.fake.deinit();
    }

    fn token(rig: *Rig, scope: []const u8) core.TokenProvider.Error![]const u8 {
        return rig.cred.provider().getToken(rig.clock.io(), rig.arena.allocator(), &.{scope});
    }
};

test "ClientSecret: a token per scope, from one credential, cached and refreshed" {
    var rig: Rig = undefined;
    try rig.init("the-secret");
    defer rig.deinit();
    try testing.expectEqualStrings("fake-entra.1", try rig.token(arm));
    try testing.expectEqualStrings("fake-entra.2", try rig.token(blob));
    try testing.expectEqualStrings("fake-entra.1", try rig.token(arm));
    try testing.expectEqual(2, rig.fake.requests);
    try testing.expectEqualStrings(arm, rig.fake.issued.items[0]);
    try testing.expectEqualStrings(blob, rig.fake.issued.items[1]);
    rig.clock.now_ns += 3300 * std.time.ns_per_s;
    try testing.expectEqualStrings("fake-entra.3", try rig.token(arm));
    // After a 401, as a service's engine says: every token fetched again.
    rig.cred.provider().invalidate();
    try testing.expectEqualStrings("fake-entra.4", try rig.token(blob));
    try testing.expectEqual(0, rig.diag.http_status);
}

test "ClientSecret: Entra's refusals, their codes and ids in Diagnostics" {
    var rig: Rig = undefined;
    try rig.init("not-the-secret");
    defer rig.deinit();
    try testing.expectError(error.TokenEndpointRejected, rig.token(arm));
    try testing.expectEqual(401, rig.diag.http_status);
    try testing.expectEqualStrings("invalid_client", rig.diag.code());
    try testing.expectStringStartsWith(rig.diag.message(), "AADSTS7000215: Invalid client secret provided.");
    try testing.expectEqualStrings("00000000-0000-4000-8000-0000000000e1", rig.diag.requestId());
    try testing.expectEqualStrings("00000000-0000-4000-8000-0000000000c1", rig.diag.correlationId());

    var other: Rig = undefined;
    try other.init("the-secret");
    defer other.deinit();
    other.fake.fail_next = .{ .status = 401, .body = "{\"error\":\"invalid_client\",\"error_description\":\"AADSTS7000222: The provided client secret keys for app '00000000-0000-4000-8000-00000000a99a' are expired.\",\"error_codes\":[7000222]}" };
    try testing.expectError(error.ReauthenticationRequired, other.token(arm));
    // Entra down for a moment: tried again, then a token.
    other.fake.fail_next = .{ .status = 503, .body = "" };
    try testing.expectEqualStrings("fake-entra.1", try other.token(arm));
    try testing.expectEqual(3, other.fake.requests);
}

test "ClientSecret: a long-lived token's refresh_in is honoured" {
    var rig: Rig = undefined;
    try rig.init("the-secret");
    defer rig.deinit();
    rig.fake.expires_in = 86399;
    rig.fake.refresh_in = 43199;
    _ = try rig.token(arm);
    rig.clock.now_ns += 43198 * std.time.ns_per_s;
    _ = try rig.token(arm);
    try testing.expectEqual(1, rig.fake.requests);
    rig.clock.now_ns += 1 * std.time.ns_per_s;
    _ = try rig.token(arm);
    try testing.expectEqual(2, rig.fake.requests);
}

test "ClientSecret: what Entra would refuse is refused before anything is sent" {
    var rig: Rig = undefined;
    try rig.init("the-secret");
    defer rig.deinit();
    const p = rig.cred.provider();
    for ([_][]const []const u8{ &.{}, &.{ arm, blob }, &.{"https://management.azure.com/user_impersonation"}, &.{"a b/.default"} }) |scopes| {
        try testing.expectError(error.TokenUnavailable, p.getToken(rig.clock.io(), rig.arena.allocator(), scopes));
    }
    try testing.expectEqual(0, rig.fake.requests);
    try testing.expectStringStartsWith(rig.diag.message(), "an app asks for one scope at a time");

    var diag: core.Diagnostics = .{};
    var clock: auth.testing.FakeClock = .{};
    for ([_]ClientSecret.Options{
        .{ .tenant_id = "organizations", .client_id = app, .secret = "s", .diagnostics = &diag },
        .{ .tenant_id = "a/b.com", .client_id = app, .secret = "s", .diagnostics = &diag },
        .{ .tenant_id = tenant, .client_id = "my-app", .secret = "s", .diagnostics = &diag },
        .{ .tenant_id = tenant, .client_id = app, .secret = "", .diagnostics = &diag },
        .{ .tenant_id = tenant, .client_id = app, .secret = "s", .authority_host = "http://login.microsoftonline.com/", .diagnostics = &diag },
        .{ .tenant_id = tenant, .client_id = app, .secret = "s", .cache = .{ .refresh_margin_s = 0 }, .diagnostics = &diag },
    }) |options| try testing.expectError(error.InvalidArgument, ClientSecret.init(testing.allocator, clock.io(), options));
}

test "ClientSecret: an unknown tenant or app, as Entra says them" {
    var fake: FakeEntra = .init(testing.allocator);
    defer fake.deinit();
    try fake.addApp(tenant, app, "s");
    var clock: auth.testing.FakeClock = .{};
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Case = struct { tenant: []const u8, client: []const u8, code: []const u8, status: u16 };
    for ([_]Case{
        .{ .tenant = "00000000-0000-4000-8000-0000000000ff", .client = app, .code = "invalid_request", .status = 400 },
        .{ .tenant = tenant, .client = "00000000-0000-4000-8000-0000000000bb", .code = "unauthorized_client", .status = 400 },
    }) |case| {
        var diag: core.Diagnostics = .{};
        var cred: ClientSecret = try .init(testing.allocator, clock.io(), .{ .tenant_id = case.tenant, .client_id = case.client, .secret = "s", .transport = fake.transport(), .diagnostics = &diag });
        defer cred.deinit();
        try testing.expectError(error.TokenEndpointRejected, cred.provider().getToken(clock.io(), arena.allocator(), &.{arm}));
        try testing.expectEqualStrings(case.code, diag.code());
        try testing.expectEqual(case.status, diag.http_status);
    }
}

test "ClientSecret: the secret goes in the form, and every block freed is wiped" {
    var checker: core.testing.WipeChecker = .{ .child = testing.allocator };
    var fake: FakeEntra = .init(testing.allocator);
    defer fake.deinit();
    try fake.addApp(tenant, app, "s3cr3t+/=");
    var clock: auth.testing.FakeClock = .{};
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var cred: ClientSecret = try .init(checker.allocator(), clock.io(), .{ .tenant_id = tenant, .client_id = app, .secret = "s3cr3t+/=", .transport = fake.transport() });
    _ = try cred.provider().getToken(clock.io(), arena.allocator(), &.{arm});
    cred.deinit();
    // The token, the scope, the secret, the token URL, the client id, and
    // the scratch memory of the fetch that held them.
    try testing.expect(checker.frees >= 6);
    try testing.expectEqual(0, checker.unwiped);
}
