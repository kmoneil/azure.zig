//! The prices module against Azure's Retail Prices API, which needs no
//! credentials:
//!
//!     PRICES_TEST=1 zig build test-integration-azure -Dtest-filter=prices
//!
//! Without PRICES_TEST every test skips. Reads only, a few requests a run:
//! the API's limits are undocumented and its rate-limit headers say little,
//! so the suite asks for little.

const std = @import("std");
const prices = @import("prices");
const testing = std.testing;

const Fixture = struct {
    env: std.process.Environ.Map,
    diag: prices.Diagnostics,
    client: prices.Client,

    fn init(f: *Fixture, currency: ?[]const u8) !bool {
        const gpa = testing.allocator;
        f.env = try testing.environ.createMap(gpa);
        errdefer f.env.deinit();
        if (f.env.get("PRICES_TEST") == null) {
            f.env.deinit();
            return false;
        }
        f.diag = .{};
        f.client = try .init(gpa, testing.io, .{
            .diagnostics = &f.diag,
            .currency = currency,
            .user_agent = "azure-zig-prices-integration/0.1",
        });
        return true;
    }

    fn deinit(f: *Fixture) void {
        f.client.deinit();
        f.env.deinit();
    }

    fn explain(f: *Fixture, err: anyerror) anyerror {
        std.debug.print("  failed: {t}: {f}\n", .{ err, f.diag });
        return err;
    }
};

fn fact(comptime format: []const u8, args: anytype) void {
    std.debug.print("  fact: " ++ format ++ "\n", args);
}

test "prices: Standard_D2as_v5 spot, one Linux price per region, the filter doing all the work" {
    var f: Fixture = undefined;
    if (!try f.init(null)) return error.SkipZigTest;
    defer f.deinit();
    var got = f.client.list(.{ .sku = "Standard_D2as_v5" }) catch |err| return f.explain(err);
    defer got.deinit();
    // 66 regions on 2026-11-06; the count moves as regions open.
    try testing.expect(got.value.prices.len > 40);
    try testing.expectEqual(0, got.value.skipped);
    for (got.value.prices, 0..) |p, i| {
        try testing.expectEqualStrings("USD", p.currency);
        try testing.expect(p.per_hour.toNanos() > 0);
        for (got.value.prices[0..i]) |earlier| try testing.expect(!std.mem.eql(u8, earlier.region, p.region));
    }
    var best = (f.client.cheapest(.{ .sku = "Standard_D2as_v5" }) catch |err| return f.explain(err)).?;
    defer best.deinit();
    fact("{d} regions in {d} page(s); cheapest {s} at {f}/h", .{ got.value.prices.len, got.value.pages, best.value.region, best.value.per_hour });
}

test "prices: a region's whole on-demand list, through every page" {
    var f: Fixture = undefined;
    if (!try f.init(null)) return error.SkipZigTest;
    defer f.deinit();
    var got = f.client.list(.{ .pricing = .on_demand, .region = "eastus2" }) catch |err| return f.explain(err);
    defer got.deinit();
    try testing.expect(got.value.prices.len > 100);
    fact("eastus2 on demand: {d} sizes in {d} page(s), {d} row(s) left out by the check", .{ got.value.prices.len, got.value.pages, got.value.skipped });
}

test "prices: in euros when asked" {
    var f: Fixture = undefined;
    if (!try f.init("EUR")) return error.SkipZigTest;
    defer f.deinit();
    var got = f.client.list(.{ .sku = "Standard_D2as_v5", .region = "eastus2" }) catch |err| return f.explain(err);
    defer got.deinit();
    try testing.expectEqual(1, got.value.prices.len);
    try testing.expectEqualStrings("EUR", got.value.prices[0].currency);
    fact("Standard_D2as_v5 spot in eastus2: {f} EUR/h", .{got.value.prices[0].per_hour});
}

test "prices: a filter the API refuses comes back as BadRequest, with its message" {
    var f: Fixture = undefined;
    if (!try f.init(null)) return error.SkipZigTest;
    defer f.deinit();
    // A size no filter of the client's can name is refused before sending;
    // a raw call through the engine is what reaches the API's own refusal.
    var response: std.heap.ArenaAllocator = .init(testing.allocator);
    defer response.deinit();
    f.client.engine.begin();
    try testing.expectError(error.BadRequest, f.client.engine.execute(&response, .{
        .method = .GET,
        .path = "/api/retail/prices?api-version=2023-01-01-preview&%24filter=not%20endswith(productName%2C%27%20Windows%27)",
    }));
    try testing.expectEqualStrings("BadRequest", f.diag.code());
    fact("refused: {f}", .{f.diag});
}
