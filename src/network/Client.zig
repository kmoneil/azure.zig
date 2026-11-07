//! The network client: virtual networks, their subnets, and network
//! security groups, on Azure Resource Manager (Microsoft.Network). Made
//! with `init`, freed with `deinit`; one task uses it at a time.

const Client = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const transport = core.transport;
const types = @import("types.zig");
const validate = @import("validate.zig");

const Engine = core.arm.Engine(.azure_network);
const Operation = core.operation.Operation;

/// The api-version of every call here: Microsoft.Network's newest stable
/// one.
pub const api_version = "2026-03-01";

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
    /// An argument refused before anything is sent: a name Network would
    /// refuse, a range that is not a CIDR, a rule out of bounds.
    /// `Diagnostics` says which.
    InvalidArgument,
    /// An answer that is not the JSON ARM sends. `Diagnostics` says which.
    InvalidResponse,
    /// A write whose answer cannot be followed.
    InvalidOperation,
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

// Virtual networks.

/// Begins making the network, or making one there already exactly the
/// spec, its subnets included, and returns the operation to wait on
/// (`waitOperation`); `getVirtualNetwork` then reads it.
pub fn beginCreateVirtualNetwork(self: *Client, subscription: []const u8, group: []const u8, name: []const u8, spec: types.VirtualNetworkSpec) Error!types.Owned(Operation) {
    self.engine.begin();
    const target: Target = .{ .subscription = subscription, .group = group, .kind = .virtual_network, .name = name };
    try self.check(target);
    try self.checkNetworkSpec(spec);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    return self.beginWrite(target, try jsonBody(scratch.allocator(), spec, writeNetwork));
}

/// One virtual network, with its subnets; `NotFound` when there is none
/// of that name.
pub fn getVirtualNetwork(self: *Client, subscription: []const u8, group: []const u8, name: []const u8) Error!types.Owned(types.VirtualNetwork) {
    return self.read(types.VirtualNetwork, RawNetwork, .{ .subscription = subscription, .group = group, .kind = .virtual_network, .name = name });
}

/// Begins deleting the network and its subnets, and returns the operation
/// to wait on. A network that is not there has nothing to delete: the
/// operation has succeeded already. One with a subnet in use is refused
/// (`InUseSubnetCannotBeDeleted`).
pub fn beginDeleteVirtualNetwork(self: *Client, subscription: []const u8, group: []const u8, name: []const u8) Error!types.Owned(Operation) {
    self.engine.begin();
    const target: Target = .{ .subscription = subscription, .group = group, .kind = .virtual_network, .name = name };
    try self.check(target);
    return self.beginWrite(target, null);
}

// Subnets.

/// Begins making a subnet of `network`, or making one there already
/// exactly the spec, and returns the operation to wait on. A network
/// that is not there is `NotFound`.
pub fn beginCreateSubnet(self: *Client, subscription: []const u8, group: []const u8, network: []const u8, name: []const u8, spec: types.SubnetSpec) Error!types.Owned(Operation) {
    self.engine.begin();
    const target: Target = .{ .subscription = subscription, .group = group, .kind = .subnet, .network = network, .name = name };
    try self.check(target);
    try self.checkSubnetSpec(spec);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    return self.beginWrite(target, try jsonBody(scratch.allocator(), spec, writeSubnet));
}

/// One subnet of `network`; `NotFound` when either is not there.
pub fn getSubnet(self: *Client, subscription: []const u8, group: []const u8, network: []const u8, name: []const u8) Error!types.Owned(types.Subnet) {
    return self.read(types.Subnet, RawSubnet, .{ .subscription = subscription, .group = group, .kind = .subnet, .network = network, .name = name });
}

/// Begins deleting a subnet, and returns the operation to wait on. A
/// subnet that is not there has nothing to delete; one in use is refused
/// (`InUseSubnetCannotBeDeleted`).
pub fn beginDeleteSubnet(self: *Client, subscription: []const u8, group: []const u8, network: []const u8, name: []const u8) Error!types.Owned(Operation) {
    self.engine.begin();
    const target: Target = .{ .subscription = subscription, .group = group, .kind = .subnet, .network = network, .name = name };
    try self.check(target);
    return self.beginWrite(target, null);
}

// Network security groups.

