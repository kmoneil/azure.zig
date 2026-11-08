//! The compute client's reads, on Resource Manager: virtual machines and
//! their state, the sizes a region offers this subscription, its zones, and
//! its quotas. Made with `init`, freed with `deinit`; one task uses it at a
//! time.

const Client = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const transport = core.transport;
const types = @import("types.zig");

const Engine = core.arm.Engine(.azure_compute);

/// Microsoft.Compute's virtual machines and usages.
pub const api_version = "2026-04-01";
/// Resource SKUs.
pub const skus_api_version = "2021-07-01";
/// Microsoft.Resources' locations, which carry zone mappings.
pub const locations_api_version = "2022-12-01";

/// Pages read at most for one list, a guard against a server whose
/// `nextLink` never ends.
pub const max_pages = 10_000;

gpa: Allocator,
io: std.Io,
engine: Engine,
/// The transport the client made, when its options named none.
http: ?*transport.HttpTransport,

pub const Options = struct {
    /// Where tokens for Resource Manager come from: one of `auth`'s
    /// credentials, or a `core.StaticToken`.
    token_provider: core.TokenProvider,
    cloud: core.Cloud = .public,
    /// In place of the cloud's ARM endpoint, as `https://host[:port]` with
    /// no trailing slash. It must outlive the client.
    endpoint: ?[]const u8 = null,
    /// Null: a `std.http.Client` transport of the client's own.
    transport: ?transport.Transport = null,
    /// Details of the latest failed call.
    diagnostics: ?*core.Diagnostics = null,
    retry: core.RetryPolicy = core.arm.retry_policy,
    /// How long one attempt may take; 0 removes the limit.
    request_timeout_ms: u32 = 60_000,
    user_agent: []const u8 = "azure.zig",
};

