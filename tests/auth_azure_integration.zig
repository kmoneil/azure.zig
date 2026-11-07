//! The auth module against Entra ID itself: the test principal's client
//! secret (kb/azure-resources), and the Azure CLI's login on this machine.
//!
//!     AZURE_TEST_KEY_FILE=~/.azure-keys/azzig-test.json AZURE_TEST_CLI=1 \
//!         zig build test-integration-azure -Dtest-filter=auth
//!
//! The key file is as `az ad sp create-for-rbac` writes it (`appId`,
//! `password`, `tenant`); the secret is read into memory that is wiped,
//! and never printed. Each test skips without its variable. Tokens cost
//! nothing; a run takes seconds.

const std = @import("std");
const auth = @import("auth");
const resources = @import("resources");
const testing = std.testing;

const arm = "https://management.core.windows.net//.default";
const blob = "https://storage.azure.com/.default";

fn fact(comptime format: []const u8, args: anytype) void {
    std.debug.print("  fact: " ++ format ++ "\n", args);
}

/// The key file's three fields, in memory the caller wipes.
const Key = struct {
    app: []const u8,
    secret: []const u8,
    tenant: []const u8,
};

fn readKey(arena: std.mem.Allocator, path: []const u8) !Key {
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(64 * 1024));
    const Wire = struct { appId: []const u8, password: []const u8, tenant: []const u8 };
    const w = try std.json.parseFromSliceLeaky(Wire, arena, text, .{ .ignore_unknown_fields = true });
    return .{ .app = w.appId, .secret = w.password, .tenant = w.tenant };
}

/// Lists the subscriptions `provider` can see, and says how many.
fn subscriptions(provider: auth.TokenProvider, diag: *auth.Diagnostics) !usize {
    var client: resources.Client = try .init(testing.allocator, testing.io, .{ .token_provider = provider, .diagnostics = diag, .user_agent = "azure-zig-auth-integration/0.1" });
    defer client.deinit();
    var list = client.listSubscriptions() catch |err| {
        std.debug.print("  failed: {t}: {f}\n", .{ err, diag.* });
        return err;
    };
    defer list.deinit();
    return list.value.len;
}

test "auth: a client secret's tokens for Resource Manager and Storage, then the subscriptions they see" {
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    const path = env.get("AZURE_TEST_KEY_FILE") orelse return error.SkipZigTest;
    // The key file holds the secret: read into memory wiped when freed.
    var wiping: auth.WipingAllocator = .init(testing.allocator);
    var key_arena: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer key_arena.deinit();
    const key = try readKey(key_arena.allocator(), path);

    var diag: auth.Diagnostics = .{};
    var cred: auth.ClientSecret = try .init(testing.allocator, testing.io, .{
        .tenant_id = key.tenant,
        .client_id = key.app,
        .secret = key.secret,
        .diagnostics = &diag,
        .user_agent = "azure-zig-auth-integration/0.1",
    });
    defer cred.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = cred.provider();
    const for_arm = p.getToken(testing.io, arena.allocator(), &.{arm}) catch |err| {
        std.debug.print("  failed: {t}: {f}\n", .{ err, diag });
        return err;
    };
    const for_blob = try p.getToken(testing.io, arena.allocator(), &.{blob});
    try testing.expect(!std.mem.eql(u8, for_arm, for_blob));
    // Cached: the same token again, with no request.
    try testing.expectEqualStrings(for_arm, try p.getToken(testing.io, arena.allocator(), &.{arm}));
    fact("tokens of {d} and {d} bytes for Resource Manager and Storage", .{ for_arm.len, for_blob.len });
    const n = try subscriptions(p, &diag);
    try testing.expect(n >= 1);
    fact("{d} subscription(s) visible to the test principal", .{n});

    // The same app with a wrong secret: refused as m0 recorded it.
    var bad_diag: auth.Diagnostics = .{};
    var bad: auth.ClientSecret = try .init(testing.allocator, testing.io, .{
        .tenant_id = key.tenant,
        .client_id = key.app,
        .secret = "not-the-secret",
        .diagnostics = &bad_diag,
    });
    defer bad.deinit();
    try testing.expectError(error.TokenEndpointRejected, bad.provider().getToken(testing.io, arena.allocator(), &.{arm}));
    try testing.expectEqualStrings("invalid_client", bad_diag.code());
    try testing.expectStringStartsWith(bad_diag.message(), "AADSTS7000215:");
    try testing.expect(bad_diag.correlationId().len > 0);
    fact("a wrong secret: {d} {s}, {s}", .{ bad_diag.http_status, bad_diag.code(), bad_diag.message()[0.."AADSTS7000215".len] });
}

test "auth: the Azure CLI's login, through the real az" {
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    if (env.get("AZURE_TEST_CLI") == null) return error.SkipZigTest;
    var diag: auth.Diagnostics = .{};
    var cli: auth.AzureCli = try .init(testing.allocator, .{ .diagnostics = &diag });
    defer cli.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const token = cli.provider().getToken(testing.io, arena.allocator(), &.{arm}) catch |err| {
        std.debug.print("  failed: {t}: {f}\n", .{ err, diag });
        return err;
    };
    try testing.expect(auth.TokenProvider.isValidToken(token));
    const n = try subscriptions(cli.provider(), &diag);
    try testing.expect(n >= 1);
    fact("the CLI's login sees {d} subscription(s)", .{n});
    // A resource that is not there: az's refusal, its first ERROR line.
    try testing.expectError(error.TokenEndpointRejected, cli.provider().getToken(testing.io, arena.allocator(), &.{"https://nothing.azzig.invalid/.default"}));
    fact("an unknown resource through az: {s}", .{diag.message()[0..@min(diag.message().len, "AADSTS500011".len)]});
}
