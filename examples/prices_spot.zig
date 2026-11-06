//! Every region's Linux spot price for one VM size, from the Retail Prices
//! API, which needs no credentials. docs/prices/README.md shows this file.
//!
//!     zig build example-prices_spot

const std = @import("std");
const prices = @import("prices");

pub fn main(init: std.process.Init) !void {
    var client: prices.Client = try .init(init.gpa, init.io, .{});
    defer client.deinit();

    var spot = try client.list(.{ .sku = "Standard_D2as_v5" });
    defer spot.deinit();
    for (spot.value.prices) |p| std.debug.print("{s}  {f} {s}/h\n", .{ p.region, p.per_hour, p.currency });
}
