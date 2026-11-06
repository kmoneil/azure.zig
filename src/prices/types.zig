//! What the prices module reads.

const core = @import("core");
const Amount = @import("Amount.zig");

pub const Owned = core.Owned;

pub const Pricing = enum {
    /// Spot: evictable capacity at a discount.
    spot,
    /// Pay as you go, the list price.
    on_demand,
};

/// Which prices `Client.list` asks for. Region and size compare with case,
/// as the API does: `eastus2`, `Standard_D2as_v5`.
pub const Query = struct {
    pricing: Pricing = .spot,
    /// ARM's region name; null: every region.
    region: ?[]const u8 = null,
    /// ARM's size name; null: every size.
    sku: ?[]const u8 = null,
};

/// One Linux VM size's price in one region.
pub const Price = struct {
    region: []const u8,
    sku: []const u8,
    pricing: Pricing,
    /// What an hour costs, exactly as the API wrote it.
    per_hour: Amount,
    /// As `USD`.
    currency: []const u8,
    /// When the price took effect, RFC 3339 as the API wrote it.
    effective_start: []const u8,
    meter_id: []const u8,
    /// As `Virtual Machines Dasv5 Series`.
    product_name: []const u8,
};

pub const PriceList = struct {
    prices: []const Price,
    /// Rows the filter let through that were not a Linux VM's hourly
    /// consumption price of the kind asked, and so were left out.
    skipped: usize,
    pages: usize,
};