pub const Error = core.arm.Hook.RefusalError || transport.Error || core.TokenProvider.Error || error{
    /// An argument refused before anything is sent. `Diagnostics` says
    /// which.
    InvalidArgument,
    /// An answer that is not the JSON ARM sends. `Diagnostics` says which.
    InvalidResponse,
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
        .http = http,
        .engine = .{
            .gpa = gpa,
            .io = io,
            .transport = t,
            .base_url = options.endpoint orelse options.cloud.arm_endpoint,
            .auth_scope = options.cloud.arm_scope,
            .token_provider = options.token_provider,
            .diagnostics = options.diagnostics,
            .headers = &core.arm.engine_headers,
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

// Virtual machines.

/// One VM, with its instance view read into `state`; `NotFound` when
/// there is none.
pub fn getVirtualMachine(self: *Client, subscription: []const u8, group: []const u8, name: []const u8) Error!types.Owned(types.VirtualMachine) {
    self.engine.begin();
    try self.checkGroup(subscription, group);
    if (!isVmName(name)) return self.refuse("a VM's name is 1 to 64 of letters, digits and .-_, beginning with a letter or digit and ending with one or _", .{});
    var out: types.Owned(types.VirtualMachine) = try .init(self.gpa);
    errdefer out.deinit();
    const a = out.arena.allocator();
    const path = try std.fmt.allocPrint(a, "/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.Compute/virtualMachines/{s}?api-version=" ++ api_version ++ "&$expand=instanceView", .{ subscription, group, name });
    const body = try self.get(a, path);
    const raw = std.json.parseFromSliceLeaky(RawVm, a, body, json_options) catch |err| return self.decodeFailed(err, "a VM");
    out.value = try vmOf(a, raw);
    return out;
}

/// The VMs of a group, a subscription or a region, every page read; with
/// `options.tag`, only those with that tag and value. A list carries no
/// instance view, so each VM's `state.power` is null: get one for it.
pub fn listVirtualMachines(self: *Client, subscription: []const u8, scope: types.ListScope, options: types.ListOptions) Error!types.Owned([]types.VirtualMachine) {
    self.engine.begin();
    if (!core.names.isSubscription(subscription)) return self.refuse("a subscription id is a GUID", .{});
    switch (scope) {
        .subscription => {},
        .group => |g| try self.checkGroup(subscription, g),
        .location => |l| if (!core.names.isLocation(l)) return self.refuse("a location is letters and digits, as eastus2", .{}),
    }
    var out: types.Owned([]types.VirtualMachine) = try .init(self.gpa);
    errdefer out.deinit();
    const a = out.arena.allocator();
    const path = switch (scope) {
        .subscription => try std.fmt.allocPrint(a, "/subscriptions/{s}/providers/Microsoft.Compute/virtualMachines?api-version=" ++ api_version, .{subscription}),
        .group => |g| try std.fmt.allocPrint(a, "/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.Compute/virtualMachines?api-version=" ++ api_version, .{ subscription, g }),
        .location => |l| try std.fmt.allocPrint(a, "/subscriptions/{s}/providers/Microsoft.Compute/locations/{s}/virtualMachines?api-version=" ++ api_version, .{ subscription, l }),
    };
    var raw: std.ArrayList(RawVm) = .empty;
    try self.allPages(RawVm, a, path, &raw);
    var vms: std.ArrayList(types.VirtualMachine) = .empty;
    for (raw.items) |r| {
        const vm = try vmOf(a, r);
        if (options.tag) |t| {
            const value = vm.tag(t.name) orelse continue;
            if (!std.mem.eql(u8, value, t.value)) continue;
        }
        try vms.append(a, vm);
    }
    out.value = vms.items;
    return out;
}

// Sizes, zones and quotas.

/// The VM sizes `location` offers this subscription, from Resource SKUs.
/// A size the subscription may not use there at all (a `Location`
/// restriction, as most sizes have on a new Pay-As-You-Go subscription) is
/// left out; each size's zones are the region's less the restricted ones.
/// Either kind of refused size is 409 `SkuNotAvailable` on create.
pub fn listSizes(self: *Client, subscription: []const u8, location: []const u8) Error!types.Owned([]types.Size) {
    self.engine.begin();
    if (!core.names.isSubscription(subscription)) return self.refuse("a subscription id is a GUID", .{});
    if (!core.names.isLocation(location)) return self.refuse("a location is letters and digits, as eastus2", .{});
    var out: types.Owned([]types.Size) = try .init(self.gpa);
    errdefer out.deinit();
    const a = out.arena.allocator();
    const path = try std.fmt.allocPrint(a, "/subscriptions/{s}/providers/Microsoft.Compute/skus?api-version=" ++ skus_api_version ++ "&$filter=location%20eq%20%27{s}%27", .{ subscription, location });
    var raw: std.ArrayList(RawSku) = .empty;
    try self.allPages(RawSku, a, path, &raw);
    var sizes: std.ArrayList(types.Size) = .empty;
    for (raw.items) |r| if (try sizeOf(a, r, location)) |s| try sizes.append(a, s);
    out.value = sizes.items;
    return out;
}

/// The regions the subscription can use, each with its zones as this
/// subscription numbers them and the physical zone each is.
pub fn listLocations(self: *Client, subscription: []const u8) Error!types.Owned([]types.Location) {
    self.engine.begin();
    if (!core.names.isSubscription(subscription)) return self.refuse("a subscription id is a GUID", .{});
    var out: types.Owned([]types.Location) = try .init(self.gpa);
    errdefer out.deinit();
    const a = out.arena.allocator();
    const path = try std.fmt.allocPrint(a, "/subscriptions/{s}/locations?api-version=" ++ locations_api_version, .{subscription});
    var raw: std.ArrayList(RawLocation) = .empty;
    try self.allPages(RawLocation, a, path, &raw);
    const locations = try a.alloc(types.Location, raw.items.len);
    for (raw.items, locations) |r, *l| {
        const mappings = r.availabilityZoneMappings orelse &.{};
        const zones = try a.alloc(types.ZoneMapping, mappings.len);
        for (mappings, zones) |m, *z| z.* = .{ .logical = m.logicalZone, .physical = m.physicalZone };
        l.* = .{ .name = r.name, .display_name = r.displayName, .zones = zones };
    }
    out.value = locations;
    return out;
}

/// The subscription's quotas in `location`: `cores`, each family's, and
/// `lowPriorityCores`, which every spot VM's vCPUs count against and
/// alone (measured: a family quota of 0 stopped no spot VM).
pub fn listUsages(self: *Client, subscription: []const u8, location: []const u8) Error!types.Owned([]types.Usage) {
    self.engine.begin();
    if (!core.names.isSubscription(subscription)) return self.refuse("a subscription id is a GUID", .{});
    if (!core.names.isLocation(location)) return self.refuse("a location is letters and digits, as eastus2", .{});
    var out: types.Owned([]types.Usage) = try .init(self.gpa);
    errdefer out.deinit();
    const a = out.arena.allocator();
    const path = try std.fmt.allocPrint(a, "/subscriptions/{s}/providers/Microsoft.Compute/locations/{s}/usages?api-version=" ++ api_version, .{ subscription, location });
    var raw: std.ArrayList(RawUsage) = .empty;
    try self.allPages(RawUsage, a, path, &raw);
    const usages = try a.alloc(types.Usage, raw.items.len);
    for (raw.items, usages) |r, *u| u.* = .{ .name = r.name.value, .display_name = r.name.localizedValue, .current = r.currentValue, .limit = r.limit };
    out.value = usages;
    return out;
}

// The wire.

const json_options: std.json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };

const RawStatus = struct { code: []const u8 = "" };

const RawVm = struct {
    name: []const u8 = "",
    id: []const u8 = "",
    location: []const u8 = "",
    zones: ?[]const []const u8 = null,
    tags: ?std.json.ArrayHashMap([]const u8) = null,
    properties: Properties = .{},

    const Properties = struct {
        vmId: []const u8 = "",
        timeCreated: []const u8 = "",
        priority: ?[]const u8 = null,
        evictionPolicy: ?[]const u8 = null,
        billingProfile: ?struct { maxPrice: ?f64 = null } = null,
        provisioningState: []const u8 = "",
        hardwareProfile: struct { vmSize: []const u8 = "" } = .{},
        instanceView: ?struct { statuses: []const RawStatus = &.{} } = null,
    };
};

fn vmOf(a: Allocator, r: RawVm) Allocator.Error!types.VirtualMachine {
    const p = r.properties;
    return .{
        .name = r.name,
        .id = r.id,
        .location = r.location,
        .vm_id = p.vmId,
        .size = p.hardwareProfile.vmSize,
        .zone = if (r.zones) |z| (if (z.len > 0) z[0] else null) else null,
        .priority = if (p.priority) |s| .parse(s) else .regular,
        .eviction_policy = if (p.evictionPolicy) |s| types.EvictionPolicy.parse(s) else null,
        .max_price = if (p.billingProfile) |b| b.maxPrice else null,
        .state = stateOf(p.provisioningState, if (p.instanceView) |v| v.statuses else null),
        .time_created = p.timeCreated,
        .tags = try tagsOf(a, r.tags),
    };
}

/// The state, from the instance view's statuses when there are some
/// (`ProvisioningState/succeeded`, `ProvisioningState/failed/AllocationFailed`,
/// `PowerState/running`), else from `provisioningState` alone.
fn stateOf(provisioning: []const u8, statuses: ?[]const RawStatus) types.State {
    var state: types.State = .{ .provisioning = .parse(provisioning) };
    const list = statuses orelse return state;
    for (list) |s| {
        if (std.mem.startsWith(u8, s.code, "ProvisioningState/")) {
            var parts = std.mem.splitScalar(u8, s.code["ProvisioningState/".len..], '/');
            state.provisioning = .parse(parts.first());
            state.failure = parts.rest();
        } else if (std.mem.startsWith(u8, s.code, "PowerState/")) {
            state.power = .parse(s.code["PowerState/".len..]);
        }
    }
    return state;
}

fn tagsOf(a: Allocator, raw: ?std.json.ArrayHashMap([]const u8)) Allocator.Error![]const types.Tag {
    const map = raw orelse return &.{};
    const tags = try a.alloc(types.Tag, map.map.count());
    var it = map.map.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) tags[i] = .{ .name = e.key_ptr.*, .value = e.value_ptr.* };
    return tags;
}

