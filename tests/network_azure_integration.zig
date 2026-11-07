//! The network module against Azure itself. It needs a subscription and a
//! token for Resource Manager whose principal may make and delete resource
//! groups and networks there (t8's test principal, Contributor):
//!
//!     AZURE_TEST_SUBSCRIPTION=<guid> AZURE_TEST_TOKEN=$(tools/azure-token.sh) \
//!         zig build test-integration-azure -Dtest-filter=network
//!
//! Without both variables every test skips. A run first sweeps the `azzig-`
//! groups crashed runs left, then makes one group of its own,
//! `azzig-network-<run>`, in `AZURE_TEST_LOCATION` (eastus2 when unset),
//! holding a security group, a virtual network and its subnets, and
//! deletes it all. Virtual networks, subnets and security groups cost
//! nothing; a run takes a few minutes, most of it the deletes.
//!
//! Each `fact:` line is something FakeNetwork assumes from Network's
//! documentation: a refusal's status and code, how an operation is
//! followed, what a delete of nothing answers. A run that prints another
//! answer is the fake to change.

const std = @import("std");
const core = @import("core");
const network = @import("network");
const resources = @import("resources");
const sweep = @import("sweep.zig");
const testing = std.testing;

const Fixture = struct {
    env: std.process.Environ.Map,
    token: core.StaticToken,
    diag: core.Diagnostics,
    groups: resources.Client,
    client: network.Client,
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
        f.groups = try .init(gpa, testing.io, .{
            .token_provider = f.token.provider(),
            .diagnostics = &f.diag,
            .user_agent = "azure-zig-network-integration/0.1",
        });
        errdefer f.groups.deinit();
        f.client = try .init(gpa, testing.io, .{
            .token_provider = f.token.provider(),
            .diagnostics = &f.diag,
            .user_agent = "azure-zig-network-integration/0.1",
        });
        return true;
    }

    fn skip(f: *Fixture) bool {
        f.env.deinit();
        return false;
    }

    fn deinit(f: *Fixture) void {
        f.client.deinit();
        f.groups.deinit();
        f.env.deinit();
    }

    /// Says what failed, as Diagnostics has it, then passes the error on.
    fn explain(f: *Fixture, err: anyerror) anyerror {
        std.debug.print("  failed: {t}: {f}\n", .{ err, f.diag });
        return err;
    }

    /// Waits on a write to its end, which must be success, saying how it
    /// was followed.
    fn settle(f: *Fixture, comptime what: []const u8, begun: anyerror!network.Owned(network.Operation)) !void {
        var op = begun catch |err| return f.explain(err);
        defer op.deinit();
        fact(what ++ ": followed by {t}, first wait {d} ms", .{ op.value.follow, op.value.delay_ms });
        f.client.waitOperation(&op, 10 * 60 * 1000) catch |err| return f.explain(err);
        if (op.value.state != .succeeded) {
            std.debug.print("  " ++ what ++ " ended {t}: {s}: {s}\n", .{ op.value.state, op.value.failure_code, op.value.failure_message });
            return error.OperationNotSucceeded;
        }
    }

    /// A refusal expected, its status and code printed as found.
    fn refused(f: *Fixture, comptime what: []const u8, begun: anyerror!network.Owned(network.Operation)) !void {
        if (begun) |op| {
            var o = op;
            o.deinit();
            std.debug.print("  " ++ what ++ ": not refused\n", .{});
            return error.NotRefused;
        } else |err| fact(what ++ ": {t}, {d} {s}", .{ err, f.diag.http_status, f.diag.code() });
    }
};

fn fact(comptime format: []const u8, args: anytype) void {
    std.debug.print("  fact: " ++ format ++ "\n", args);
}

fn nowSeconds() i64 {
    return std.Io.Clock.real.now(testing.io).toSeconds();
}

