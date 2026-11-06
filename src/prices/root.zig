//! Azure VM prices from the Retail Prices API: Linux, spot or on demand, by
//! region and size, every amount exact.
//!
//! `Client.list` reads every page a query names; `Client.cheapest` picks the
//! lowest. One size in one region is a dozen rows in the API (Windows,
//! Dev/Test, reservations, the legacy Low Priority meters, Cloud Services);
//! the client asks for the one wanted and checks every row again. The API
//! needs no credentials, and the client never sends any.

const core = @import("core");
const types = @import("types.zig");

pub const Client = @import("Client.zig");
pub const Options = Client.Options;
pub const Error = Client.Error;
pub const api_version = Client.api_version;

pub const Amount = @import("Amount.zig");
pub const Owned = types.Owned;
pub const Pricing = types.Pricing;
pub const Query = types.Query;
pub const Price = types.Price;
pub const PriceList = types.PriceList;

pub const Diagnostics = core.Diagnostics;
pub const RetryPolicy = core.RetryPolicy;
/// The HTTP seam: implement `transport.Transport` to send requests another
/// way, or to fake the API in your own tests.
pub const transport = core.transport;

/// What a test of code that reads prices can stand on, with no network.
pub const testing = struct {
    /// The Retail Prices API in memory, behind `Options.transport`: rows a
    /// test adds, filtered as the API filters them and paged as it pages.
    pub const FakePrices = @import("fake_prices.zig").FakePrices;
};

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("Amount.zig");
    _ = @import("fake_prices.zig");
    _ = @import("production_bodies.zig");
    _ = @import("Client_test.zig");
}
