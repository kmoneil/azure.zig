//! The prices client: Linux VM prices from Azure's Retail Prices API, spot
//! or on demand, by region and size. The API needs no credentials, and the
//! client never sends any. Made with `init`, freed with `deinit`; one task
//! uses it at a time.

const Client = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const transport = core.transport;
const types = @import("types.zig");
const Amount = @import("Amount.zig");

const Engine = core.loop.Engine(.azure_prices, Hook);

pub const default_endpoint = "https://prices.azure.com";
pub const api_version = "2023-01-01-preview";
/// Pages read at most for one list: the whole catalogue of VM prices is a
/// few hundred pages of 1000.
pub const max_pages = 2_000;

gpa: Allocator,
io: std.Io,
engine: Engine,
currency: ?[]const u8,
http: ?*transport.HttpTransport,

pub const Options = struct {
    /// Prices in this currency, as `EUR`; null: the API's, USD.
    currency: ?[]const u8 = null,
    /// In place of the API's endpoint, as `https://host[:port]`. It must
    /// outlive the client.
    endpoint: []const u8 = default_endpoint,
    /// Null: a `std.http.Client` transport of the client's own.
    transport: ?transport.Transport = null,
    diagnostics: ?*core.Diagnostics = null,
    retry: core.RetryPolicy = core.arm.retry_policy,
    request_timeout_ms: u32 = 60_000,
    user_agent: []const u8 = "azure.zig",
};

pub const Error = Hook.RefusalError || transport.Error || core.TokenProvider.Error || error{
    /// A size, region or currency refused before anything is sent:
    /// `Diagnostics` says which.
    InvalidArgument,
    /// An answer that is not the JSON the API sends, or a price finer than
    /// a billionth: `Diagnostics` says which.
    InvalidResponse,
};

/// The Retail Prices API's side of rest-core's loop. Its refusals read
/// `{"Error":{"Code","Message"}}`, capitalized (measured on t23).
pub const Hook = struct {
    pub const RefusalError = error{
        /// 400: an OData filter or parameter the API refused.
        BadRequest,
        NotFound,
        Throttled,
        ServerError,
        Refused,
    };

    pub fn refusal(scratch: Allocator, res: transport.Response, diagnostics: ?*core.Diagnostics) (RefusalError || Allocator.Error) {
        const Inner = struct { Code: ?[]const u8 = null, Message: ?[]const u8 = null };
        const Body = struct { Error: ?Inner = null };
        const body: Body = std.json.parseFromSliceLeaky(Body, scratch, res.body, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => .{},
        };
        const inner = body.Error orelse Inner{};
        if (diagnostics) |d| d.set(res.status, inner.Code orelse "", inner.Message orelse res.body);
        return switch (res.status) {
            400 => error.BadRequest,
            404 => error.NotFound,
            429 => error.Throttled,
            500...599 => error.ServerError,
            else => error.Refused,
        };
    }

    pub const retryable = core.arm.Hook.retryable;

    pub fn bodyDelayMs(scratch: Allocator, body: []const u8) Allocator.Error!?u32 {
        _ = scratch;
        _ = body;
        return null;
    }
};

pub fn init(gpa: Allocator, io: std.Io, options: Options) Allocator.Error!Client {
    var http: ?*transport.HttpTransport = null;
    const t = options.transport orelse t: {
        const h = try gpa.create(transport.HttpTransport);
        h.* = .init(gpa, io, options.user_agent);
        http = h;
        break :t h.transport();
    };
    return .{
        .gpa = gpa,
        .io = io,
        .currency = options.currency,
        .http = http,
        .engine = .{
            .gpa = gpa,
            .io = io,
            .transport = t,
            .base_url = options.endpoint,
            .auth_scope = "",
            .unauthenticated = true,
            .diagnostics = options.diagnostics,
            .retry = options.retry,
            .request_timeout_ms = options.request_timeout_ms,
        },
    };
}