const RawSku = struct {
    resourceType: []const u8 = "",
    name: []const u8 = "",
    locationInfo: []const struct { location: []const u8 = "", zones: []const []const u8 = &.{} } = &.{},
    capabilities: []const struct { name: []const u8 = "", value: []const u8 = "" } = &.{},
    restrictions: []const struct {
        type: []const u8 = "",
        reasonCode: []const u8 = "",
        restrictionInfo: struct { zones: ?[]const []const u8 = null } = .{},
    } = &.{},

    fn capability(r: RawSku, name: []const u8) ?[]const u8 {
        for (r.capabilities) |c| if (std.mem.eql(u8, c.name, name)) return c.value;
        return null;
    }
};

/// A size from its SKU entry, or null for no VM size, or one this
/// subscription may not make in `location` at all.
fn sizeOf(a: Allocator, r: RawSku, location: []const u8) Allocator.Error!?types.Size {
    if (!std.mem.eql(u8, r.resourceType, "virtualMachines")) return null;
    const restricted = try restrictedZones(a, r) orelse return null;
    const zones = try usableZones(a, r, location, restricted);
    return .{
        .name = r.name,
        .vcpus = std.fmt.parseInt(u32, r.capability("vCPUs") orelse "0", 10) catch 0,
        .memory_gb = std.fmt.parseFloat(f64, r.capability("MemoryGB") orelse "0") catch 0,
        .spot = isTrue(r.capability("LowPriorityCapable")),
        .ephemeral_os_disk = isTrue(r.capability("EphemeralOSDiskSupported")),
        .resource_disk_mb = std.fmt.parseInt(u64, r.capability("MaxResourceVolumeMB") orelse "0", 10) catch 0,
        .zones = zones,
    };
}

/// The zones a size's restrictions take away, or null when one takes the
/// whole region.
fn restrictedZones(a: Allocator, r: RawSku) Allocator.Error!?[]const []const u8 {
    var zones: std.ArrayList([]const u8) = .empty;
    for (r.restrictions) |x| {
        if (std.mem.eql(u8, x.type, "Location")) return null;
        if (!std.mem.eql(u8, x.type, "Zone")) continue;
        if (x.restrictionInfo.zones) |zs| try zones.appendSlice(a, zs);
    }
    return zones.items;
}