/// Begins making a network security group, or making one there already
/// exactly the spec, its rules included, and returns the operation to
/// wait on.
pub fn beginCreateSecurityGroup(self: *Client, subscription: []const u8, group: []const u8, name: []const u8, spec: types.SecurityGroupSpec) Error!types.Owned(Operation) {
    self.engine.begin();
    const target: Target = .{ .subscription = subscription, .group = group, .kind = .security_group, .name = name };
    try self.check(target);
    try self.checkSecurityGroupSpec(spec);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    return self.beginWrite(target, try jsonBody(scratch.allocator(), spec, writeSecurityGroup));
}

/// One network security group, with its rules and Azure's default ones;
/// `NotFound` when there is none of that name.
pub fn getSecurityGroup(self: *Client, subscription: []const u8, group: []const u8, name: []const u8) Error!types.Owned(types.SecurityGroup) {
    return self.read(types.SecurityGroup, RawSecurityGroup, .{ .subscription = subscription, .group = group, .kind = .security_group, .name = name });
}

/// Begins deleting a network security group, and returns the operation
/// to wait on. One that is not there has nothing to delete; one applied
/// to a subnet or a network interface is refused
/// (`InUseNetworkSecurityGroupCannotBeDeleted`).
pub fn beginDeleteSecurityGroup(self: *Client, subscription: []const u8, group: []const u8, name: []const u8) Error!types.Owned(Operation) {
    self.engine.begin();
    const target: Target = .{ .subscription = subscription, .group = group, .kind = .security_group, .name = name };
    try self.check(target);
    return self.beginWrite(target, null);
}

// Operations.

/// Polls `operation` until it ends or `timeout_ms` passes, and leaves it as
/// it then stands; a failed one is an answer, in its `state`, with ARM's
/// code and message in `failure_code` and `failure_message`.
pub fn waitOperation(self: *Client, operation: *types.Owned(Operation), timeout_ms: u32) Error!void {
    self.engine.begin();
    core.operation.wait(self.engine, operation.arena.allocator(), &operation.value, timeout_ms) catch |err| return operationError(err);
}

// What the calls share.

/// The resource a call names.
const Target = struct {
    subscription: []const u8,
    group: []const u8,
    kind: Kind,
    name: []const u8,
    /// A subnet's virtual network.
    network: []const u8 = "",

    const Kind = enum { virtual_network, subnet, security_group };

    fn path(t: Target, arena: Allocator) Allocator.Error![]const u8 {
        const base = "/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.Network/";
        const query = "?api-version=" ++ api_version;
        return switch (t.kind) {
            .virtual_network => std.fmt.allocPrint(arena, base ++ "virtualNetworks/{s}" ++ query, .{ t.subscription, t.group, t.name }),
            .subnet => std.fmt.allocPrint(arena, base ++ "virtualNetworks/{s}/subnets/{s}" ++ query, .{ t.subscription, t.group, t.network, t.name }),
            .security_group => std.fmt.allocPrint(arena, base ++ "networkSecurityGroups/{s}" ++ query, .{ t.subscription, t.group, t.name }),
        };
    }
};

const network_name_rule = "a virtual network's name is 2 to 64 of letters, digits and .-_, beginning with a letter or digit and ending with one or _";
const subnet_name_rule = "a subnet's name is 1 to 80 of letters, digits and .-_, beginning with a letter or digit and ending with one or _";
const security_group_name_rule = "a network security group's name is 1 to 80 of letters, digits and .-_, beginning with a letter or digit and ending with one or _";
const rule_name_rule = "a security rule's name is 1 to 80 of letters, digits and .-_, beginning with a letter or digit and ending with one or _";

/// The target's names, each checked by its rule: each goes into the path.
fn check(self: *Client, t: Target) Error!void {
    if (core.names.groupProblem(t.subscription, t.group)) |why| return self.refuse("{s}", .{why});
    switch (t.kind) {
        .virtual_network => if (!validate.isNetworkName(t.name)) return self.refuse(network_name_rule, .{}),
        .subnet => {
            if (!validate.isNetworkName(t.network)) return self.refuse(network_name_rule, .{});
            if (!validate.isChildName(t.name)) return self.refuse(subnet_name_rule, .{});
        },
        .security_group => if (!validate.isChildName(t.name)) return self.refuse(security_group_name_rule, .{}),
    }
}