pub fn deinit(self: *Client) void {
    if (self.http) |h| {
        h.deinit();
        self.gpa.destroy(h);
    }
    self.* = undefined;
}

/// Every Linux VM price that `query` names, every page read: one per size
/// and region for spot or on demand. Windows, Dev/Test, reservations, the
/// legacy Low Priority meters and Cloud Services are left out, by the
/// filter and again row by row.
pub fn list(self: *Client, query: types.Query) Error!types.Owned(types.PriceList) {
    self.engine.begin();
    try self.check(query);
    var out: types.Owned(types.PriceList) = try .init(self.gpa);
    errdefer out.deinit();
    const a = out.arena.allocator();
    var prices: std.ArrayList(types.Price) = .empty;
    var skipped: usize = 0;
    var response: std.heap.ArenaAllocator = .init(self.gpa);
    defer response.deinit();
    var path: ?[]const u8 = try self.firstPath(a, query);
    var pages: usize = 0;
    while (path) |p| : (pages += 1) {
        if (pages == max_pages) return self.invalid("a list ran past {d} pages", .{max_pages});
        const body = try self.engine.execute(&response, .{ .method = .GET, .path = p });
        const page = std.json.parseFromSliceLeaky(Page, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return self.invalid("a page of prices is not the JSON the API sends, or holds a price finer than a billionth ({t})", .{err});
        };
        for (page.Items) |row| {
            if (row.price(query.pricing)) |price| try prices.append(a, price) else skipped += 1;
        }
        path = try self.nextPath(page.NextPageLink, p);
        _ = response.reset(.retain_capacity);
    }
    out.value = .{ .prices = prices.items, .skipped = skipped, .pages = pages };
    return out;
}

/// The cheapest price `query` names, or null when it names none.
pub fn cheapest(self: *Client, query: types.Query) Error!?types.Owned(types.Price) {
    var all = try self.list(query);
    errdefer all.deinit();
    if (all.value.prices.len == 0) {
        all.deinit();
        return null;
    }
    var best = all.value.prices[0];
    for (all.value.prices[1..]) |p| if (p.per_hour.order(best.per_hour) == .lt) {
        best = p;
    };
    // The price's strings live in the list's arena, which the result keeps.
    return .{ .value = best, .arena = all.arena, .wiping = all.wiping };
}

/// One page as the API sends it.
const Page = struct {
    Items: []const Row = &.{},
    NextPageLink: ?[]const u8 = null,
};

/// One row as the API sends it.
const Row = struct {
    currencyCode: []const u8 = "",
    retailPrice: Amount = .{},
    armRegionName: []const u8 = "",
    armSkuName: []const u8 = "",
    skuName: []const u8 = "",
    productName: []const u8 = "",
    type: []const u8 = "",
    unitOfMeasure: []const u8 = "",
    effectiveStartDate: []const u8 = "",
    meterId: []const u8 = "",

    /// The price, when the row is a Linux VM's consumption price per hour
    /// of the kind asked; null for any other row the filter let through.
    fn price(r: Row, pricing: types.Pricing) ?types.Price {
        if (!std.mem.eql(u8, r.type, "Consumption") or !std.mem.eql(u8, r.unitOfMeasure, "1 Hour")) return null;
        if (!std.mem.startsWith(u8, r.productName, "Virtual Machines") or std.mem.endsWith(u8, r.productName, " Windows")) return null;
        if (r.armSkuName.len == 0 or r.armRegionName.len == 0) return null;
        const spot = std.mem.endsWith(u8, r.skuName, " Spot");
        if (std.mem.endsWith(u8, r.skuName, " Low Priority") or spot != (pricing == .spot)) return null;
        return .{
            .region = r.armRegionName,
            .sku = r.armSkuName,
            .pricing = pricing,
            .per_hour = r.retailPrice,
            .currency = r.currencyCode,
            .effective_start = r.effectiveStartDate,
            .meter_id = r.meterId,
            .product_name = r.productName,
        };
    }
};