/// The region's zones for the size, less `restricted`, in order.
fn usableZones(a: Allocator, r: RawSku, location: []const u8, restricted: []const []const u8) Allocator.Error![]const []const u8 {
    var zones: std.ArrayList([]const u8) = .empty;
    for (r.locationInfo) |info| {
        if (!std.ascii.eqlIgnoreCase(info.location, location)) continue;
        for (info.zones) |z| if (!contains(restricted, z)) try zones.append(a, z);
    }
    std.mem.sort([]const u8, zones.items, {}, zoneLess);
    return zones.items;
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, item)) return true;
    return false;
}

fn isTrue(value: ?[]const u8) bool {
    return if (value) |v| std.ascii.eqlIgnoreCase(v, "True") else false;
}

fn zoneLess(_: void, a: []const u8, b: []const u8) bool {
    return if (a.len != b.len) a.len < b.len else std.mem.order(u8, a, b) == .lt;
}

const RawLocation = struct {
    name: []const u8 = "",
    displayName: []const u8 = "",
    availabilityZoneMappings: ?[]const struct { logicalZone: []const u8 = "", physicalZone: []const u8 = "" } = null,
};

const RawUsage = struct {
    currentValue: i64 = 0,
    limit: i64 = 0,
    name: struct { value: []const u8 = "", localizedValue: []const u8 = "" } = .{},
};

/// Every page of a list, its items appended to `out`.
fn allPages(self: *Client, comptime Raw: type, arena: Allocator, first: []const u8, out: *std.ArrayList(Raw)) Error!void {
    const Page = struct { value: []const Raw = &.{}, nextLink: ?[]const u8 = null };
    var path: ?[]const u8 = first;
    var pages: usize = 0;
    while (path) |p| : (pages += 1) {
        if (pages == max_pages) return self.invalidResponse("a list ran past {d} pages", .{max_pages});
        const body = try self.get(arena, p);
        const page = std.json.parseFromSliceLeaky(Page, arena, body, json_options) catch |err| return self.decodeFailed(err, "a page of a list");
        try out.appendSlice(arena, page.value);
        path = core.arm.nextPagePath(self.engine.base_url, page.nextLink) catch {
            if (self.engine.diagnostics) |d| d.print("a list's nextLink is not on {s}", .{self.engine.base_url});
            return error.InvalidEndpoint;
        };
        if (path) |next| if (std.mem.eql(u8, next, p)) return self.invalidResponse("a page names itself as the next", .{});
    }
}

/// A GET's body, copied into `arena`, with a request id of its own.
fn get(self: *Client, arena: Allocator, path: []const u8) Error![]const u8 {
    var response: std.heap.ArenaAllocator = .init(self.gpa);
    defer response.deinit();
    const id = core.arm.clientRequestId(self.io);
    const body = try self.engine.execute(&response, .{
        .method = .GET,
        .path = path,
        .headers = &.{.{ .name = "x-ms-client-request-id", .value = &id }},
    });
    return arena.dupe(u8, body);
}

// Checks.

/// 1 to 64 of letters, digits and `.-_`, beginning with a letter or digit
/// and ending with one or `_`: a Linux VM's name, as it goes in the path.
pub fn isVmName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (!std.ascii.isAlphanumeric(name[0])) return false;
    const last = name[name.len - 1];
    if (!std.ascii.isAlphanumeric(last) and last != '_') return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_')) return false;
    return true;
}

fn checkGroup(self: *Client, subscription: []const u8, group: []const u8) Error!void {
    if (core.names.groupProblem(subscription, group)) |why| return self.refuse("{s}", .{why});
}

fn refuse(self: *Client, comptime fmt: []const u8, args: anytype) error{InvalidArgument} {
    if (self.engine.diagnostics) |d| d.print(fmt, args);
    return error.InvalidArgument;
}

fn invalidResponse(self: *Client, comptime fmt: []const u8, args: anytype) error{InvalidResponse} {
    if (self.engine.diagnostics) |d| d.print(fmt, args);
    return error.InvalidResponse;
}

fn decodeFailed(self: *Client, err: anyerror, comptime what: []const u8) Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return self.invalidResponse(what ++ " is not the JSON ARM sends ({t})", .{err});
}

test {
    std.testing.refAllDecls(@This());
}

test "VM names" {
    const testing = std.testing;
    for ([_][]const u8{ "m0-vm1", "a", "pb_worker.1", "w_" }) |ok| try testing.expect(isVmName(ok));
    for ([_][]const u8{ "", "-a", "a-", "a.", "a b", "a/b", core.testing.repeat("a", 65) }) |bad| try testing.expect(!isVmName(bad));
}
