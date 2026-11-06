//! The prices client against FakePrices, and against a scripted transport
//! where a row the filter should have left out, or the request's exact
//! shape, is the point.

const std = @import("std");
const testing = std.testing;
const core = @import("core");
const Client = @import("Client.zig");
const Amount = @import("Amount.zig");
const FakePrices = @import("fake_prices.zig").FakePrices;

const sku = "Standard_D2as_v5";

const Rig = struct {
    fake: FakePrices,
    clock: core.testing.FakeClock = .{},
    diag: core.Diagnostics = .{},
    client: Client = undefined,

    fn init(rig: *Rig, currency: ?[]const u8) !void {
        rig.* = .{ .fake = .init(testing.allocator) };
        rig.client = try .init(testing.allocator, rig.clock.io(), .{
            .transport = rig.fake.transport(),
            .diagnostics = &rig.diag,
            .currency = currency,
        });
    }

    fn deinit(rig: *Rig) void {
        rig.client.deinit();
        rig.fake.deinit();
    }
};

fn nanos(text: []const u8) u128 {
    return Amount.parse(text).?.toNanos();
}

test "list: one Linux spot price per region, every other row left out" {
    var rig: Rig = undefined;
    try rig.init(null);
    defer rig.deinit();
    try rig.fake.addSize("eastus2", sku, "Dasv5", "0.015919", "0.086");
    try rig.fake.addSize("westus3", sku, "Dasv5", "0.015893", "0.086");
    try rig.fake.addSize("centralindia", sku, "Dasv5", "0.010275", "0.0821");
    try rig.fake.addSize("eastus2", "Standard_D4as_v5", "Dasv5", "0.031838", "0.172");

    var got = try rig.client.list(.{ .sku = sku });
    defer got.deinit();
    try testing.expectEqual(3, got.value.prices.len);
    try testing.expectEqual(0, got.value.skipped);
    for (got.value.prices) |p| {
        try testing.expectEqual(.spot, p.pricing);
        try testing.expectEqualStrings(sku, p.sku);
        try testing.expectEqualStrings("USD", p.currency);
        try testing.expectEqualStrings("Virtual Machines Dasv5 Series", p.product_name);
    }
    try testing.expectEqualStrings("eastus2", got.value.prices[0].region);
    try testing.expectEqual(nanos("0.015919"), got.value.prices[0].per_hour.toNanos());
}

test "list: on demand leaves out spot and the legacy Low Priority meters" {
    var rig: Rig = undefined;
    try rig.init(null);
    defer rig.deinit();
    try rig.fake.addSize("eastus2", sku, "Dasv5", "0.015919", "0.086");

    var got = try rig.client.list(.{ .pricing = .on_demand, .region = "eastus2" });
    defer got.deinit();
    try testing.expectEqual(1, got.value.prices.len);
    try testing.expectEqual(.on_demand, got.value.prices[0].pricing);
    try testing.expectEqual(nanos("0.086"), got.value.prices[0].per_hour.toNanos());
}

test "list: every page read, through links that write the default port as production's do" {
    var rig: Rig = undefined;
    try rig.init(null);
    defer rig.deinit();
    rig.fake.page_size = 2;
    for ([_][]const u8{ "eastus", "eastus2", "westus2", "westus3", "northcentralus" }) |r| try rig.fake.addSize(r, sku, "Dasv5", "0.02", "0.086");

    var got = try rig.client.list(.{ .sku = sku });
    defer got.deinit();
    try testing.expectEqual(5, got.value.prices.len);
    try testing.expectEqual(3, got.value.pages);
    try testing.expectEqual(3, rig.fake.requests);
}

test "cheapest: the lowest price of those asked for" {
    var rig: Rig = undefined;
    try rig.init(null);
    defer rig.deinit();
    try rig.fake.addSize("eastus2", sku, "Dasv5", "0.015919", "0.086");
    try rig.fake.addSize("centralindia", sku, "Dasv5", "0.010275", "0.0821");
    try rig.fake.addSize("westus3", sku, "Dasv5", "0.015893", "0.086");

    var best = (try rig.client.cheapest(.{ .sku = sku })).?;
    defer best.deinit();
    try testing.expectEqualStrings("centralindia", best.value.region);
    try testing.expectEqual(null, try rig.client.cheapest(.{ .sku = "Standard_D96as_v5" }));
}

