//! The resources module against Azure itself. It needs a subscription and
//! a token for Resource Manager whose principal may make and delete
//! resource groups there (t8's test principal):
//!
//!     AZURE_TEST_SUBSCRIPTION=<guid> AZURE_TEST_TOKEN=$(tools/azure-token.sh) \
//!         zig build test-integration-azure -Dtest-filter=resources
//!
//! Without both variables every test skips. A run first sweeps the `azzig-`
//! groups crashed runs left, then makes one group of its own,
//! `azzig-resources-<run>`, in `AZURE_TEST_LOCATION` (eastus2 when unset),
//! and deletes it. Resource groups cost nothing; a run takes a minute or
//! two, most of it the delete.

const std = @import("std");
const core = @import("core");
const resources = @import("resources");
const sweep = @import("sweep.zig");
const testing = std.testing;

const Fixture = struct {
    env: std.process.Environ.Map,
    token: core.StaticToken,
    diag: resources.Diagnostics,
    client: resources.Client,
    subscription: []const u8,
    location: []const u8,

    fn init(f: *Fixture) !bool {
        const gpa = testing.allocator;
        f.env = try testing.environ.createMap(gpa);
        errdefer f.env.deinit();
        f.subscription = f.env.get("AZURE_TEST_SUBSCRIPTION") orelse return f.skip();
        const token = f.env.get("AZURE_TEST_TOKEN") orelse return f.skip();
        f.location = f.env.get("AZURE_TEST_LOCATION") orelse "eastus2";
        f.token = .{ .token = std.mem.trim(u8, token, &std.ascii.whitespace) };
        f.diag = .{};
        f.client = try .init(gpa, testing.io, .{
            .token_provider = f.token.provider(),
            .diagnostics = &f.diag,
            .user_agent = "azure-zig-resources-integration/0.1",
        });
        return true;
    }

    fn skip(f: *Fixture) bool {
        f.env.deinit();
        return false;
    }

    fn deinit(f: *Fixture) void {
        f.client.deinit();
        f.env.deinit();
    }

    /// Says what failed, as Diagnostics has it, then passes the error on.
    fn explain(f: *Fixture, err: anyerror) anyerror {
        std.debug.print("  failed: {t}: {f}\n", .{ err, f.diag });
        return err;
    }
};

fn fact(comptime format: []const u8, args: anytype) void {
    std.debug.print("  fact: " ++ format ++ "\n", args);
}

fn nowSeconds() i64 {
    return std.Io.Clock.real.now(testing.io).toSeconds();
}

test "resources: the sweep deletes the groups crashed runs left, over a day old" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const begun = sweep.sweep(&f.client, f.subscription, nowSeconds()) catch |err| return f.explain(err);
    fact("{d} leftover group(s) being deleted", .{begun});
}

test "resources: the subscription is listed, and the providers azure.zig needs are registered" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    var subs = f.client.listSubscriptions() catch |err| return f.explain(err);
    defer subs.deinit();
    const mine = for (subs.value) |s| {
        if (std.ascii.eqlIgnoreCase(s.id, f.subscription)) break s;
    } else return error.TestSubscriptionNotListed;
    fact("{d} subscription(s) visible; this one {t}", .{ subs.value.len, mine.state });
    try testing.expectEqual(.enabled, mine.state);
    for ([_][]const u8{ "Microsoft.Compute", "Microsoft.Network", "Microsoft.Storage", "Microsoft.ManagedIdentity" }) |ns| {
        var p = f.client.getProvider(f.subscription, ns) catch |err| return f.explain(err);
        defer p.deinit();
        fact("{s}: {t}", .{ ns, p.value.registration_state });
        try testing.expectEqual(.registered, p.value.registration_state);
    }
}

test "resources: a group made, made again, read, found by its tag, and deleted" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const run = sweep.runId(testing.io);
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "azzig-resources-{s}", .{&run});
    var created_buf: [20]u8 = undefined;
    const tags = [_]resources.Tag{
        .{ .name = sweep.run_tag, .value = &run },
        .{ .name = sweep.created_tag, .value = try std.fmt.bufPrint(&created_buf, "{d}", .{nowSeconds()}) },
    };
    const spec: resources.GroupSpec = .{ .location = f.location, .tags = &tags };

    var made = f.client.createResourceGroup(f.subscription, name, spec) catch |err| return f.explain(err);
    defer made.deinit();
    // From here on the group exists: delete it however the test ends.
    defer if (f.client.beginDeleteResourceGroup(f.subscription, name, .{})) |op| {
        var o = op;
        o.deinit();
    } else |_| {};
    try testing.expect(made.value.created);
    try testing.expectEqualStrings(name, made.value.group.name);
    try testing.expectEqualStrings(&run, made.value.group.tag(sweep.run_tag).?);

    var again = f.client.createResourceGroup(f.subscription, name, spec) catch |err| return f.explain(err);
    defer again.deinit();
    try testing.expect(!again.value.created);

    var got = f.client.getResourceGroup(f.subscription, name) catch |err| return f.explain(err);
    defer got.deinit();
    try testing.expectEqualStrings(f.location, got.value.location);
    fact("provisioningState {s}", .{got.value.provisioning_state});

    var found = f.client.listResourceGroups(f.subscription, .{ .name = sweep.run_tag, .value = &run }) catch |err| return f.explain(err);
    defer found.deinit();
    try testing.expectEqual(1, found.value.len);

    var op = f.client.beginDeleteResourceGroup(f.subscription, name, .{}) catch |err| return f.explain(err);
    defer op.deinit();
    fact("delete followed by {t}, first wait {d} ms", .{ op.value.follow, op.value.delay_ms });
    f.client.waitOperation(&op, 15 * 60 * 1000) catch |err| return f.explain(err);
    try testing.expectEqual(.succeeded, op.value.state);
    try testing.expectError(error.NotFound, f.client.getResourceGroup(f.subscription, name));
}
