//! Code the documentation shows, compiled and run with the unit tests so
//! that it cannot drift from the library. tools/check_docs.py holds each
//! block marked `<!-- snippet: tests/docs_examples.zig#name -->` to the
//! lines between `// snippet: name` and `// end snippet` here. (gcp.zig's
//! pattern, at eae944c.)

const std = @import("std");
const resources = @import("resources");
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
