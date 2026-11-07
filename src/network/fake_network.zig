//! Microsoft.Network in memory, for code that uses the network module:
//! virtual networks with their subnets, and network security groups, in
//! resource groups a test adds, behind `Client.Options.transport`. Paths
//! and names match without regard to case, as ARM's do.
//!
//! Every write is a long-running operation followed through
//! `Azure-AsyncOperation`, which answers `InProgress` for
//! `operation_polls` polls before it ends; until then the resource reads
//! `Updating`, or `Deleting`. A delete of what is not there answers 204,
//! but a subnet's whose network is not there 404, as any call under it.
//! What Network refuses, the fake refuses with Network's codes: a subnet
//! outside its network's ranges or overlapping another, a subnet in use
//! deleted, a security group in use deleted, a reference to a resource not
//! there, a resource made again in another location. The codes and
//! statuses are Network's as the live suite found them on 2026-11-07, and
//! the shapes as its spec and examples give them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const wire = core.transport;
const Header = wire.Header;
const validate = @import("validate.zig");

const api_version = "2026-03-01";

pub const FakeNetwork = struct {
    arena: std.heap.ArenaAllocator,
    /// The ARM endpoint the fake answers as, and writes into its operation
    /// URLs: the client's own (`Client.Options.endpoint`, or the public
    /// cloud's).
    base_url: []const u8 = core.Cloud.public.arm_endpoint,
    /// Polls of an operation answered `InProgress` before it ends.
    operation_polls: u32 = 1,
    /// What every running operation asks in `Retry-After`, in seconds.
    retry_after: []const u8 = "10",
    /// False: the subscription has not registered Microsoft.Network, and
    /// every call is refused as ARM refuses it.
    registered: bool = true,
    groups: std.ArrayList(Group) = .empty,
    /// The ARM ids of NAT gateways a subnet may name (`addNatGateway`).
    nat_gateways: std.ArrayList([]const u8) = .empty,
    operations: std.ArrayList(Pending) = .empty,
    /// Every request, in order: its method, URL and body.
    calls: std.ArrayList(Call) = .empty,
    next_id: u32 = 1,
    next_failure: ?Failure = null,

    pub const Call = struct { method: wire.Method, url: []const u8, body: []const u8 };
    pub const Tag = core.arm.Tag;

    pub const Group = struct {
        subscription: []const u8,
        name: []const u8,
        networks: std.ArrayList(Network) = .empty,
        security_groups: std.ArrayList(SecurityGroup) = .empty,
    };

    pub const Network = struct {
        name: []const u8,
        location: []const u8,
        prefixes: []const []const u8,
        tags: []const Tag,
        subnets: std.ArrayList(Subnet) = .empty,
        state: []const u8 = "Succeeded",

        pub fn subnet(network: *Network, name: []const u8) ?*Subnet {
            return findIn(Subnet, network.subnets.items, name);
        }
    };

    pub const Subnet = struct {
        name: []const u8,
        prefix: []const u8,
        /// Null when the create said nothing of it.
        default_outbound_access: ?bool = null,
        endpoints: []const []const u8 = &.{},
        security_group: ?[]const u8 = null,
        nat_gateway: ?[]const u8 = null,
        /// Network interfaces' IP configurations in it (`useSubnet`).
        in_use: u32 = 0,
        state: []const u8 = "Succeeded",
    };

    pub const SecurityGroup = struct {
        name: []const u8,
        location: []const u8,
        tags: []const Tag,
        /// The rules as the latest create sent them, each its JSON object.
        rules: []const std.json.Value,
        state: []const u8 = "Succeeded",
    };

    const Failure = struct { code: []const u8, message: []const u8 };

    /// The resource an operation acts on.
    const Target = struct {
        subscription: []const u8,
        group: []const u8,
        kind: enum { network, subnet, security_group },
        name: []const u8,
        network: []const u8 = "",
    };

    const Pending = struct {
        id: []const u8,
        target: Target,
        delete: bool,
        polls_left: u32,
        failure: ?Failure,
        done: bool = false,
    };

    pub fn init(gpa: Allocator) FakeNetwork {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *FakeNetwork) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// A resource group the calls may name; any other is
    /// `ResourceGroupNotFound`.
    pub fn addGroup(self: *FakeNetwork, subscription: []const u8, name: []const u8) Allocator.Error!void {
        const a = self.arena.allocator();
        try self.groups.append(a, .{ .subscription = try a.dupe(u8, subscription), .name = try a.dupe(u8, name) });
    }

    /// A NAT gateway a subnet may name, which the fake does not otherwise
    /// hold.
    pub fn addNatGateway(self: *FakeNetwork, subscription: []const u8, group: []const u8, name: []const u8) Allocator.Error!void {
        const a = self.arena.allocator();
        try self.nat_gateways.append(a, try std.fmt.allocPrint(a, "/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.Network/natGateways/{s}", .{ subscription, group, name }));
    }

    /// Puts a network interface's IP configuration in the subnet, as a VM
    /// made there would: the subnet is in use, and cannot be deleted.
    pub fn useSubnet(self: *FakeNetwork, subscription: []const u8, group: []const u8, network: []const u8, name: []const u8) error{NoSuchSubnet}!void {
        const n = self.findNetwork(subscription, group, network) orelse return error.NoSuchSubnet;
        const s = n.subnet(name) orelse return error.NoSuchSubnet;
        s.in_use += 1;
    }

    /// Makes the next create's operation end `Failed` with ARM's `code`
    /// and `message`, and its resource read `Failed`.
    pub fn failNextWrite(self: *FakeNetwork, code: []const u8, message: []const u8) Allocator.Error!void {
        const a = self.arena.allocator();
        self.next_failure = .{ .code = try a.dupe(u8, code), .message = try a.dupe(u8, message) };
    }

    pub fn findGroup(self: *FakeNetwork, subscription: []const u8, name: []const u8) ?*Group {
        for (self.groups.items) |*g| if (eql(g.subscription, subscription) and eql(g.name, name)) return g;
        return null;
    }

    /// The network as the fake holds it now, or null.
    pub fn findNetwork(self: *FakeNetwork, subscription: []const u8, group: []const u8, name: []const u8) ?*Network {
        const g = self.findGroup(subscription, group) orelse return null;
        return findIn(Network, g.networks.items, name);
    }

    /// The security group as the fake holds it now, or null.
    pub fn findSecurityGroup(self: *FakeNetwork, subscription: []const u8, group: []const u8, name: []const u8) ?*SecurityGroup {
        const g = self.findGroup(subscription, group) orelse return null;
        return findIn(SecurityGroup, g.security_groups.items, name);
    }

    pub fn transport(self: *FakeNetwork) wire.Transport {
        return .{ .ptr = self, .vtable = &.{ .send = send, .sendStream = sendStream } };
    }

    fn findIn(comptime T: type, items: []T, name: []const u8) ?*T {
        for (items) |*item| if (eql(item.name, name)) return item;
        return null;
    }

    // The wire.

    const Answer = struct {
        status: u16 = 200,
        body: []const u8 = "",
        headers: []const Header = &.{},
    };

    fn send(ptr: *anyopaque, req: wire.Request, arena: Allocator) wire.Error!wire.Response {
        const self: *FakeNetwork = @ptrCast(@alignCast(ptr));
        const got = try self.answer(arena, req.method, req.url, req.body, req.bearer);
        return .{ .status = got.status, .body = got.body, .headers = got.headers };
    }

    fn sendStream(ptr: *anyopaque, req: wire.StreamRequest, arena: Allocator) wire.StreamError!wire.StreamResponse {
        const self: *FakeNetwork = @ptrCast(@alignCast(ptr));
        const body: ?[]const u8 = switch (req.body) {
            .none => null,
            .segments => |segments| try std.mem.concat(arena, u8, segments),
            // Nothing in the network module streams a body.
            .stream => return error.HttpProtocolError,
        };
        const got = try self.answer(arena, req.method, req.url, body, req.bearer);
        if (req.head_out) |out| out.* = .{ .status = got.status, .headers = got.headers };
        if (got.status < 300 and req.sink == .writer) {
            req.sink.writer.writeAll(got.body) catch return error.WriteFailed;
            return .{ .status = got.status, .headers = got.headers, .bytes_streamed = got.body.len };
        }
        return .{ .status = got.status, .headers = got.headers, .body = got.body };
    }

    fn answer(self: *FakeNetwork, arena: Allocator, method: wire.Method, url: []const u8, body: ?[]const u8, bearer: ?[]const u8) Allocator.Error!Answer {
        const a = self.arena.allocator();
        try self.calls.append(a, .{ .method = method, .url = try a.dupe(u8, url), .body = try a.dupe(u8, body orelse "") });
        if (bearer == null) return refusal(arena, 401, "AuthenticationFailed", "Authentication failed. The 'Authorization' header is missing.");
        if (!std.mem.startsWith(u8, url, self.base_url)) return refusal(arena, 400, "InvalidRequestUri", "The request URI is not this ARM's.");
        const rest = url[self.base_url.len..];
        const q = std.mem.indexOfScalar(u8, rest, '?');
        const path = rest[0 .. q orelse rest.len];
        const query = if (q) |i| rest[i + 1 ..] else "";
        if (try param(arena, query, "api-version") == null) {
            return refusal(arena, 400, "MissingApiVersionParameter", "The api-version query parameter (?api-version=) is required for all requests.");
        }
        if (!self.registered) {
            return refusal(arena, 409, "MissingSubscriptionRegistration", "The subscription is not registered to use namespace 'Microsoft.Network'. See https://aka.ms/rps-not-found for how to register subscriptions.");
        }
        var segments: [12][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |s| : (count += 1) {
            if (count == segments.len) return notFound(arena);
            segments[count] = s;
        }
        return self.route(arena, method, segments[0..count], body orelse "");
    }

    fn route(self: *FakeNetwork, arena: Allocator, method: wire.Method, s: []const []const u8, body: []const u8) Allocator.Error!Answer {
        if (s.len < 8 or !eql(s[0], "subscriptions")) return notFound(arena);
        const network_ns = eql(s[2], "providers") and eql(s[3], "Microsoft.Network") and eql(s[4], "locations");
        if (s.len == 8 and network_ns and method == .GET) {
            if (eql(s[6], "operations")) return self.pollOperation(arena, s[7]);
            if (eql(s[6], "operationResults")) return self.operationResult(arena, s[7]);
        }
        if (!eql(s[2], "resourceGroups") or !eql(s[4], "providers") or !eql(s[5], "Microsoft.Network")) return notFound(arena);
        const group = self.findGroup(s[1], s[3]) orelse
            return refusal(arena, 404, "ResourceGroupNotFound", try std.fmt.allocPrint(arena, "Resource group '{s}' could not be found.", .{s[3]}));
        if (s.len == 8 and eql(s[6], "virtualNetworks")) return self.networkCall(arena, group, method, s[7], body);
        if (s.len == 10 and eql(s[6], "virtualNetworks") and eql(s[8], "subnets")) return self.subnetCall(arena, group, method, s[7], s[9], body);
        if (s.len == 8 and eql(s[6], "networkSecurityGroups")) return self.securityGroupCall(arena, group, method, s[7], body);
        return notFound(arena);
    }

    // Virtual networks.

    const RefBody = struct { id: []const u8 = "" };

    const SubnetProps = struct {
        addressPrefix: ?[]const u8 = null,
        defaultOutboundAccess: ?bool = null,
        serviceEndpoints: ?[]const struct { service: []const u8 = "" } = null,
        networkSecurityGroup: ?RefBody = null,
        natGateway: ?RefBody = null,
    };

    const SubnetBody = struct { name: ?[]const u8 = null, properties: ?SubnetProps = null };

    const NetworkProps = struct {
        addressSpace: ?struct { addressPrefixes: ?[]const []const u8 = null } = null,
        subnets: ?[]const SubnetBody = null,
    };

    const NetworkBody = struct {
        location: ?[]const u8 = null,
        tags: ?std.json.ArrayHashMap([]const u8) = null,
        properties: ?NetworkProps = null,
    };

    fn networkCall(self: *FakeNetwork, arena: Allocator, group: *Group, method: wire.Method, name: []const u8, body: []const u8) Allocator.Error!Answer {
        return switch (method) {
            .PUT => self.putNetwork(arena, group, name, body),
            .GET => if (findIn(Network, group.networks.items, name)) |n|
                .{ .body = try jsonWith(arena, self, group, n.*, writeNetwork) }
            else
                resourceNotFound(arena, "virtualNetworks", name, group.name),
            .DELETE => self.deleteNetwork(arena, group, name),
            else => notFound(arena),
        };
    }

    fn putNetwork(self: *FakeNetwork, arena: Allocator, group: *Group, name: []const u8, body: []const u8) Allocator.Error!Answer {
        const a = self.arena.allocator();
        const spec = parse(NetworkBody, a, body) orelse return badBody(arena, "the body is not a virtual network");
        const location = spec.location orelse return refusal(arena, 400, "LocationRequired", "The location property is required for this definition.");
        const props: NetworkProps = spec.properties orelse .{};
        const prefixes: []const []const u8 = if (props.addressSpace) |space| space.addressPrefixes orelse &.{} else &.{};
        if (prefixes.len == 0) return badBody(arena, "addressSpace.addressPrefixes is required");
        for (prefixes) |p| if (!validate.isCidr(p)) return invalidCidr(arena, p);
        const existing = findIn(Network, group.networks.items, name);
        if (existing) |n| if (!eql(n.location, location)) return wrongLocation(arena, name, n.location, group.name, location);

        var subnets: std.ArrayList(Subnet) = .empty;
        if (try self.subnetsFrom(arena, name, prefixes, props.subnets orelse &.{}, &subnets)) |r| return r;
        if (existing) |n| if (try carryOver(arena, n.subnets.items, subnets.items)) |r| return r;
        const network: Network = .{
            .name = if (existing) |n| n.name else try a.dupe(u8, name),
            .location = location,
            .prefixes = prefixes,
            .tags = try tagsOf(a, spec.tags),
            .subnets = subnets,
            .state = "Updating",
        };
        if (existing) |n| n.* = network else try group.networks.append(a, network);
        const stored = findIn(Network, group.networks.items, name).?;
        return self.started(arena, if (existing != null) 200 else 201, .{
            .subscription = group.subscription,
            .group = group.name,
            .kind = .network,
            .name = stored.name,
        }, try jsonWith(arena, self, group, stored.*, writeNetwork));
    }

    /// The subnets a network's create describes, into `out`, or Network's
    /// refusal of one.
    fn subnetsFrom(self: *FakeNetwork, arena: Allocator, network: []const u8, prefixes: []const []const u8, bodies: []const SubnetBody, out: *std.ArrayList(Subnet)) Allocator.Error!?Answer {
        for (bodies) |sb| {
            const subnet_name = sb.name orelse return try badBody(arena, "a subnet has no name");
            const subnet = switch (try self.subnetFrom(arena, subnet_name, sb.properties orelse .{})) {
                .ok => |s| s,
                .refused => |r| return r,
            };
            if (try rangeProblem(arena, network, prefixes, out.items, subnet)) |r| return r;
            try out.append(self.arena.allocator(), subnet);
        }
        return null;
    }

    /// What the old subnets kept by a create keep: their names' casing and
    /// what uses them. One left out while in use is Network's refusal.
    fn carryOver(arena: Allocator, old: []const Subnet, new: []Subnet) Allocator.Error!?Answer {
        for (old) |o| {
            const kept = findIn(Subnet, new, o.name) orelse {
                if (o.in_use > 0) return try inUseSubnet(arena, o.name);
                continue;
            };
            kept.name = o.name;
            kept.in_use = o.in_use;
        }
        return null;
    }

    fn deleteNetwork(self: *FakeNetwork, arena: Allocator, group: *Group, name: []const u8) Allocator.Error!Answer {
        const n = findIn(Network, group.networks.items, name) orelse return .{ .status = 204 };
        for (n.subnets.items) |s| if (s.in_use > 0) return inUseSubnet(arena, s.name);
        n.state = "Deleting";
        return self.started(arena, 202, .{ .subscription = group.subscription, .group = group.name, .kind = .network, .name = n.name }, "");
    }

    // Subnets.

    const Checked = union(enum) { ok: Subnet, refused: Answer };

    /// The subnet a create describes, its strings in the fake's arena, or
    /// Network's refusal of it.
    fn subnetFrom(self: *FakeNetwork, arena: Allocator, name: []const u8, props: SubnetProps) Allocator.Error!Checked {
        const a = self.arena.allocator();
        const prefix = props.addressPrefix orelse return .{ .refused = try badBody(arena, "a subnet has no addressPrefix") };
        if (!validate.isCidr(prefix)) return .{ .refused = try invalidCidr(arena, prefix) };
        if (props.networkSecurityGroup) |ref| if (self.securityGroupById(ref.id) == null) {
            return .{ .refused = try missingReference(arena, ref.id, name) };
        };
        if (props.natGateway) |ref| if (!self.natGatewayKnown(ref.id)) {
            return .{ .refused = try missingReference(arena, ref.id, name) };
        };
        const raw_endpoints = props.serviceEndpoints orelse &.{};
        const endpoints = try a.alloc([]const u8, raw_endpoints.len);
        for (raw_endpoints, endpoints) |e, *out| out.* = e.service;
        return .{ .ok = .{
            .name = try a.dupe(u8, name),
            .prefix = prefix,
            .default_outbound_access = props.defaultOutboundAccess,
            .endpoints = endpoints,
            .security_group = if (props.networkSecurityGroup) |r| r.id else null,
            .nat_gateway = if (props.natGateway) |r| r.id else null,
            .state = "Updating",
        } };
    }

    fn subnetCall(self: *FakeNetwork, arena: Allocator, group: *Group, method: wire.Method, network_name: []const u8, name: []const u8, body: []const u8) Allocator.Error!Answer {
        // A subnet's path goes through its network, so with the network
        // not there even a delete is ResourceNotFound, naming the network.
        const network = findIn(Network, group.networks.items, network_name) orelse return resourceNotFound(arena, "virtualNetworks", network_name, group.name);
        return switch (method) {
            .PUT => self.putSubnet(arena, group, network, name, body),
            .GET => if (network.subnet(name)) |s|
                .{ .body = try jsonWith(arena, self, group, SubnetIn{ .network = network.*, .subnet = s.* }, writeSubnetAlone) }
            else
                refusal(arena, 404, "NotFound", try std.fmt.allocPrint(arena, "Resource {f} not found.", .{subnetId(group, network.name, name)})),
            .DELETE => self.deleteSubnet(arena, group, network, name),
            else => notFound(arena),
        };
    }

    fn putSubnet(self: *FakeNetwork, arena: Allocator, group: *Group, network: *Network, name: []const u8, body: []const u8) Allocator.Error!Answer {
        const spec = parse(SubnetBody, self.arena.allocator(), body) orelse return badBody(arena, "the body is not a subnet");
        var subnet = switch (try self.subnetFrom(arena, name, spec.properties orelse .{})) {
            .ok => |s| s,
            .refused => |r| return r,
        };
        var others: std.ArrayList(Subnet) = .empty;
        for (network.subnets.items) |s| if (!eql(s.name, name)) try others.append(arena, s);
        if (try rangeProblem(arena, network.name, network.prefixes, others.items, subnet)) |r| return r;
        var status: u16 = 201;
        if (network.subnet(name)) |old| {
            subnet.name = old.name;
            subnet.in_use = old.in_use;
            old.* = subnet;
            status = 200;
        } else {
            try network.subnets.append(self.arena.allocator(), subnet);
        }
        const stored = network.subnet(name).?;
        return self.started(arena, status, .{
            .subscription = group.subscription,
            .group = group.name,
            .kind = .subnet,
            .network = network.name,
            .name = stored.name,
        }, try jsonWith(arena, self, group, SubnetIn{ .network = network.*, .subnet = stored.* }, writeSubnetAlone));
    }

    fn deleteSubnet(self: *FakeNetwork, arena: Allocator, group: *Group, network: *Network, name: []const u8) Allocator.Error!Answer {
        const s = network.subnet(name) orelse return .{ .status = 204 };
        if (s.in_use > 0) return inUseSubnet(arena, s.name);
        s.state = "Deleting";
        return self.started(arena, 202, .{ .subscription = group.subscription, .group = group.name, .kind = .subnet, .network = network.name, .name = s.name }, "");
    }

    /// Network's refusal of `subnet` among `others` in a network of
    /// `prefixes`, or null. IPv4 ranges only: an IPv6 one is let through.
    fn rangeProblem(arena: Allocator, network: []const u8, prefixes: []const []const u8, others: []const Subnet, subnet: Subnet) Allocator.Error!?Answer {
        const inner = validate.parseCidr4(subnet.prefix) orelse return null;
        const inside = for (prefixes) |p| {
            const outer = validate.parseCidr4(p) orelse continue;
            if (outer.contains(inner)) break true;
        } else false;
        if (!inside) {
            return try refusal(arena, 400, "NetcfgSubnetRangeOutsideVnet", try std.fmt.allocPrint(arena, "Subnet '{s}' is not valid because its IP address range is outside the IP address range of virtual network '{s}'.", .{ subnet.name, network }));
        }
        for (others) |o| {
            const other = validate.parseCidr4(o.prefix) orelse continue;
            if (!other.overlaps(inner)) continue;
            return try refusal(arena, 400, "NetcfgSubnetRangesOverlap", try std.fmt.allocPrint(arena, "Subnet '{s}' is not valid because its IP address range overlaps with that of an existing subnet in virtual network '{s}'.", .{ subnet.name, network }));
        }
        return null;
    }

    // Network security groups.

    const SecurityGroupBody = struct {
        location: ?[]const u8 = null,
        tags: ?std.json.ArrayHashMap([]const u8) = null,
        properties: ?struct { securityRules: ?[]const std.json.Value = null } = null,
    };

    fn securityGroupCall(self: *FakeNetwork, arena: Allocator, group: *Group, method: wire.Method, name: []const u8, body: []const u8) Allocator.Error!Answer {
        return switch (method) {
            .PUT => self.putSecurityGroup(arena, group, name, body),
            .GET => if (findIn(SecurityGroup, group.security_groups.items, name)) |g|
                .{ .body = try jsonWith(arena, self, group, g.*, writeSecurityGroup) }
            else
                resourceNotFound(arena, "networkSecurityGroups", name, group.name),
            .DELETE => self.deleteSecurityGroup(arena, group, name),
            else => notFound(arena),
        };
    }

    fn putSecurityGroup(self: *FakeNetwork, arena: Allocator, group: *Group, name: []const u8, body: []const u8) Allocator.Error!Answer {
        const a = self.arena.allocator();
        const spec = parse(SecurityGroupBody, a, body) orelse return badBody(arena, "the body is not a network security group");
        const location = spec.location orelse return refusal(arena, 400, "LocationRequired", "The location property is required for this definition.");
        const rules: []const std.json.Value = if (spec.properties) |p| p.securityRules orelse &.{} else &.{};
        for (rules) |r| if (ruleName(r) == null) return badBody(arena, "a security rule has no name or no properties");
        const existing = findIn(SecurityGroup, group.security_groups.items, name);
        if (existing) |g| if (!eql(g.location, location)) return wrongLocation(arena, name, g.location, group.name, location);
        const made: SecurityGroup = .{
            .name = if (existing) |g| g.name else try a.dupe(u8, name),
            .location = location,
            .tags = try tagsOf(a, spec.tags),
            .rules = rules,
            .state = "Updating",
        };
        if (existing) |g| g.* = made else try group.security_groups.append(a, made);
        const stored = findIn(SecurityGroup, group.security_groups.items, name).?;
        return self.started(arena, if (existing != null) 200 else 201, .{
            .subscription = group.subscription,
            .group = group.name,
            .kind = .security_group,
            .name = stored.name,
        }, try jsonWith(arena, self, group, stored.*, writeSecurityGroup));
    }

    fn deleteSecurityGroup(self: *FakeNetwork, arena: Allocator, group: *Group, name: []const u8) Allocator.Error!Answer {
        const g = findIn(SecurityGroup, group.security_groups.items, name) orelse return .{ .status = 204 };
        var users: std.ArrayList([]const u8) = .empty;
        try self.subnetsUsing(arena, group, g.name, &users);
        if (users.items.len > 0) {
            return refusal(arena, 400, "InUseNetworkSecurityGroupCannotBeDeleted", try std.fmt.allocPrint(arena, "Network security group {f} cannot be deleted because it is in use by the following resources: {s}. In order to delete the Network security group, remove the association with the resource(s).", .{ securityGroupId(group, g.name), users.items[0] }));
        }
        g.state = "Deleting";
        return self.started(arena, 202, .{ .subscription = group.subscription, .group = group.name, .kind = .security_group, .name = g.name }, "");
    }

    /// The ids of the subnets anywhere in the fake that name this group.
    fn subnetsUsing(self: *FakeNetwork, arena: Allocator, group: *const Group, name: []const u8, out: *std.ArrayList([]const u8)) Allocator.Error!void {
        const id = try std.fmt.allocPrint(arena, "{f}", .{securityGroupId(group, name)});
        for (self.groups.items) |g| for (g.networks.items) |n| for (n.subnets.items) |s| {
            const ref = s.security_group orelse continue;
            if (eql(ref, id)) try out.append(arena, try std.fmt.allocPrint(arena, "{f}", .{subnetId(&g, n.name, s.name)}));
        };
    }

    fn securityGroupById(self: *FakeNetwork, id: []const u8) ?*SecurityGroup {
        var s: [8][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.tokenizeScalar(u8, id, '/');
        while (it.next()) |part| : (count += 1) {
            if (count == s.len) return null;
            s[count] = part;
        }
        if (count != 8 or !eql(s[0], "subscriptions") or !eql(s[2], "resourceGroups") or !eql(s[4], "providers")) return null;
        if (!eql(s[5], "Microsoft.Network") or !eql(s[6], "networkSecurityGroups")) return null;
        return self.findSecurityGroup(s[1], s[3], s[7]);
    }

    fn natGatewayKnown(self: *FakeNetwork, id: []const u8) bool {
        for (self.nat_gateways.items) |known| if (eql(known, id)) return true;
        return false;
    }

    /// A rule's name, when it is an object with a string `name` and an
    /// object `properties`.
    fn ruleName(rule: std.json.Value) ?[]const u8 {
        if (rule != .object) return null;
        const props = rule.object.get("properties") orelse return null;
        if (props != .object) return null;
        const name = rule.object.get("name") orelse return null;
        return if (name == .string) name.string else null;
    }

    // Operations.

    /// Records the write's operation and answers it: `status`, `body`, and
    /// the URL to poll, with a `Location` too for a delete.
    fn started(self: *FakeNetwork, arena: Allocator, status: u16, target: Target, body: []const u8) Allocator.Error!Answer {
        const a = self.arena.allocator();
        const delete = status == 202;
        const id = try std.fmt.allocPrint(a, "0000{x:0>4}-fa4e-4000-8000-000000000000", .{self.next_id});
        self.next_id += 1;
        const failure = if (delete) null else self.next_failure;
        if (!delete) self.next_failure = null;
        try self.operations.append(a, .{ .id = id, .target = target, .delete = delete, .polls_left = self.operation_polls, .failure = failure });
        const location = self.locationOf(target);
        const base = "{s}/subscriptions/{s}/providers/Microsoft.Network/locations/{s}/";
        const poll = try std.fmt.allocPrint(arena, base ++ "operations/{s}?api-version=" ++ api_version, .{ self.base_url, target.subscription, location, id });
        const result = try std.fmt.allocPrint(arena, base ++ "operationResults/{s}?api-version=" ++ api_version, .{ self.base_url, target.subscription, location, id });
        const headers = try arena.dupe(Header, &.{
            .{ .name = "Azure-AsyncOperation", .value = poll },
            .{ .name = "Retry-After", .value = self.retry_after },
            .{ .name = "Location", .value = result },
        });
        return .{ .status = status, .body = body, .headers = if (delete) headers else headers[0..2] };
    }

    fn locationOf(self: *FakeNetwork, t: Target) []const u8 {
        return switch (t.kind) {
            .network => self.findNetwork(t.subscription, t.group, t.name).?.location,
            .subnet => self.findNetwork(t.subscription, t.group, t.network).?.location,
            .security_group => self.findSecurityGroup(t.subscription, t.group, t.name).?.location,
        };
    }

    fn findOperation(self: *FakeNetwork, id: []const u8) ?*Pending {
        for (self.operations.items) |*op| if (eql(op.id, id)) return op;
        return null;
    }

    fn pollOperation(self: *FakeNetwork, arena: Allocator, id: []const u8) Allocator.Error!Answer {
        const op = self.findOperation(id) orelse return notFound(arena);
        if (!op.done and op.polls_left > 0) {
            op.polls_left -= 1;
            return .{ .headers = try arena.dupe(Header, &.{.{ .name = "Retry-After", .value = self.retry_after }}), .body = "{\"status\":\"InProgress\"}" };
        }
        self.finish(op);
        const f = op.failure orelse return .{ .body = "{\"status\":\"Succeeded\"}" };
        return .{ .body = try jsonOf(arena, .{ .status = "Failed", .@"error" = .{ .code = f.code, .message = f.message } }) };
    }

    /// The `Location` a delete names: 202 while it runs, 204 once done.
    fn operationResult(self: *FakeNetwork, arena: Allocator, id: []const u8) Allocator.Error!Answer {
        const op = self.findOperation(id) orelse return notFound(arena);
        if (!op.done and op.polls_left > 0) {
            op.polls_left -= 1;
            return .{ .status = 202, .headers = try arena.dupe(Header, &.{.{ .name = "Retry-After", .value = self.retry_after }}) };
        }
        self.finish(op);
        return .{ .status = 204 };
    }

    /// Ends the operation: a create's resource is Succeeded (or Failed), a
    /// deleted one gone.
    fn finish(self: *FakeNetwork, op: *Pending) void {
        if (op.done) return;
        op.done = true;
        const t = op.target;
        const state = if (op.failure != null) "Failed" else "Succeeded";
        const group = self.findGroup(t.subscription, t.group) orelse return;
        switch (t.kind) {
            .network => {
                const n = findIn(Network, group.networks.items, t.name) orelse return;
                if (op.delete) return removeNamed(Network, &group.networks, t.name);
                n.state = state;
                for (n.subnets.items) |*s| s.state = state;
            },
            .subnet => {
                const n = findIn(Network, group.networks.items, t.network) orelse return;
                const s = n.subnet(t.name) orelse return;
                if (op.delete) return removeNamed(Subnet, &n.subnets, t.name);
                s.state = state;
            },
            .security_group => {
                const g = findIn(SecurityGroup, group.security_groups.items, t.name) orelse return;
                if (op.delete) return removeNamed(SecurityGroup, &group.security_groups, t.name);
                g.state = state;
            },
        }
    }

    fn removeNamed(comptime T: type, list: *std.ArrayList(T), name: []const u8) void {
        for (list.items, 0..) |item, i| {
            if (eql(item.name, name)) {
                _ = list.orderedRemove(i);
                return;
            }
        }
    }

    // Bodies.

    /// An ARM id, written as ARM writes it.
    const Id = struct {
        group: *const Group,
        kind: []const u8,
        name: []const u8,
        subnet: ?[]const u8 = null,

        pub fn format(id: Id, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.print("/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.Network/{s}/{s}", .{ id.group.subscription, id.group.name, id.kind, id.name });
            if (id.subnet) |s| try w.print("/subnets/{s}", .{s});
        }
    };

    fn subnetId(group: *const Group, network: []const u8, name: []const u8) Id {
        return .{ .group = group, .kind = "virtualNetworks", .name = network, .subnet = name };
    }

    fn securityGroupId(group: *const Group, name: []const u8) Id {
        return .{ .group = group, .kind = "networkSecurityGroups", .name = name };
    }

    /// JSON from `write(jw, self, group, value)`, in `arena`.
    fn jsonWith(arena: Allocator, self: *FakeNetwork, group: *const Group, value: anytype, comptime write: fn (*std.json.Stringify, *FakeNetwork, *const Group, @TypeOf(value)) std.json.Stringify.Error!void) Allocator.Error![]const u8 {
        var w: std.Io.Writer.Allocating = .init(arena);
        var jw: std.json.Stringify = .{ .writer = &w.writer };
        write(&jw, self, group, value) catch return error.OutOfMemory;
        return w.written();
    }

    fn writeId(jw: *std.json.Stringify, id: Id) std.json.Stringify.Error!void {
        try jw.objectField("id");
        try jw.print("\"{f}\"", .{id});
    }

    fn writeNetwork(jw: *std.json.Stringify, self: *FakeNetwork, group: *const Group, n: Network) std.json.Stringify.Error!void {
        _ = self;
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(n.name);
        try writeId(jw, .{ .group = group, .kind = "virtualNetworks", .name = n.name });
        try jw.objectField("type");
        try jw.write("Microsoft.Network/virtualNetworks");
        try jw.objectField("location");
        try jw.write(n.location);
        try writeTags(jw, n.tags);
        try jw.objectField("properties");
        try jw.beginObject();
        try jw.objectField("provisioningState");
        try jw.write(n.state);
        try jw.objectField("addressSpace");
        try jw.write(.{ .addressPrefixes = n.prefixes });
        try jw.objectField("subnets");
        try jw.beginArray();
        for (n.subnets.items) |s| try writeSubnet(jw, group, n, s);
        try jw.endArray();
        try jw.objectField("virtualNetworkPeerings");
        try jw.beginArray();
        try jw.endArray();
        try jw.objectField("enableDdosProtection");
        try jw.write(false);
        try jw.endObject();
        try jw.endObject();
    }

    /// A subnet and the network it is in.
    const SubnetIn = struct { network: Network, subnet: Subnet };

    fn writeSubnetAlone(jw: *std.json.Stringify, self: *FakeNetwork, group: *const Group, in: SubnetIn) std.json.Stringify.Error!void {
        _ = self;
        try writeSubnet(jw, group, in.network, in.subnet);
    }

    fn writeSubnet(jw: *std.json.Stringify, group: *const Group, n: Network, s: Subnet) std.json.Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(s.name);
        try writeId(jw, subnetId(group, n.name, s.name));
        try jw.objectField("type");
        try jw.write("Microsoft.Network/virtualNetworks/subnets");
        try jw.objectField("properties");
        try jw.beginObject();
        try jw.objectField("provisioningState");
        try jw.write(s.state);
        try jw.objectField("addressPrefix");
        try jw.write(s.prefix);
        if (s.default_outbound_access) |d| {
            try jw.objectField("defaultOutboundAccess");
            try jw.write(d);
        }
        if (s.endpoints.len > 0) {
            try jw.objectField("serviceEndpoints");
            try jw.beginArray();
            for (s.endpoints) |e| try jw.write(.{ .service = e, .locations = &[_][]const u8{n.location}, .provisioningState = "Succeeded" });
            try jw.endArray();
        }
        if (s.security_group) |id| {
            try jw.objectField("networkSecurityGroup");
            try jw.write(.{ .id = id });
        }
        if (s.nat_gateway) |id| {
            try jw.objectField("natGateway");
            try jw.write(.{ .id = id });
        }
        if (s.in_use > 0) {
            try jw.objectField("ipConfigurations");
            try jw.beginArray();
            for (0..s.in_use) |i| {
                try jw.beginObject();
                try jw.objectField("id");
                try jw.print("\"/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.Network/networkInterfaces/fake-nic-{d}/ipConfigurations/ipconfig1\"", .{ group.subscription, group.name, i + 1 });
                try jw.endObject();
            }
            try jw.endArray();
        }
        try jw.objectField("privateEndpointNetworkPolicies");
        try jw.write("Disabled");
        try jw.objectField("privateLinkServiceNetworkPolicies");
        try jw.write("Enabled");
        try jw.endObject();
        try jw.endObject();
    }

    /// Azure's six default rules, as the spec's examples give them.
    const default_rules = [_]struct { []const u8, u16, []const u8, []const u8, []const u8, []const u8, []const u8 }{
        .{ "AllowVnetInBound", 65000, "Inbound", "Allow", "VirtualNetwork", "VirtualNetwork", "Allow inbound traffic from all VMs in VNET" },
        .{ "AllowAzureLoadBalancerInBound", 65001, "Inbound", "Allow", "AzureLoadBalancer", "*", "Allow inbound traffic from azure load balancer" },
        .{ "DenyAllInBound", 65500, "Inbound", "Deny", "*", "*", "Deny all inbound traffic" },
        .{ "AllowVnetOutBound", 65000, "Outbound", "Allow", "VirtualNetwork", "VirtualNetwork", "Allow outbound traffic from all VMs to all VMs in VNET" },
        .{ "AllowInternetOutBound", 65001, "Outbound", "Allow", "*", "Internet", "Allow outbound traffic from all VMs to Internet" },
        .{ "DenyAllOutBound", 65500, "Outbound", "Deny", "*", "*", "Deny all outbound traffic" },
    };

    fn writeSecurityGroup(jw: *std.json.Stringify, self: *FakeNetwork, group: *const Group, g: SecurityGroup) std.json.Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(g.name);
        try writeId(jw, securityGroupId(group, g.name));
        try jw.objectField("type");
        try jw.write("Microsoft.Network/networkSecurityGroups");
        try jw.objectField("location");
        try jw.write(g.location);
        try writeTags(jw, g.tags);
        try jw.objectField("properties");
        try jw.beginObject();
        try jw.objectField("provisioningState");
        try jw.write(g.state);
        try jw.objectField("securityRules");
        try jw.beginArray();
        for (g.rules) |r| try writeRule(jw, group, g.name, r);
        try jw.endArray();
        try jw.objectField("defaultSecurityRules");
        try jw.beginArray();
        for (default_rules) |d| try writeDefaultRule(jw, group, g.name, d);
        try jw.endArray();
        try jw.objectField("subnets");
        try jw.beginArray();
        try writeSubnetRefs(jw, self, group, g.name);
        try jw.endArray();
        try jw.endObject();
        try jw.endObject();
    }

    fn writeSubnetRefs(jw: *std.json.Stringify, self: *FakeNetwork, group: *const Group, name: []const u8) std.json.Stringify.Error!void {
        var buf: [512]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        const id = std.fmt.allocPrint(fba.allocator(), "{f}", .{securityGroupId(group, name)}) catch return error.WriteFailed;
        for (self.groups.items) |*g| for (g.networks.items) |n| for (n.subnets.items) |s| {
            const ref = s.security_group orelse continue;
            if (!eql(ref, id)) continue;
            try jw.beginObject();
            try writeId(jw, subnetId(g, n.name, s.name));
            try jw.endObject();
        };
    }

    /// A rule as the create sent it, with what Network adds: its id, type
    /// and provisioning state.
    fn writeRule(jw: *std.json.Stringify, group: *const Group, name: []const u8, rule: std.json.Value) std.json.Stringify.Error!void {
        const rule_name = ruleName(rule).?;
        const props = rule.object.get("properties").?.object;
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(rule_name);
        try jw.objectField("id");
        try jw.print("\"{f}/securityRules/{s}\"", .{ securityGroupId(group, name), rule_name });
        try jw.objectField("type");
        try jw.write("Microsoft.Network/networkSecurityGroups/securityRules");
        try jw.objectField("properties");
        try jw.beginObject();
        for (props.keys(), props.values()) |k, v| {
            if (std.mem.eql(u8, k, "provisioningState")) continue;
            try jw.objectField(k);
            try jw.write(v);
        }
        try jw.objectField("provisioningState");
        try jw.write("Succeeded");
        try jw.endObject();
        try jw.endObject();
    }

    fn writeDefaultRule(jw: *std.json.Stringify, group: *const Group, name: []const u8, d: @TypeOf(default_rules[0])) std.json.Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(d[0]);
        try jw.objectField("id");
        try jw.print("\"{f}/defaultSecurityRules/{s}\"", .{ securityGroupId(group, name), d[0] });
        try jw.objectField("properties");
        try jw.write(.{
            .description = d[6],
            .protocol = "*",
            .sourcePortRange = "*",
            .destinationPortRange = "*",
            .sourceAddressPrefix = d[4],
            .destinationAddressPrefix = d[5],
            .access = d[3],
            .priority = d[1],
            .direction = d[2],
            .provisioningState = "Succeeded",
        });
        try jw.endObject();
    }

    fn writeTags(jw: *std.json.Stringify, tags: []const Tag) std.json.Stringify.Error!void {
        try jw.objectField("tags");
        try jw.beginObject();
        for (tags) |t| {
            try jw.objectField(t.name);
            try jw.write(t.value);
        }
        try jw.endObject();
    }

    fn tagsOf(a: Allocator, raw: ?std.json.ArrayHashMap([]const u8)) Allocator.Error![]const Tag {
        const m = raw orelse return &.{};
        const tags = try a.alloc(Tag, m.map.count());
        for (m.map.keys(), m.map.values(), tags) |k, v, *t| t.* = .{ .name = k, .value = v };
        return tags;
    }

    fn parse(comptime T: type, a: Allocator, body: []const u8) ?T {
        return std.json.parseFromSliceLeaky(T, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
    }

    fn jsonOf(arena: Allocator, value: anytype) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(value, .{})});
    }

    // Refusals.

    fn refusal(arena: Allocator, status: u16, code: []const u8, message: []const u8) Allocator.Error!Answer {
        const headers = try arena.dupe(Header, &.{
            .{ .name = "x-ms-request-id", .value = "fa4e0000-0000-4000-8000-000000000001" },
            .{ .name = "x-ms-correlation-request-id", .value = "fa4e0000-0000-4000-8000-000000000002" },
        });
        return .{ .status = status, .headers = headers, .body = try jsonOf(arena, .{ .@"error" = .{ .code = code, .message = message } }) };
    }

    fn notFound(arena: Allocator) Allocator.Error!Answer {
        return refusal(arena, 404, "NotFound", "The fake answers only the network module's calls.");
    }

    fn badBody(arena: Allocator, why: []const u8) Allocator.Error!Answer {
        return refusal(arena, 400, "InvalidRequestFormat", try std.fmt.allocPrint(arena, "Cannot parse the request: {s}.", .{why}));
    }

    fn resourceNotFound(arena: Allocator, kind: []const u8, name: []const u8, group: []const u8) Allocator.Error!Answer {
        return refusal(arena, 404, "ResourceNotFound", try std.fmt.allocPrint(arena, "The Resource 'Microsoft.Network/{s}/{s}' under resource group '{s}' was not found.", .{ kind, name, group }));
    }

    fn invalidCidr(arena: Allocator, prefix: []const u8) Allocator.Error!Answer {
        return refusal(arena, 400, "InvalidCIDRNotation", try std.fmt.allocPrint(arena, "The address prefix {s} has an invalid CIDR notation.", .{prefix}));
    }

    fn inUseSubnet(arena: Allocator, name: []const u8) Allocator.Error!Answer {
        return refusal(arena, 400, "InUseSubnetCannotBeDeleted", try std.fmt.allocPrint(arena, "Subnet {s} is in use and cannot be deleted. In order to delete the subnet, delete all the resources within the subnet.", .{name}));
    }

    fn missingReference(arena: Allocator, id: []const u8, by: []const u8) Allocator.Error!Answer {
        return refusal(arena, 400, "InvalidResourceReference", try std.fmt.allocPrint(arena, "Resource {s} referenced by resource {s} was not found. Please make sure that the referenced resource exists, and that both resources are in the same region.", .{ id, by }));
    }

    fn wrongLocation(arena: Allocator, name: []const u8, was: []const u8, group: []const u8, asked: []const u8) Allocator.Error!Answer {
        return refusal(arena, 409, "InvalidResourceLocation", try std.fmt.allocPrint(arena, "The resource '{s}' already exists in location '{s}' in resource group '{s}'. A resource with the same name cannot be created in location '{s}'. Please select a new resource name.", .{ name, was, group, asked }));
    }

    // Queries.

    /// A query parameter's value, percent-decoded, matched by name without
    /// regard to case; null when the query has none.
    fn param(arena: Allocator, query: []const u8, name: []const u8) Allocator.Error!?[]const u8 {
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
            const key = std.Uri.percentDecodeInPlace(try arena.dupe(u8, pair[0..eq]));
            if (!std.ascii.eqlIgnoreCase(key, name)) continue;
            const raw = if (eq < pair.len) pair[eq + 1 ..] else "";
            return std.Uri.percentDecodeInPlace(try arena.dupe(u8, raw));
        }
        return null;
    }

    fn eql(a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }
};
