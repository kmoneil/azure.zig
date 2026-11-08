//! Resource Manager's compute reads in memory, for code that uses the
//! compute module: virtual machines with their instance views, Resource
//! SKUs, locations with zone mappings, and usages, behind
//! `Client.Options.transport`. Lists come in pages of `page_size`.
//!
//! What it holds by default is what t19's m0 measured on the test
//! subscription on 2026-11-07: eastus2 and westus2 with their zone
//! mappings (eastus2 has four), cores 10 and spot cores (lowPriorityCores)
//! 3 in each, and no sizes or VMs, which a test adds; `addMeasuredSizes`
//! adds eastus2's as measured.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const wire = core.transport;
const Header = wire.Header;

pub const FakeCompute = struct {
    arena: std.heap.ArenaAllocator,
    /// The ARM endpoint the fake answers as, and writes into next links.
    base_url: []const u8 = core.Cloud.public.arm_endpoint,
    /// Items in one page of a list.
    page_size: usize = 100,
    vms: std.ArrayList(Vm) = .empty,
    sizes: std.ArrayList(Size) = .empty,
    locations: std.ArrayList(Location) = .empty,
    usages: std.ArrayList(Usage) = .empty,
    /// Every request, in order: its method and path with query.
    calls: std.ArrayList(Call) = .empty,

    pub const Call = struct { method: wire.Method, path: []const u8 };
    pub const Tag = struct { name: []const u8, value: []const u8 };

    pub const Vm = struct {
        subscription: []const u8,
        group: []const u8,
        name: []const u8,
        location: []const u8 = "eastus2",
        size: []const u8 = "Standard_D2ds_v5",
        priority: []const u8 = "Spot",
        eviction_policy: ?[]const u8 = "Delete",
        zone: ?[]const u8 = null,
        tags: []const Tag = &.{},
        /// As `provisioningState` writes it.
        provisioning: []const u8 = "Succeeded",
        /// The instance view's `PowerState/...`; null for none yet.
        power: ?[]const u8 = "running",
        /// After `ProvisioningState/failed/`, when provisioning failed.
        failure: []const u8 = "",
        vm_id: []const u8 = "00000000-0000-4000-8000-0000000000f1",
    };

    pub const Size = struct {
        name: []const u8,
        location: []const u8 = "eastus2",
        vcpus: u32 = 2,
        memory_gb: f64 = 8,
        spot: bool = true,
        ephemeral_os_disk: bool = false,
        resource_disk_mb: u64 = 0,
        zones: []const []const u8 = &.{ "1", "2", "3" },
        restricted_zones: []const []const u8 = &.{},
        /// NotAvailableForSubscription across the region.
        restricted_location: bool = false,
    };

    pub const Location = struct {
        name: []const u8,
        display_name: []const u8,
        zones: []const [2][]const u8,
    };

    pub const Usage = struct {
        location: []const u8,
        name: []const u8,
        display_name: []const u8,
        current: i64 = 0,
        limit: i64,
    };

    pub fn init(gpa: Allocator) Allocator.Error!FakeCompute {
        var self: FakeCompute = .{ .arena = .init(gpa) };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        try self.locations.appendSlice(a, &.{
            .{ .name = "eastus2", .display_name = "East US 2", .zones = &.{ .{ "1", "eastus2-az3" }, .{ "2", "eastus2-az2" }, .{ "3", "eastus2-az1" }, .{ "4", "eastus2-az5" } } },
            .{ .name = "westus2", .display_name = "West US 2", .zones = &.{ .{ "1", "westus2-az2" }, .{ "2", "westus2-az1" }, .{ "3", "westus2-az3" } } },
        });
        for ([_][]const u8{ "eastus2", "westus2" }) |l| try self.usages.appendSlice(a, &.{
            .{ .location = l, .name = "cores", .display_name = "Total Regional vCPUs", .limit = 10 },
            .{ .location = l, .name = "lowPriorityCores", .display_name = "Total Regional Low-priority vCPUs", .limit = 3 },
        });
        return self;
    }

    pub fn deinit(self: *FakeCompute) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn transport(self: *FakeCompute) wire.Transport {
        return .{ .ptr = self, .vtable = &.{ .send = send, .sendStream = sendStream } };
    }

    pub fn addVm(self: *FakeCompute, vm: Vm) Allocator.Error!void {
        try self.vms.append(self.arena.allocator(), vm);
    }

    pub fn addSize(self: *FakeCompute, size: Size) Allocator.Error!void {
        try self.sizes.append(self.arena.allocator(), size);
    }

    /// eastus2's sizes as the test subscription was offered them on
    /// 2026-11-07: D2ds_v5 and D2s_v5 in zone 4 alone (1 to 3 restricted),
    /// D2as_v5 and B2s not at all.
    pub fn addMeasuredSizes(self: *FakeCompute) Allocator.Error!void {
        const all: []const []const u8 = &.{ "1", "2", "3", "4" };
        try self.sizes.appendSlice(self.arena.allocator(), &.{
            .{ .name = "Standard_D2ds_v5", .ephemeral_os_disk = true, .resource_disk_mb = 76800, .zones = all, .restricted_zones = &.{ "1", "2", "3" } },
            .{ .name = "Standard_D2s_v5", .zones = all, .restricted_zones = &.{ "1", "2", "3" } },
            .{ .name = "Standard_D2as_v5", .zones = all, .restricted_location = true, .restricted_zones = &.{ "1", "2", "3" } },
            .{ .name = "Standard_B2s", .spot = false, .ephemeral_os_disk = true, .resource_disk_mb = 8192, .zones = all, .restricted_location = true, .restricted_zones = all },
        });
    }

    // The wire.

    fn sendStream(ptr: *anyopaque, req: wire.StreamRequest, arena: Allocator) wire.StreamError!wire.StreamResponse {
        _ = ptr;
        _ = req;
        _ = arena;
        // The reads go buffered.
        return error.HttpProtocolError;
    }

    fn send(ptr: *anyopaque, req: wire.Request, arena: Allocator) wire.Error!wire.Response {
        const self: *FakeCompute = @ptrCast(@alignCast(ptr));
        if (!std.mem.startsWith(u8, req.url, self.base_url)) return refusal(arena, 400, "InvalidRequestUri", "The request URI is not this ARM's.");
        const rest = req.url[self.base_url.len..];
        const a = self.arena.allocator();
        try self.calls.append(a, .{ .method = req.method, .path = try a.dupe(u8, rest) });
        if (req.method != .GET) return refusal(arena, 405, "MethodNotAllowed", "The fake answers reads only.");
        const q = std.mem.indexOfScalar(u8, rest, '?');
        const path = rest[0 .. q orelse rest.len];
        const query = if (q) |i| rest[i + 1 ..] else "";
        var s: [10][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |seg| : (n += 1) {
            if (n == s.len) return notFound(arena);
            s[n] = seg;
        }
        return self.route(arena, s[0..n], path, query);
    }

    fn route(self: *FakeCompute, arena: Allocator, s: []const []const u8, path: []const u8, query: []const u8) Allocator.Error!wire.Response {
        if (s.len < 2 or !eql(s[0], "subscriptions")) return notFound(arena);
        const sub = s[1];
        if (s.len == 3 and eql(s[2], "locations")) return self.page(arena, path, query, try self.locationItems(arena));
        if (s.len >= 4 and eql(s[2], "providers") and eql(s[3], "Microsoft.Compute")) {
            if (s.len == 5 and eql(s[4], "virtualMachines")) return self.page(arena, path, query, try self.vmItems(arena, sub, null, null));
            if (s.len == 5 and eql(s[4], "skus")) return self.page(arena, path, query, try self.skuItems(arena, try skuLocation(arena, query)));
            if (s.len == 7 and eql(s[4], "locations") and eql(s[6], "virtualMachines")) return self.page(arena, path, query, try self.vmItems(arena, sub, null, s[5]));
            if (s.len == 7 and eql(s[4], "locations") and eql(s[6], "usages")) return self.page(arena, path, query, try self.usageItems(arena, s[5]));
        }
        if (s.len >= 7 and eql(s[2], "resourceGroups") and eql(s[4], "providers") and eql(s[5], "Microsoft.Compute") and eql(s[6], "virtualMachines")) {
            if (s.len == 7) return self.page(arena, path, query, try self.vmItems(arena, sub, s[3], null));
            if (s.len == 8) return self.getVm(arena, sub, s[3], s[7], std.mem.indexOf(u8, query, "$expand=instanceView") != null);
        }
        return notFound(arena);
    }

    fn eql(a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }

    fn getVm(self: *FakeCompute, arena: Allocator, sub: []const u8, group: []const u8, name: []const u8, expand: bool) Allocator.Error!wire.Response {
        for (self.vms.items) |vm| if (eql(vm.subscription, sub) and eql(vm.group, group) and eql(vm.name, name)) {
            return .{ .status = 200, .body = try self.json(arena, vm, expand, writeVm) };
        };
        return refusal(arena, 404, "ResourceNotFound", try std.fmt.allocPrint(arena, "The Resource 'Microsoft.Compute/virtualMachines/{s}' under resource group '{s}' was not found.", .{ name, group }));
    }

    fn vmItems(self: *FakeCompute, arena: Allocator, sub: []const u8, group: ?[]const u8, location: ?[]const u8) Allocator.Error![]const []const u8 {
        var items: std.ArrayList([]const u8) = .empty;
        for (self.vms.items) |vm| {
            if (!eql(vm.subscription, sub)) continue;
            if (group) |g| if (!eql(vm.group, g)) continue;
            if (location) |l| if (!eql(vm.location, l)) continue;
            try items.append(arena, try self.json(arena, vm, false, writeVm));
        }
        return items.items;
    }

    fn skuItems(self: *FakeCompute, arena: Allocator, location: ?[]const u8) Allocator.Error![]const []const u8 {
        var items: std.ArrayList([]const u8) = .empty;
        for (self.sizes.items) |size| {
            if (location) |l| if (!eql(size.location, l)) continue;
            try items.append(arena, try self.json(arena, size, false, writeSku));
        }
        return items.items;
    }

    fn locationItems(self: *FakeCompute, arena: Allocator) Allocator.Error![]const []const u8 {
        var items: std.ArrayList([]const u8) = .empty;
        for (self.locations.items) |l| try items.append(arena, try self.json(arena, l, false, writeLocation));
        return items.items;
    }

    fn usageItems(self: *FakeCompute, arena: Allocator, location: []const u8) Allocator.Error![]const []const u8 {
        var items: std.ArrayList([]const u8) = .empty;
        for (self.usages.items) |u| if (eql(u.location, location)) try items.append(arena, try self.json(arena, u, false, writeUsage));
        return items.items;
    }

    /// `location` from `$filter=location eq 'x'`, URL-encoded or not.
    fn skuLocation(arena: Allocator, query: []const u8) Allocator.Error!?[]const u8 {
        const decoded = std.Uri.percentDecodeInPlace(try arena.dupe(u8, query));
        const start = (std.mem.indexOf(u8, decoded, "location eq '") orelse return null) + "location eq '".len;
        const end = std.mem.indexOfScalarPos(u8, decoded, start, '\'') orelse return null;
        return decoded[start..end];
    }

    /// One page of `items`, from `$skiptoken`, with a next link while more
    /// remain.
    fn page(self: *FakeCompute, arena: Allocator, path: []const u8, query: []const u8, items: []const []const u8) Allocator.Error!wire.Response {
        var from: usize = 0;
        if (std.mem.indexOf(u8, query, "$skiptoken=")) |i| {
            const tail = query[i + "$skiptoken=".len ..];
            from = std.fmt.parseInt(usize, tail[0 .. std.mem.indexOfScalar(u8, tail, '&') orelse tail.len], 10) catch 0;
        }
        const to = @min(items.len, from + self.page_size);
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        w.writeAll("{\"value\":[") catch return error.OutOfMemory;
        for (items[@min(from, items.len)..to], 0..) |item, i| {
            if (i > 0) w.writeByte(',') catch return error.OutOfMemory;
            w.writeAll(item) catch return error.OutOfMemory;
        }
        w.writeByte(']') catch return error.OutOfMemory;
        if (to < items.len) {
            const base_query = if (std.mem.indexOf(u8, query, "&$skiptoken=")) |i| query[0..i] else query;
            w.print(",\"nextLink\":\"{s}{s}?{s}&$skiptoken={d}\"", .{ self.base_url, path, base_query, to }) catch return error.OutOfMemory;
        }
        w.writeByte('}') catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn json(self: *FakeCompute, arena: Allocator, value: anytype, expand: bool, comptime write: anytype) Allocator.Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: std.json.Stringify = .{ .writer = &out.writer };
        write(&jw, self, value, expand) catch return error.OutOfMemory;
        return out.written();
    }

    fn writeVm(jw: *std.json.Stringify, self: *FakeCompute, vm: Vm, expand: bool) !void {
        try jw.beginObject();
        try field(jw, "id", try std.fmt.allocPrint(self.arena.allocator(), "/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.Compute/virtualMachines/{s}", .{ vm.subscription, vm.group, vm.name }));
        try field(jw, "name", vm.name);
        try field(jw, "type", "Microsoft.Compute/virtualMachines");
        try field(jw, "location", vm.location);
        try jw.objectField("tags");
        try jw.beginObject();
        for (vm.tags) |t| try field(jw, t.name, t.value);
        try jw.endObject();
        if (vm.zone) |z| {
            try jw.objectField("zones");
            try jw.write(&[_][]const u8{z});
        }
        try jw.objectField("properties");
        try jw.beginObject();
        try field(jw, "vmId", vm.vm_id);
        try field(jw, "timeCreated", "2026-11-07T21:07:11.5157622+00:00");
        try field(jw, "priority", vm.priority);
        if (vm.eviction_policy) |e| try field(jw, "evictionPolicy", e);
        try jw.objectField("billingProfile");
        try jw.write(.{ .maxPrice = @as(f64, -1) });
        try jw.objectField("hardwareProfile");
        try jw.write(.{ .vmSize = vm.size });
        try field(jw, "provisioningState", vm.provisioning);
        if (expand) {
            try jw.objectField("instanceView");
            try jw.beginObject();
            try jw.objectField("statuses");
            try jw.beginArray();
            var buf: [96]u8 = undefined;
            const lower = std.ascii.lowerString(buf[0..@min(vm.provisioning.len, 32)], vm.provisioning[0..@min(vm.provisioning.len, 32)]);
            var code_buf: [160]u8 = undefined;
            const code = if (vm.failure.len > 0)
                try std.fmt.bufPrint(&code_buf, "ProvisioningState/{s}/{s}", .{ lower, vm.failure })
            else
                try std.fmt.bufPrint(&code_buf, "ProvisioningState/{s}", .{lower});
            try jw.write(.{ .code = code, .level = if (vm.failure.len > 0) "Error" else "Info" });
            if (vm.power) |p| {
                var power_buf: [64]u8 = undefined;
                try jw.write(.{ .code = try std.fmt.bufPrint(&power_buf, "PowerState/{s}", .{p}), .level = "Info" });
            }
            try jw.endArray();
            try jw.endObject();
        }
        try jw.endObject();
        try jw.endObject();
    }

    fn writeSku(jw: *std.json.Stringify, self: *FakeCompute, s: Size, expand: bool) !void {
        _ = self;
        _ = expand;
        try jw.beginObject();
        try field(jw, "resourceType", "virtualMachines");
        try field(jw, "name", s.name);
        try jw.objectField("locations");
        try jw.write(&[_][]const u8{s.location});
        try jw.objectField("locationInfo");
        try jw.write(&[_]struct { location: []const u8, zones: []const []const u8 }{.{ .location = s.location, .zones = s.zones }});
        try jw.objectField("capabilities");
        try jw.beginArray();
        var buf: [4][32]u8 = undefined;
        try jw.write(.{ .name = "vCPUs", .value = try std.fmt.bufPrint(&buf[0], "{d}", .{s.vcpus}) });
        try jw.write(.{ .name = "MemoryGB", .value = try std.fmt.bufPrint(&buf[1], "{d}", .{s.memory_gb}) });
        try jw.write(.{ .name = "LowPriorityCapable", .value = if (s.spot) "True" else "False" });
        try jw.write(.{ .name = "EphemeralOSDiskSupported", .value = if (s.ephemeral_os_disk) "True" else "False" });
        try jw.write(.{ .name = "MaxResourceVolumeMB", .value = try std.fmt.bufPrint(&buf[2], "{d}", .{s.resource_disk_mb}) });
        try jw.endArray();
        try jw.objectField("restrictions");
        try jw.beginArray();
        if (s.restricted_location) try jw.write(.{ .type = "Location", .values = &[_][]const u8{s.location}, .restrictionInfo = .{ .locations = &[_][]const u8{s.location} }, .reasonCode = "NotAvailableForSubscription" });
        if (s.restricted_zones.len > 0) try jw.write(.{ .type = "Zone", .values = &[_][]const u8{s.location}, .restrictionInfo = .{ .locations = &[_][]const u8{s.location}, .zones = s.restricted_zones }, .reasonCode = "NotAvailableForSubscription" });
        try jw.endArray();
        try jw.endObject();
    }

    fn writeLocation(jw: *std.json.Stringify, self: *FakeCompute, l: Location, expand: bool) !void {
        _ = self;
        _ = expand;
        try jw.beginObject();
        try field(jw, "name", l.name);
        try field(jw, "displayName", l.display_name);
        try jw.objectField("metadata");
        try jw.write(.{ .regionType = "Physical" });
        if (l.zones.len > 0) {
            try jw.objectField("availabilityZoneMappings");
            try jw.beginArray();
            for (l.zones) |z| try jw.write(.{ .logicalZone = z[0], .physicalZone = z[1] });
            try jw.endArray();
        }
        try jw.endObject();
    }

    fn writeUsage(jw: *std.json.Stringify, self: *FakeCompute, u: Usage, expand: bool) !void {
        _ = self;
        _ = expand;
        try jw.write(.{ .limit = u.limit, .unit = "Count", .currentValue = u.current, .name = .{ .value = u.name, .localizedValue = u.display_name } });
    }

    fn field(jw: *std.json.Stringify, name: []const u8, value: []const u8) !void {
        try jw.objectField(name);
        try jw.write(value);
    }

    fn notFound(arena: Allocator) Allocator.Error!wire.Response {
        return refusal(arena, 404, "NotFound", "The fake answers only the compute module's reads.");
    }

    fn refusal(arena: Allocator, status: u16, code: []const u8, message: []const u8) Allocator.Error!wire.Response {
        return .{
            .status = status,
            .body = try std.fmt.allocPrint(arena, "{{\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}", .{ code, message }),
            .headers = try arena.dupe(Header, &.{
                .{ .name = "x-ms-request-id", .value = "11111111-1111-4111-8111-111111111111" },
                .{ .name = "x-ms-correlation-request-id", .value = "22222222-2222-4222-8222-222222222222" },
            }),
        };
    }
};