test "a currency is asked as currencyCode='EUR', and the prices say so" {
    var rig: Rig = undefined;
    try rig.init("EUR");
    defer rig.deinit();
    try rig.fake.addSize("eastus2", sku, "Dasv5", "0.014291", "0.0779");

    var got = try rig.client.list(.{ .sku = sku, .region = "eastus2" });
    defer got.deinit();
    try testing.expectEqualStrings("EUR", got.value.prices[0].currency);
}

/// A client over a scripted transport, for what the filter cannot show.
const Scripted = struct {
    fake: core.testing.FakeTransport,
    clock: core.testing.FakeClock = .{},
    diag: core.Diagnostics = .{},
    client: Client = undefined,

    fn init(s: *Scripted, script: []const core.testing.FakeTransport.Reply, currency: ?[]const u8) !void {
        s.* = .{ .fake = .init(testing.allocator, script) };
        s.client = try .init(testing.allocator, s.clock.io(), .{
            .transport = s.fake.transport(),
            .diagnostics = &s.diag,
            .currency = currency,
        });
    }

    fn deinit(s: *Scripted) void {
        s.client.deinit();
        s.fake.deinit();
    }
};

fn row(comptime sku_name: []const u8, comptime product: []const u8, comptime kind: []const u8, comptime price: []const u8) []const u8 {
    return "{\"currencyCode\":\"USD\",\"retailPrice\":" ++ price ++ ",\"armRegionName\":\"eastus2\",\"armSkuName\":\"Standard_D2as_v5\",\"skuName\":\"" ++ sku_name ++
        "\",\"productName\":\"" ++ product ++ "\",\"type\":\"" ++ kind ++ "\",\"unitOfMeasure\":\"1 Hour\",\"effectiveStartDate\":\"2026-09-01T00:00:00Z\",\"meterId\":\"m\"}";
}

test "a row the filter should have left out is left out again, and counted" {
    const body = comptime "{\"Items\":[" ++
        row("Standard_D2as_v5 Spot", "Virtual Machines Dasv5 Series", "Consumption", "0.015919") ++ "," ++
        row("Standard_D2as_v5 Spot", "Virtual Machines Dasv5 Series Windows", "Consumption", "0.032948") ++ "," ++
        row("Standard_D2as_v5 Spot", "Virtual Machines Dasv5 Series", "DevTestConsumption", "0.015919") ++ "," ++
        row("Standard_D2as_v5 Low Priority", "Virtual Machines Dasv5 Series", "Consumption", "0.0172") ++ "," ++
        row("Standard_D2as_v5 Spot", "Dasv5 Series Cloud Services", "Consumption", "0.0712") ++ "," ++
        row("Standard_D2as_v5", "Virtual Machines Dasv5 Series", "Consumption", "0.086") ++
        "],\"NextPageLink\":null}";
    const script = [_]core.testing.FakeTransport.Reply{.{ .respond = .{ .body = body } }};
    var s: Scripted = undefined;
    try s.init(&script, null);
    defer s.deinit();

    var got = try s.client.list(.{ .sku = sku });
    defer got.deinit();
    try testing.expectEqual(1, got.value.prices.len);
    try testing.expectEqual(nanos("0.015919"), got.value.prices[0].per_hour.toNanos());
    try testing.expectEqual(5, got.value.skipped);
}

test "the request: the measured filter, encoded, no credentials, the currency in quotes" {
    const script = [_]core.testing.FakeTransport.Reply{.{ .respond = .{ .body = "{\"Items\":[],\"NextPageLink\":null}" } }};
    var s: Scripted = undefined;
    try s.init(&script, "EUR");
    defer s.deinit();

    var got = try s.client.list(.{ .sku = sku, .region = "eastus2" });
    defer got.deinit();
    const sent = try s.fake.request(0);
    try testing.expectEqual(null, sent.bearer);
    try testing.expectStringStartsWith(sent.url, "https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&currencyCode=%27EUR%27&%24filter=");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(
        "serviceName eq 'Virtual Machines' and priceType eq 'Consumption' and startswith(productName,'Virtual Machines') and endswith(productName,' Windows') eq false and endswith(skuName,' Spot') and armRegionName eq 'eastus2' and armSkuName eq 'Standard_D2as_v5'",
        try Client.filter(arena.allocator(), .{ .sku = sku, .region = "eastus2" }),
    );
}