fn checkNetworkSpec(self: *Client, spec: types.VirtualNetworkSpec) Error!void {
    if (!validate.isLocation(spec.location)) return self.refuse("a location is letters and digits, as eastus2", .{});
    if (core.names.tagsProblem(spec.tags)) |why| return self.refuse("{s}", .{why});
    if (spec.address_prefixes.len == 0) return self.refuse("a virtual network needs one address range at least", .{});
    for (spec.address_prefixes) |p| {
        if (!validate.isCidr(p)) return self.refuse("a virtual network's range is a CIDR with no host bits set, as 10.0.0.0/16: {s}", .{p});
    }
    for (spec.subnets, 0..) |s, i| {
        if (!validate.isChildName(s.name)) return self.refuse(subnet_name_rule, .{});
        for (spec.subnets[0..i]) |earlier| {
            if (std.ascii.eqlIgnoreCase(earlier.name, s.name)) return self.refuse("two subnets named {s}: Network's names ignore case", .{s.name});
        }
        try self.checkSubnetSpec(s.spec);
    }
}

fn checkSubnetSpec(self: *Client, spec: types.SubnetSpec) Error!void {
    if (!validate.isCidr(spec.address_prefix)) {
        return self.refuse("a subnet's range is a CIDR with no host bits set, as 10.0.1.0/24: {s}", .{spec.address_prefix});
    }
    for (spec.service_endpoints) |e| {
        if (!validate.isService(e)) return self.refuse("a service endpoint is a service's name, as Microsoft.Storage", .{});
    }
    if (spec.security_group) |id| if (!validate.isNetworkId(id, "networkSecurityGroups")) {
        return self.refuse("security_group is a network security group's ARM id (ids.securityGroup), not its name", .{});
    };
    if (spec.nat_gateway) |id| if (!validate.isNetworkId(id, "natGateways")) {
        return self.refuse("nat_gateway is a NAT gateway's ARM id (ids.natGateway), not its name", .{});
    };
}

fn checkSecurityGroupSpec(self: *Client, spec: types.SecurityGroupSpec) Error!void {
    if (!validate.isLocation(spec.location)) return self.refuse("a location is letters and digits, as eastus2", .{});
    if (core.names.tagsProblem(spec.tags)) |why| return self.refuse("{s}", .{why});
    for (spec.rules, 0..) |r, i| {
        try self.checkRule(r);
        for (spec.rules[0..i]) |earlier| {
            if (std.ascii.eqlIgnoreCase(earlier.name, r.name)) return self.refuse("two rules named {s}: Network's names ignore case", .{r.name});
            if (earlier.direction == r.direction and earlier.priority == r.priority) {
                return self.refuse("rules {s} and {s} share priority {d} in one direction", .{ earlier.name, r.name, r.priority });
            }
        }
    }
}

fn checkRule(self: *Client, r: types.SecurityRule) Error!void {
    if (!validate.isChildName(r.name)) return self.refuse(rule_name_rule, .{});
    if (r.priority < 100 or r.priority > 4096) return self.refuse("rule {s}: a priority is 100 to 4096", .{r.name});
    if (r.direction == .unknown or r.access == .unknown or r.protocol == .unknown) {
        return self.refuse("rule {s}: its direction, access and protocol are known ones", .{r.name});
    }
    if (!allOf(r.source_address_prefixes, validate.isAddressPrefix) or !allOf(r.destination_address_prefixes, validate.isAddressPrefix)) {
        return self.refuse("rule {s}: an address is *, an address or CIDR, or a service tag, one at least each way", .{r.name});
    }
    if (!allOf(r.source_port_ranges, validate.isPortRange) or !allOf(r.destination_port_ranges, validate.isPortRange)) {
        return self.refuse("rule {s}: a port is *, 0 to 65535, or low-high, one at least each way", .{r.name});
    }
    if (!validate.isDescription(r.description)) return self.refuse("rule {s}: a description is up to 140 bytes, no control bytes", .{r.name});
}

/// Whether `values` has one at least, and `ok` takes every one.
fn allOf(values: []const []const u8, comptime ok: fn ([]const u8) bool) bool {
    if (values.len == 0) return false;
    for (values) |v| if (!ok(v)) return false;
    return true;
}

/// Sends a PUT of `body`, or a DELETE when it is null, and returns how the
/// operation stands.
fn beginWrite(self: *Client, target: Target, body: ?[]const u8) Error!types.Owned(Operation) {
    var out: types.Owned(Operation) = try .init(self.gpa);
    errdefer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const id = core.arm.clientRequestId(self.io);
    const headers = [_]transport.Header{.{ .name = "x-ms-client-request-id", .value = &id }};
    const segments = [_][]const u8{body orelse ""};
    out.value = core.operation.begin(self.engine, out.arena.allocator(), .{
        .method = if (body != null) .PUT else .DELETE,
        .path = try target.path(scratch.allocator()),
        .content_type = if (body != null) "application/json" else null,
        .headers = &headers,
        .body = if (body != null) .{ .segments = &segments } else .none,
    }, .{}) catch |err| return operationError(err);
    return out;
}

