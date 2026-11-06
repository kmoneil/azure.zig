//! The Retail Prices API in memory, behind `prices.Options.transport`. Rows
//! a test adds are filtered by the OData the client sends (`eq`,
//! `startswith` and `endswith`, each perhaps `eq false`, joined by `and`),
//! values compared with case as the API compares them, and paged with a
//! `NextPageLink` that writes the default port, as production's does
//! (measured on t23). A filter of any other form is refused as production
//! refuses `not`: 400, `{"Error":{"Code":"BadRequest",...}}`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const wire = core.transport;

pub const FakePrices = struct {
    arena: std.heap.ArenaAllocator,
    rows: std.ArrayList(Row) = .empty,
    page_size: usize = 1000,
    /// Where the fake answers, and what its links start with: production's
    /// host with the default port written out, as production writes it.
    base_url: []const u8 = "https://prices.azure.com",
    link_base: []const u8 = "https://prices.azure.com:443",
    /// Requests answered so far.
    requests: usize = 0,

    /// One row, as the API lists it. `retailPrice` is the number's text.
    pub const Row = struct {
        armRegionName: []const u8,
        armSkuName: []const u8,
        skuName: []const u8,
        productName: []const u8,
        retailPrice: []const u8,
        type: []const u8 = "Consumption",
        serviceName: []const u8 = "Virtual Machines",
        unitOfMeasure: []const u8 = "1 Hour",
        effectiveStartDate: []const u8 = "2026-09-01T00:00:00Z",
        meterId: []const u8 = "00000000-0000-4000-8000-000000000000",
    };

    pub fn init(gpa: Allocator) FakePrices {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *FakePrices) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn addRow(self: *FakePrices, row: Row) Allocator.Error!void {
        const a = self.arena.allocator();
        var copy = row;
        inline for (@typeInfo(Row).@"struct".field_names) |name| @field(copy, name) = try a.dupe(u8, @field(row, name));
        try self.rows.append(a, copy);
    }

    /// The rows production lists for one size in one region (t23 measured
    /// Standard_D2as_v5 in eastus2): the Linux spot and on-demand prices
    /// given, and the ones a client must leave out: Windows spot and on
    /// demand, Dev/Test, a reservation, the legacy Low Priority meter, and
    /// Cloud Services.
    pub fn addSize(self: *FakePrices, region: []const u8, sku: []const u8, family: []const u8, spot: []const u8, on_demand: []const u8) Allocator.Error!void {
        var buf: [6][128]u8 = undefined;
        const vm = std.fmt.bufPrint(&buf[0], "Virtual Machines {s} Series", .{family}) catch unreachable;
        const windows = std.fmt.bufPrint(&buf[1], "Virtual Machines {s} Series Windows", .{family}) catch unreachable;
        const cloud = std.fmt.bufPrint(&buf[2], "{s} Series Cloud Services", .{family}) catch unreachable;
        const spot_sku = std.fmt.bufPrint(&buf[3], "{s} Spot", .{sku}) catch unreachable;
        const low = std.fmt.bufPrint(&buf[4], "{s} Low Priority", .{sku}) catch unreachable;
        const rows = [_]Row{
            .{ .armRegionName = region, .armSkuName = sku, .skuName = spot_sku, .productName = vm, .retailPrice = spot },
            .{ .armRegionName = region, .armSkuName = sku, .skuName = sku, .productName = vm, .retailPrice = on_demand },
            .{ .armRegionName = region, .armSkuName = sku, .skuName = spot_sku, .productName = windows, .retailPrice = "0.032948" },
            .{ .armRegionName = region, .armSkuName = sku, .skuName = sku, .productName = windows, .retailPrice = "0.178" },
            .{ .armRegionName = region, .armSkuName = sku, .skuName = spot_sku, .productName = windows, .retailPrice = spot, .type = "DevTestConsumption" },
            .{ .armRegionName = region, .armSkuName = sku, .skuName = sku, .productName = vm, .retailPrice = "465.0", .type = "Reservation" },
            .{ .armRegionName = region, .armSkuName = sku, .skuName = low, .productName = vm, .retailPrice = "0.0172" },
            .{ .armRegionName = region, .armSkuName = sku, .skuName = sku, .productName = cloud, .retailPrice = "0.178" },
        };
        for (rows) |r| try self.addRow(r);
    }

    pub fn transport(self: *FakePrices) wire.Transport {
        return .{ .ptr = self, .vtable = &.{ .send = send } };
    }

    fn send(ptr: *anyopaque, req: wire.Request, arena: Allocator) wire.Error!wire.Response {
        const self: *FakePrices = @ptrCast(@alignCast(ptr));
        self.requests += 1;
        if (req.bearer != null) return .{ .status = 400, .body = "{\"Error\":{\"Code\":\"BadRequest\",\"Message\":\"The fake was sent a token, which the API never asks for\"}}" };
        if (!std.mem.startsWith(u8, req.url, self.base_url)) return .{ .status = 404, .body = "" };
        const rest = req.url[self.base_url.len..];
        const q = std.mem.indexOfScalar(u8, rest, '?') orelse rest.len;
        if (!std.mem.eql(u8, rest[0..q], "/api/retail/prices") or req.method != .GET) return .{ .status = 404, .body = "" };
        const query = if (q < rest.len) rest[q + 1 ..] else "";
        return self.answer(arena, query);
    }

    fn answer(self: *FakePrices, arena: Allocator, query: []const u8) Allocator.Error!wire.Response {
        const text = try param(arena, query, "$filter") orelse "";
        const clauses = parseFilter(arena, text) catch
            return .{ .status = 400, .body = "{\"Error\":{\"Code\":\"BadRequest\",\"Message\":\"Invalid OData parameters supplied\"}}" };
        var currency: []const u8 = "USD";
        if (try param(arena, query, "currencyCode")) |c| currency = std.mem.trim(u8, c, "'");
        const skip = std.fmt.parseInt(usize, try param(arena, query, "$skip") orelse "0", 10) catch 0;

        var matching: std.ArrayList(Row) = .empty;
        for (self.rows.items) |r| if (matchesAll(r, clauses)) try matching.append(arena, r);
        const start = @min(skip, matching.items.len);
        const end = @min(matching.items.len, start + self.page_size);

        var w: std.Io.Writer.Allocating = .init(arena);
        self.writePage(&w.writer, query, currency, matching.items[start..end], if (end < matching.items.len) end else null) catch return error.OutOfMemory;
        return .{ .status = 200, .body = w.written() };
    }

    fn writePage(self: *FakePrices, w: *std.Io.Writer, query: []const u8, currency: []const u8, rows: []const Row, next: ?usize) std.Io.Writer.Error!void {
        var jw: std.json.Stringify = .{ .writer = w };
        try jw.beginObject();
        try jw.objectField("BillingCurrency");
        try jw.write(currency);
        try jw.objectField("CustomerEntityId");
        try jw.write("Default");
        try jw.objectField("CustomerEntityType");
        try jw.write("Retail");
        try jw.objectField("Items");
        try jw.beginArray();
        for (rows) |r| try writeRow(&jw, r, currency);
        try jw.endArray();
        try jw.objectField("NextPageLink");
        if (next) |n| {
            const kept = query[0 .. std.mem.indexOf(u8, query, "&$skip=") orelse query.len];
            try jw.print("\"{s}/api/retail/prices?{s}&$skip={d}\"", .{ self.link_base, kept, n });
        } else try jw.write(null);
        try jw.objectField("Count");
        try jw.write(rows.len);
        try jw.endObject();
    }

    fn writeRow(jw: *std.json.Stringify, r: Row, currency: []const u8) std.json.Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("currencyCode");
        try jw.write(currency);
        // The number as the test wrote it, as production writes its own.
        try jw.objectField("retailPrice");
        try jw.print("{s}", .{r.retailPrice});
        try jw.objectField("unitPrice");
        try jw.print("{s}", .{r.retailPrice});
        inline for (.{ "armRegionName", "armSkuName", "skuName", "productName", "serviceName", "unitOfMeasure", "effectiveStartDate", "meterId", "type" }) |name| {
            try jw.objectField(name);
            try jw.write(@field(r, name));
        }
        try jw.endObject();
    }

    // The filter.

    const Op = enum { eq, startswith, endswith };

    const Clause = struct {
        op: Op,
        field: []const u8,
        value: []const u8,
        negated: bool,

        fn holds(c: Clause, r: Row) bool {
            const have = fieldOf(r, c.field).?;
            const yes = switch (c.op) {
                .eq => std.mem.eql(u8, have, c.value),
                .startswith => std.mem.startsWith(u8, have, c.value),
                .endswith => std.mem.endsWith(u8, have, c.value),
            };
            return yes != c.negated;
        }
    };

    fn matchesAll(r: Row, clauses: []const Clause) bool {
        for (clauses) |c| if (!c.holds(r)) return false;
        return true;
    }

    fn fieldOf(r: Row, name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, "priceType")) return r.type;
        inline for (.{ "armRegionName", "armSkuName", "skuName", "productName", "serviceName" }) |f| {
            if (std.mem.eql(u8, name, f)) return @field(r, f);
        }
        return null;
    }

    fn parseFilter(arena: Allocator, text: []const u8) error{ OutOfMemory, Invalid }![]const Clause {
        var clauses: std.ArrayList(Clause) = .empty;
        if (text.len == 0) return clauses.items;
        var it = std.mem.splitSequence(u8, text, " and ");
        while (it.next()) |part| try clauses.append(arena, try parseClause(part));
        return clauses.items;
    }

    fn parseClause(part: []const u8) error{Invalid}!Clause {
        var text = part;
        var negated = false;
        if (std.mem.endsWith(u8, text, " eq false")) {
            negated = true;
            text = text[0 .. text.len - " eq false".len];
        }
        for ([_]Op{ .startswith, .endswith }) |op| {
            const head = @tagName(op);
            if (!std.mem.startsWith(u8, text, head) or text.len < head.len + 1 or text[head.len] != '(') continue;
            if (text[text.len - 1] != ')') return error.Invalid;
            const inner = text[head.len + 1 .. text.len - 1];
            const comma = std.mem.indexOfScalar(u8, inner, ',') orelse return error.Invalid;
            return clause(op, inner[0..comma], inner[comma + 1 ..], negated);
        }
        const eq = std.mem.indexOf(u8, text, " eq ") orelse return error.Invalid;
        return clause(.eq, text[0..eq], text[eq + " eq ".len ..], negated);
    }

    fn clause(op: Op, field: []const u8, literal: []const u8, negated: bool) error{Invalid}!Clause {
        if (literal.len < 2 or literal[0] != '\'' or literal[literal.len - 1] != '\'') return error.Invalid;
        const value = literal[1 .. literal.len - 1];
        if (std.mem.indexOfScalar(u8, value, '\'') != null) return error.Invalid;
        const probe: Row = .{ .armRegionName = "", .armSkuName = "", .skuName = "", .productName = "", .retailPrice = "" };
        if (fieldOf(probe, field) == null) return error.Invalid;
        return .{ .op = op, .field = field, .value = value, .negated = negated };
    }

    /// A query parameter's value, percent-decoded; its name matched after
    /// decoding too, since the client writes `%24filter` and production's
    /// links `$filter`, and the API takes both.
    fn param(arena: Allocator, query: []const u8, name: []const u8) Allocator.Error!?[]const u8 {
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
            const key = std.Uri.percentDecodeInPlace(try arena.dupe(u8, pair[0..eq]));
            if (!std.mem.eql(u8, key, name)) continue;
            return std.Uri.percentDecodeInPlace(try arena.dupe(u8, if (eq < pair.len) pair[eq + 1 ..] else ""));
        }
        return null;
    }
};
