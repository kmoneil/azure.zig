//! Code the documentation shows, compiled and run with the unit tests so
//! that it cannot drift from the library. tools/check_docs.py holds each
//! block marked `<!-- snippet: tests/docs_examples.zig#name -->` to the
//! lines between `// snippet: name` and `// end snippet` here. (gcp.zig's
//! pattern, at eae944c.)

const std = @import("std");
const resources = @import("resources");
const network = @import("network");
const prices = @import("prices");

test "docs/resources: a client over FakeResources, and a list by tag" {
    const gpa = std.testing.allocator;
    // snippet: fake-resources
    var fake: resources.testing.FakeResources = .init(gpa);
    defer fake.deinit();
    try fake.addSubscription("0f9e8d7c-6b5a-4c3d-8e2f-1a0b9c8d7e6f", "test");
    var clock: resources.testing.FakeClock = .{};
    var token: resources.StaticToken = .{ .token = "t" };
    var client: resources.Client = try .init(gpa, clock.io(), .{
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    // end snippet

    const sub = "0f9e8d7c-6b5a-4c3d-8e2f-1a0b9c8d7e6f";
    const run = "1a2b3c4d";
    var made = try client.createResourceGroup(sub, "azzig-docs-1a2b3c4d", .{ .location = "eastus2", .tags = &.{.{ .name = "azzig-run", .value = run }} });
    made.deinit();
    // snippet: list-by-tag
    var mine = try client.listResourceGroups(sub, .{ .name = "azzig-run", .value = run });
    defer mine.deinit();
    // end snippet
    try std.testing.expectEqual(1, mine.value.len);
}

test "docs/network: a client over FakeNetwork, and a subnet behind a security group" {
    const gpa = std.testing.allocator;
    // snippet: fake-network
    var fake: network.testing.FakeNetwork = .init(gpa);
    defer fake.deinit();
    try fake.addGroup("0f9e8d7c-6b5a-4c3d-8e2f-1a0b9c8d7e6f", "rg");
    var clock: network.testing.FakeClock = .{};
    var token: network.StaticToken = .{ .token = "t" };
    var client: network.Client = try .init(gpa, clock.io(), .{
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    // end snippet

    const sub = "0f9e8d7c-6b5a-4c3d-8e2f-1a0b9c8d7e6f";
    // snippet: security-group
    var nsg_op = try client.beginCreateSecurityGroup(sub, "rg", "pb-nsg", .{
        .location = "eastus2",
        .rules = &.{.{
            .name = "AllowSsh",
            .priority = 100,
            .direction = .inbound,
            .access = .allow,
            .protocol = .tcp,
            .source_address_prefixes = &.{"203.0.113.0/24"},
            .destination_port_ranges = &.{"22"},
        }},
    });
    defer nsg_op.deinit();
    try client.waitOperation(&nsg_op, 60_000);

    const nsg_id = try network.ids.securityGroup(gpa, sub, "rg", "pb-nsg");
    defer gpa.free(nsg_id);
    var vnet_op = try client.beginCreateVirtualNetwork(sub, "rg", "pb-vnet", .{
        .location = "eastus2",
        .address_prefixes = &.{"10.20.0.0/16"},
        .subnets = &.{.{ .name = "workers", .spec = .{
            .address_prefix = "10.20.1.0/24",
            .service_endpoints = &.{"Microsoft.Storage"},
            .security_group = nsg_id,
        } }},
    });
    defer vnet_op.deinit();
    try client.waitOperation(&vnet_op, 60_000);
    // end snippet
    try std.testing.expectEqual(.succeeded, vnet_op.value.state);
    var subnet = try client.getSubnet(sub, "rg", "pb-vnet", "workers");
    defer subnet.deinit();
    try std.testing.expectEqualStrings(nsg_id, subnet.value.security_group.?);
}

test "docs/prices: a client over FakePrices" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // snippet: fake-prices
    var fake: prices.testing.FakePrices = .init(gpa);
    defer fake.deinit();
    try fake.addSize("eastus2", "Standard_D2as_v5", "Dasv5", "0.015919", "0.086");
    var client: prices.Client = try .init(gpa, io, .{ .transport = fake.transport() });
    defer client.deinit();
    // end snippet

    var spot = try client.list(.{ .sku = "Standard_D2as_v5" });
    defer spot.deinit();
    try std.testing.expectEqual(1, spot.value.prices.len);
}