/// A GET of the target, decoded through `Raw` into a `T`.
fn read(self: *Client, comptime T: type, comptime Raw: type, target: Target) Error!types.Owned(T) {
    self.engine.begin();
    try self.check(target);
    var out: types.Owned(T) = try .init(self.gpa);
    errdefer out.deinit();
    const a = out.arena.allocator();
    var response: std.heap.ArenaAllocator = .init(self.gpa);
    defer response.deinit();
    const id = core.arm.clientRequestId(self.io);
    const body = try self.engine.execute(&response, .{
        .method = .GET,
        .path = try target.path(a),
        .headers = &.{.{ .name = "x-ms-client-request-id", .value = &id }},
    });
    const raw = std.json.parseFromSliceLeaky(Raw, a, body, json_options) catch |err| return self.decodeFailed(err, Raw.what);
    out.value = try raw.view(a);
    return out;
}

// Request bodies.

fn jsonBody(arena: Allocator, spec: anytype, comptime write: fn (*std.json.Stringify, @TypeOf(spec)) std.json.Stringify.Error!void) Allocator.Error![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &w.writer };
    write(&jw, spec) catch return error.OutOfMemory;
    return w.written();
}

/// `{"location","tags","properties":{"addressSpace","subnets"}}`. The tags
/// and the subnets are always sent, since a PUT replaces both.
fn writeNetwork(jw: *std.json.Stringify, spec: types.VirtualNetworkSpec) std.json.Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("location");
    try jw.write(spec.location);
    try writeTags(jw, spec.tags);
    try jw.objectField("properties");
    try jw.beginObject();
    try jw.objectField("addressSpace");
    try jw.write(.{ .addressPrefixes = spec.address_prefixes });
    try jw.objectField("subnets");
    try jw.beginArray();
    for (spec.subnets) |s| {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(s.name);
        try jw.objectField("properties");
        try writeSubnetProperties(jw, s.spec);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
    try jw.endObject();
}

fn writeSubnet(jw: *std.json.Stringify, spec: types.SubnetSpec) std.json.Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("properties");
    try writeSubnetProperties(jw, spec);
    try jw.endObject();
}

/// `defaultOutboundAccess` and the service endpoints are always sent: the
/// one's default depends on the api-version, and a PUT replaces the other.
fn writeSubnetProperties(jw: *std.json.Stringify, spec: types.SubnetSpec) std.json.Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("addressPrefix");
    try jw.write(spec.address_prefix);
    try jw.objectField("defaultOutboundAccess");
    try jw.write(spec.default_outbound_access);
    try jw.objectField("serviceEndpoints");
    try jw.beginArray();
    for (spec.service_endpoints) |e| try jw.write(.{ .service = e });
    try jw.endArray();
    if (spec.security_group) |id| {
        try jw.objectField("networkSecurityGroup");
        try jw.write(.{ .id = id });
    }
    if (spec.nat_gateway) |id| {
        try jw.objectField("natGateway");
        try jw.write(.{ .id = id });
    }
    try jw.endObject();
}

/// `{"location","tags","properties":{"securityRules"}}`, the rules always
/// sent, since a PUT replaces them.
fn writeSecurityGroup(jw: *std.json.Stringify, spec: types.SecurityGroupSpec) std.json.Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("location");
    try jw.write(spec.location);
    try writeTags(jw, spec.tags);
    try jw.objectField("properties");
    try jw.beginObject();
    try jw.objectField("securityRules");
    try jw.beginArray();
    for (spec.rules) |r| try writeRule(jw, r);
    try jw.endArray();
    try jw.endObject();
    try jw.endObject();
}