fn firstPath(self: *Client, arena: Allocator, query: types.Query) Allocator.Error![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    self.writeFirstPath(&w.writer, arena, query) catch return error.OutOfMemory;
    return w.written();
}

fn writeFirstPath(self: *Client, w: *std.Io.Writer, arena: Allocator, query: types.Query) (std.Io.Writer.Error || Allocator.Error)!void {
    try w.writeAll("/api/retail/prices");
    var params: core.query.Params = .init(w);
    try params.add("api-version", api_version);
    if (self.currency) |c| try params.add("currencyCode", try std.fmt.allocPrint(arena, "'{s}'", .{c}));
    try params.add("$filter", try filter(arena, query));
}

/// The OData filter: Linux VM consumption prices of the kind asked, in the
/// region and of the size asked. Values compare with case, as the API's do.
pub fn filter(arena: Allocator, query: types.Query) Allocator.Error![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    writeFilter(&w.writer, query) catch return error.OutOfMemory;
    return w.written();
}

fn writeFilter(w: *std.Io.Writer, query: types.Query) std.Io.Writer.Error!void {
    try w.writeAll("serviceName eq 'Virtual Machines' and priceType eq 'Consumption'");
    try w.writeAll(" and startswith(productName,'Virtual Machines') and endswith(productName,' Windows') eq false");
    switch (query.pricing) {
        .spot => try w.writeAll(" and endswith(skuName,' Spot')"),
        .on_demand => try w.writeAll(" and endswith(skuName,' Spot') eq false and endswith(skuName,' Low Priority') eq false"),
    }
    // The values are checked letters, digits and `_`: no quote to double.
    if (query.region) |r| try w.print(" and armRegionName eq '{s}'", .{r});
    if (query.sku) |s| try w.print(" and armSkuName eq '{s}'", .{s});
}

/// The next page's path, followed only on the client's own origin; the
/// API writes the default port into every one.
fn nextPath(self: *Client, link: ?[]const u8, current: []const u8) Error!?[]const u8 {
    const next = link orelse return null;
    if (next.len == 0) return null;
    const path = core.origin.pathOnOrigin(self.engine.base_url, next) orelse {
        if (self.engine.diagnostics) |d| d.print("a NextPageLink is not on {s}", .{self.engine.base_url});
        return error.InvalidEndpoint;
    };
    if (std.mem.eql(u8, path, current)) return self.invalid("a page names itself as the next", .{});
    return path;
}

fn check(self: *Client, query: types.Query) Error!void {
    if (query.region) |r| if (!isWord(r, false)) return self.refuse("a region is lowercase letters and digits, as eastus2: the API's filter compares with case", .{});
    if (query.sku) |s| if (!isWord(s, true)) return self.refuse("a size is ARM's name, as Standard_D2as_v5: letters, digits and _", .{});
    if (self.currency) |c| {
        if (c.len != 3) return self.refuse("a currency is three capital letters, as EUR", .{});
        for (c) |ch| if (!std.ascii.isUpper(ch)) return self.refuse("a currency is three capital letters, as EUR", .{});
    }
}

/// Letters (lowercase only, for a region) and digits, and `_` for a size.
fn isWord(text: []const u8, size: bool) bool {
    if (text.len == 0 or text.len > 64) return false;
    for (text) |c| {
        const ok = std.ascii.isDigit(c) or std.ascii.isLower(c) or (size and (std.ascii.isUpper(c) or c == '_'));
        if (!ok) return false;
    }
    return true;
}

fn refuse(self: *Client, comptime fmt: []const u8, args: anytype) error{InvalidArgument} {
    if (self.engine.diagnostics) |d| d.print(fmt, args);
    return error.InvalidArgument;
}

fn invalid(self: *Client, comptime fmt: []const u8, args: anytype) error{InvalidResponse} {
    if (self.engine.diagnostics) |d| d.print(fmt, args);
    return error.InvalidResponse;
}