test "a refusal reads the API's capitalized error body" {
    const script = [_]core.testing.FakeTransport.Reply{.{ .respond = .{
        .status = 400,
        .body = "{\"Error\":{\"Code\":\"BadRequest\",\"Message\":\"Invalid OData parameters supplied\"}}",
    } }};
    var s: Scripted = undefined;
    try s.init(&script, null);
    defer s.deinit();

    try testing.expectError(error.BadRequest, s.client.list(.{}));
    try testing.expectEqualStrings("BadRequest", s.diag.code());
    try testing.expectEqualStrings("Invalid OData parameters supplied", s.diag.message());
}

test "a price finer than a billionth is refused, not rounded" {
    const body = comptime "{\"Items\":[" ++ row("Standard_D2as_v5 Spot", "Virtual Machines Dasv5 Series", "Consumption", "1e-12") ++ "]}";
    const script = [_]core.testing.FakeTransport.Reply{.{ .respond = .{ .body = body } }};
    var s: Scripted = undefined;
    try s.init(&script, null);
    defer s.deinit();
    try testing.expectError(error.InvalidResponse, s.client.list(.{}));
    try testing.expectStringStartsWith(s.diag.message(), "a page of prices is not the JSON");
}

test "a NextPageLink off the API's origin is refused" {
    const script = [_]core.testing.FakeTransport.Reply{.{ .respond = .{ .body = "{\"Items\":[],\"NextPageLink\":\"https://evil.example:443/api/retail/prices?$skip=1000\"}" } }};
    var s: Scripted = undefined;
    try s.init(&script, null);
    defer s.deinit();
    try testing.expectError(error.InvalidEndpoint, s.client.list(.{}));
    try testing.expectEqual(1, s.fake.requests.items.len);
}

test "a region, size or currency the API would not match is refused before sending" {
    const script = [_]core.testing.FakeTransport.Reply{};
    var s: Scripted = undefined;
    try s.init(&script, null);
    defer s.deinit();
    try testing.expectError(error.InvalidArgument, s.client.list(.{ .region = "EastUS2" }));
    try testing.expectStringStartsWith(s.diag.message(), "a region is lowercase");
    try testing.expectError(error.InvalidArgument, s.client.list(.{ .sku = "Standard_D2as_v5' or 1 eq 1" }));
    try testing.expectEqual(0, s.fake.requests.items.len);

    var e: Scripted = undefined;
    try e.init(&script, "eur");
    defer e.deinit();
    try testing.expectError(error.InvalidArgument, e.client.list(.{}));
}

/// Production's rows, as FakePrices holds rows: every number kept as text.
fn addProductionRows(fake: *FakePrices, body: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{ .parse_numbers = false });
    for (value.object.get("Items").?.array.items) |item| {
        const o = item.object;
        try fake.addRow(.{
            .armRegionName = o.get("armRegionName").?.string,
            .armSkuName = o.get("armSkuName").?.string,
            .skuName = o.get("skuName").?.string,
            .productName = o.get("productName").?.string,
            .retailPrice = o.get("retailPrice").?.number_string,
            .type = o.get("type").?.string,
            .serviceName = o.get("serviceName").?.string,
            .unitOfMeasure = o.get("unitOfMeasure").?.string,
            .effectiveStartDate = o.get("effectiveStartDate").?.string,
            .meterId = o.get("meterId").?.string,
        });
    }
}

test "against production's 13 rows for one size: the Linux spot and on-demand prices, and no other" {
    var rig: Rig = undefined;
    try rig.init(null);
    defer rig.deinit();
    try addProductionRows(&rig.fake, @import("production_bodies.zig").d2as_v5_eastus2);
    try testing.expectEqual(13, rig.fake.rows.items.len);

    var spot = try rig.client.list(.{ .sku = sku, .region = "eastus2" });
    defer spot.deinit();
    try testing.expectEqual(1, spot.value.prices.len);
    try testing.expectEqual(nanos("0.015919"), spot.value.prices[0].per_hour.toNanos());
    try testing.expectEqualStrings("2026-09-01T00:00:00Z", spot.value.prices[0].effective_start);

    var on_demand = try rig.client.list(.{ .pricing = .on_demand, .sku = sku, .region = "eastus2" });
    defer on_demand.deinit();
    try testing.expectEqual(1, on_demand.value.prices.len);
    try testing.expectEqual(nanos("0.086"), on_demand.value.prices[0].per_hour.toNanos());
    try testing.expectEqual(0, spot.value.skipped + on_demand.value.skipped);
}