fn writeRule(jw: *std.json.Stringify, r: types.SecurityRule) std.json.Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(r.name);
    try jw.objectField("properties");
    try jw.beginObject();
    try jw.objectField("priority");
    try jw.write(r.priority);
    try jw.objectField("direction");
    try jw.write(r.direction.wire());
    try jw.objectField("access");
    try jw.write(r.access.wire());
    try jw.objectField("protocol");
    try jw.write(r.protocol.wire());
    try writeOneOrMany(jw, "sourceAddressPrefix", "sourceAddressPrefixes", r.source_address_prefixes);
    try writeOneOrMany(jw, "sourcePortRange", "sourcePortRanges", r.source_port_ranges);
    try writeOneOrMany(jw, "destinationAddressPrefix", "destinationAddressPrefixes", r.destination_address_prefixes);
    try writeOneOrMany(jw, "destinationPortRange", "destinationPortRanges", r.destination_port_ranges);
    if (r.description.len > 0) {
        try jw.objectField("description");
        try jw.write(r.description);
    }
    try jw.endObject();
    try jw.endObject();
}

/// One value under Network's singular field, more under its plural one:
/// never both, which Network refuses.
fn writeOneOrMany(jw: *std.json.Stringify, comptime one: []const u8, comptime many: []const u8, values: []const []const u8) std.json.Stringify.Error!void {
    if (values.len == 1) {
        try jw.objectField(one);
        try jw.write(values[0]);
    } else {
        try jw.objectField(many);
        try jw.write(values);
    }
}

fn writeTags(jw: *std.json.Stringify, tags: []const types.Tag) std.json.Stringify.Error!void {
    try jw.objectField("tags");
    try jw.beginObject();
    for (tags) |t| {
        try jw.objectField(t.name);
        try jw.write(t.value);
    }
    try jw.endObject();
}

// Response bodies, read leniently: a field ARM leaves out or sends as null
// reads as empty.

const json_options: std.json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };

const RawRef = struct { id: []const u8 = "" };

const RawTags = ?std.json.ArrayHashMap([]const u8);

fn tagsOf(arena: Allocator, raw: RawTags) Allocator.Error![]const types.Tag {
    const m = raw orelse return &.{};
    const tags = try arena.alloc(types.Tag, m.map.count());
    for (m.map.keys(), m.map.values(), tags) |k, v, *t| t.* = .{ .name = k, .value = v };
    return tags;
}

/// Network's singular field and its plural one, as one list.
fn oneAndMany(arena: Allocator, one: ?[]const u8, many: ?[]const []const u8) Allocator.Error![]const []const u8 {
    const rest = many orelse &.{};
    const first = one orelse return rest;
    if (first.len == 0) return rest;
    const all = try arena.alloc([]const u8, rest.len + 1);
    all[0] = first;
    @memcpy(all[1..], rest);
    return all;
}

const RawEndpoint = struct {
    service: []const u8 = "",
    locations: ?[]const []const u8 = null,
    provisioningState: []const u8 = "",
};

const RawSubnet = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    properties: ?Properties = null,

    const Properties = struct {
        addressPrefix: ?[]const u8 = null,
        addressPrefixes: ?[]const []const u8 = null,
        provisioningState: []const u8 = "",
        defaultOutboundAccess: ?bool = null,
        serviceEndpoints: ?[]const RawEndpoint = null,
        networkSecurityGroup: ?RawRef = null,
        natGateway: ?RawRef = null,
        ipConfigurations: ?[]const RawRef = null,
    };

    const what = "a subnet";

    fn view(raw: RawSubnet, arena: Allocator) Allocator.Error!types.Subnet {
        const p: Properties = raw.properties orelse .{};
        const raw_endpoints = p.serviceEndpoints orelse &.{};
        const endpoints = try arena.alloc(types.ServiceEndpoint, raw_endpoints.len);
        for (raw_endpoints, endpoints) |r, *e| e.* = .{
            .service = r.service,
            .locations = r.locations orelse &.{},
            .provisioning_state = r.provisioningState,
        };
        return .{
            .name = raw.name,
            .id = raw.id,
            .address_prefixes = try oneAndMany(arena, p.addressPrefix, p.addressPrefixes),
            .provisioning_state = p.provisioningState,
            .default_outbound_access = p.defaultOutboundAccess,
            .service_endpoints = endpoints,
            .security_group = if (p.networkSecurityGroup) |r| r.id else null,
            .nat_gateway = if (p.natGateway) |r| r.id else null,
            .ip_configurations = if (p.ipConfigurations) |c| c.len else 0,
        };
    }
};