test "network: a private subnet for spot workers, its security group, what Network refuses, and the deletes" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const gpa = testing.allocator;
    _ = sweep.sweep(&f.groups, f.subscription, nowSeconds()) catch |err| return f.explain(err);

    const run = sweep.runId(testing.io);
    var name_buf: [64]u8 = undefined;
    const rg = try std.fmt.bufPrint(&name_buf, "azzig-network-{s}", .{&run});
    var created_buf: [20]u8 = undefined;
    const tags = [_]network.Tag{
        .{ .name = sweep.run_tag, .value = &run },
        .{ .name = sweep.created_tag, .value = try std.fmt.bufPrint(&created_buf, "{d}", .{nowSeconds()}) },
    };
    var made = f.groups.createResourceGroup(f.subscription, rg, .{ .location = f.location, .tags = &tags }) catch |err| return f.explain(err);
    made.deinit();
    // From here on the group exists: delete it however the test ends.
    defer if (f.groups.beginDeleteResourceGroup(f.subscription, rg, .{})) |op| {
        var o = op;
        o.deinit();
    } else |_| {};

    const sub = f.subscription;
    const nsg_id = try network.ids.securityGroup(gpa, sub, rg, "pb-nsg");
    defer gpa.free(nsg_id);
    try f.settle("security group create", f.client.beginCreateSecurityGroup(sub, rg, "pb-nsg", .{ .location = f.location, .tags = &tags, .rules = &.{.{
        .name = "AllowSsh",
        .priority = 100,
        .direction = .inbound,
        .access = .allow,
        .protocol = .tcp,
        .source_address_prefixes = &.{ "203.0.113.0/24", "198.51.100.7" },
        .destination_port_ranges = &.{"22"},
    }} }));

    const spec: network.VirtualNetworkSpec = .{
        .location = f.location,
        .address_prefixes = &.{"10.20.0.0/16"},
        .subnets = &.{.{ .name = "workers", .spec = .{
            .address_prefix = "10.20.1.0/24",
            .service_endpoints = &.{"Microsoft.Storage"},
            .security_group = nsg_id,
        } }},
        .tags = &tags,
    };
    try f.settle("network create", f.client.beginCreateVirtualNetwork(sub, rg, "pb-vnet", spec));
    try f.settle("network made again", f.client.beginCreateVirtualNetwork(sub, rg, "pb-vnet", spec));

    var vnet = f.client.getVirtualNetwork(sub, rg, "pb-vnet") catch |err| return f.explain(err);
    defer vnet.deinit();
    try testing.expectEqualStrings("Succeeded", vnet.value.provisioning_state);
    try testing.expectEqualStrings(&run, vnet.value.tag(sweep.run_tag).?);
    const workers = vnet.value.subnet("workers") orelse return error.SubnetMissing;
    try testing.expectEqual(false, workers.default_outbound_access orelse return error.DefaultOutboundUnsaid);
    try testing.expect(workers.hasEndpoint("Microsoft.Storage"));
    try testing.expect(std.ascii.eqlIgnoreCase(nsg_id, workers.security_group.?));
    fact("the Storage endpoint reaches {d} region(s), the first {s}", .{ workers.service_endpoints[0].locations.len, if (workers.service_endpoints[0].locations.len > 0) workers.service_endpoints[0].locations[0] else "-" });

    var nsg = f.client.getSecurityGroup(sub, rg, "pb-nsg") catch |err| return f.explain(err);
    defer nsg.deinit();
    const ssh = nsg.value.rule("AllowSsh") orelse return error.RuleMissing;
    try testing.expectEqual(2, ssh.source_address_prefixes.len);
    try testing.expectEqual(.tcp, ssh.protocol);
    fact("{d} default rules; the group applies to {d} subnet(s)", .{ nsg.value.default_rules.len, nsg.value.subnets.len });

    // A subnet on its own, then what Network refuses.
    try f.settle("subnet create", f.client.beginCreateSubnet(sub, rg, "pb-vnet", "extra", .{ .address_prefix = "10.20.2.0/24" }));
    try f.refused("an overlapping subnet", f.client.beginCreateSubnet(sub, rg, "pb-vnet", "over", .{ .address_prefix = "10.20.2.128/25" }));
    try f.refused("a subnet outside the network", f.client.beginCreateSubnet(sub, rg, "pb-vnet", "far", .{ .address_prefix = "10.30.0.0/24" }));
    try f.refused("a security group in use, deleted", f.client.beginDeleteSecurityGroup(sub, rg, "pb-nsg"));
    const missing_id = try network.ids.securityGroup(gpa, sub, rg, "none");
    defer gpa.free(missing_id);
    try f.refused("a subnet naming a security group not there", f.client.beginCreateSubnet(sub, rg, "pb-vnet", "dangling", .{ .address_prefix = "10.20.3.0/24", .security_group = missing_id }));
    try f.refused("a network made again in another location", f.client.beginCreateVirtualNetwork(sub, rg, "pb-vnet", .{ .location = if (std.mem.eql(u8, f.location, "westus2")) "eastus2" else "westus2", .address_prefixes = &.{"10.20.0.0/16"} }));
    try f.refused("a subnet of a network not there", f.client.beginCreateSubnet(sub, rg, "no-vnet", "workers", .{ .address_prefix = "10.20.1.0/24" }));

    // Deletes of nothing: done at once, but a subnet of a network not there.
    try f.settle("a delete of a network not there", f.client.beginDeleteVirtualNetwork(sub, rg, "no-vnet"));
    try f.settle("a delete of a subnet not there", f.client.beginDeleteSubnet(sub, rg, "pb-vnet", "none"));
    try f.refused("a delete of a subnet of a network not there", f.client.beginDeleteSubnet(sub, rg, "no-vnet", "workers"));

    // The deletes, and nothing left after them.
    try f.settle("subnet delete", f.client.beginDeleteSubnet(sub, rg, "pb-vnet", "extra"));
    try testing.expectError(error.NotFound, f.client.getSubnet(sub, rg, "pb-vnet", "extra"));
    fact("a subnet not there: {s}", .{f.diag.code()});
    try f.settle("network delete", f.client.beginDeleteVirtualNetwork(sub, rg, "pb-vnet"));
    try testing.expectError(error.NotFound, f.client.getVirtualNetwork(sub, rg, "pb-vnet"));
    fact("a network not there: {s}", .{f.diag.code()});
    try f.settle("security group delete", f.client.beginDeleteSecurityGroup(sub, rg, "pb-nsg"));
    try testing.expectError(error.NotFound, f.client.getSecurityGroup(sub, rg, "pb-nsg"));
}