const RawNetwork = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    location: []const u8 = "",
    tags: RawTags = null,
    properties: ?Properties = null,

    const Properties = struct {
        provisioningState: []const u8 = "",
        addressSpace: ?struct { addressPrefixes: ?[]const []const u8 = null } = null,
        subnets: ?[]const RawSubnet = null,
    };

    const what = "a virtual network";

    fn view(raw: RawNetwork, arena: Allocator) Allocator.Error!types.VirtualNetwork {
        const p: Properties = raw.properties orelse .{};
        const raw_subnets = p.subnets orelse &.{};
        const subnets = try arena.alloc(types.Subnet, raw_subnets.len);
        for (raw_subnets, subnets) |r, *s| s.* = try r.view(arena);
        return .{
            .name = raw.name,
            .id = raw.id,
            .location = raw.location,
            .provisioning_state = p.provisioningState,
            .address_prefixes = if (p.addressSpace) |space| space.addressPrefixes orelse &.{} else &.{},
            .subnets = subnets,
            .tags = try tagsOf(arena, raw.tags),
        };
    }
};

const RawRule = struct {
    name: []const u8 = "",
    properties: ?Properties = null,

    const Properties = struct {
        priority: u16 = 0,
        direction: []const u8 = "",
        access: []const u8 = "",
        protocol: []const u8 = "",
        sourceAddressPrefix: ?[]const u8 = null,
        sourceAddressPrefixes: ?[]const []const u8 = null,
        sourcePortRange: ?[]const u8 = null,
        sourcePortRanges: ?[]const []const u8 = null,
        destinationAddressPrefix: ?[]const u8 = null,
        destinationAddressPrefixes: ?[]const []const u8 = null,
        destinationPortRange: ?[]const u8 = null,
        destinationPortRanges: ?[]const []const u8 = null,
        description: ?[]const u8 = null,
    };

    fn view(raw: RawRule, arena: Allocator) Allocator.Error!types.SecurityRule {
        const p: Properties = raw.properties orelse .{};
        return .{
            .name = raw.name,
            .priority = p.priority,
            .direction = .parse(p.direction),
            .access = .parse(p.access),
            .protocol = .parse(p.protocol),
            .source_address_prefixes = try oneAndMany(arena, p.sourceAddressPrefix, p.sourceAddressPrefixes),
            .source_port_ranges = try oneAndMany(arena, p.sourcePortRange, p.sourcePortRanges),
            .destination_address_prefixes = try oneAndMany(arena, p.destinationAddressPrefix, p.destinationAddressPrefixes),
            .destination_port_ranges = try oneAndMany(arena, p.destinationPortRange, p.destinationPortRanges),
            .description = p.description orelse "",
        };
    }

    fn views(arena: Allocator, raw: ?[]const RawRule) Allocator.Error![]const types.SecurityRule {
        const items = raw orelse &.{};
        const rules = try arena.alloc(types.SecurityRule, items.len);
        for (items, rules) |r, *out| out.* = try r.view(arena);
        return rules;
    }
};

const RawSecurityGroup = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    location: []const u8 = "",
    tags: RawTags = null,
    properties: ?Properties = null,

    const Properties = struct {
        provisioningState: []const u8 = "",
        securityRules: ?[]const RawRule = null,
        defaultSecurityRules: ?[]const RawRule = null,
        subnets: ?[]const RawRef = null,
    };

    const what = "a network security group";

    fn view(raw: RawSecurityGroup, arena: Allocator) Allocator.Error!types.SecurityGroup {
        const p: Properties = raw.properties orelse .{};
        const raw_subnets = p.subnets orelse &.{};
        const subnets = try arena.alloc([]const u8, raw_subnets.len);
        for (raw_subnets, subnets) |r, *s| s.* = r.id;
        return .{
            .name = raw.name,
            .id = raw.id,
            .location = raw.location,
            .provisioning_state = p.provisioningState,
            .rules = try RawRule.views(arena, p.securityRules),
            .default_rules = try RawRule.views(arena, p.defaultSecurityRules),
            .subnets = subnets,
            .tags = try tagsOf(arena, raw.tags),
        };
    }
};

// Failures.

fn refuse(self: *Client, comptime fmt: []const u8, args: anytype) error{InvalidArgument} {
    if (self.engine.diagnostics) |d| d.print(fmt, args);
    return error.InvalidArgument;
}

fn decodeFailed(self: *Client, err: anyerror, comptime what: []const u8) Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (self.engine.diagnostics) |d| d.print(what ++ " is not the JSON ARM sends ({t})", .{err});
    return error.InvalidResponse;
}

fn operationError(err: core.operation.Error(Engine)) Error {
    return switch (err) {
        error.WriteFailed => unreachable,
        else => |e| e,
    };
}
