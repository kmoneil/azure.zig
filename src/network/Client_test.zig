//! The network client against FakeNetwork, and against a scripted
//! transport where the request's exact shape is the point.

const std = @import("std");
const testing = std.testing;
const core = @import("core");
const Client = @import("Client.zig");
const types = @import("types.zig");
const ids = @import("ids.zig");
const FakeNetwork = @import("fake_network.zig").FakeNetwork;

const sub = "0f9e8d7c-6b5a-4c3d-8e2f-1a0b9c8d7e6f";
const rg = "azzig-network-1";

const Rig = struct {
    fake: FakeNetwork,
    clock: core.testing.FakeClock = .{},
    token: core.testing.FakeTokenProvider = .{ .token = "eyJ0.arm" },
    diag: core.Diagnostics = .{},
    client: Client = undefined,

    /// In place: the client points at the fake, the clock and the token.
    fn init(rig: *Rig) !void {
        rig.* = .{ .fake = .init(testing.allocator) };
        try rig.fake.addGroup(sub, rg);
        rig.client = try .init(testing.allocator, rig.clock.io(), .{
            .token_provider = rig.token.provider(),
            .transport = rig.fake.transport(),
            .diagnostics = &rig.diag,
        });
    }

    fn deinit(rig: *Rig) void {
        rig.client.deinit();
        rig.fake.deinit();
    }

    /// Waits on `op` to its end, which must be success, and frees it.
    fn settle(rig: *Rig, op: anytype) !void {
        var o = op;
        defer o.deinit();
        try rig.client.waitOperation(&o, 600_000);
        try testing.expectEqual(.succeeded, o.value.state);
    }

    /// The JSON body of the latest call the fake saw.
    fn lastBody(rig: *Rig) []const u8 {
        return rig.fake.calls.items[rig.fake.calls.items.len - 1].body;
    }
};

const workers: types.NamedSubnet = .{ .name = "workers", .spec = .{
    .address_prefix = "10.20.1.0/24",
    .service_endpoints = &.{"Microsoft.Storage"},
} };

test "a network with a private subnet: Updating until its operation ends, then as made" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    rig.fake.operation_polls = 2;

    var op = try rig.client.beginCreateVirtualNetwork(sub, rg, "pb-vnet", .{
        .location = "eastus2",
        .address_prefixes = &.{"10.20.0.0/16"},
        .subnets = &.{workers},
        .tags = &.{.{ .name = "azzig-run", .value = "r1" }},
    });
    defer op.deinit();
    try testing.expectEqual(.running, op.value.state);
    try testing.expectEqual(.async_operation, op.value.follow);
    try testing.expectEqualStrings(core.Cloud.public.arm_scope, rig.token.firstScope());
    const sent = rig.fake.calls.items[0];
    try testing.expectEqual(.PUT, sent.method);
    try testing.expectStringEndsWith(sent.url, "/subscriptions/" ++ sub ++ "/resourceGroups/" ++ rg ++ "/providers/Microsoft.Network/virtualNetworks/pb-vnet?api-version=2026-03-01");
    try testing.expect(std.mem.indexOf(u8, sent.body, "\"defaultOutboundAccess\":false") != null);

    var during = try rig.client.getVirtualNetwork(sub, rg, "pb-vnet");
    defer during.deinit();
    try testing.expectEqualStrings("Updating", during.value.provisioning_state);

    try rig.client.waitOperation(&op, 600_000);
    try testing.expectEqual(.succeeded, op.value.state);
    try testing.expectEqual(3, rig.clock.sleep_count);
    try testing.expectEqual(10_000, rig.clock.sleepMs(2));

    var got = try rig.client.getVirtualNetwork(sub, rg, "PB-VNET");
    defer got.deinit();
    const n = got.value;
    try testing.expectEqualStrings("Succeeded", n.provisioning_state);
    try testing.expectEqualStrings("eastus2", n.location);
    try testing.expectEqualStrings("10.20.0.0/16", n.address_prefixes[0]);
    try testing.expectEqualStrings("r1", n.tag("AZZIG-RUN").?);
    const s = n.subnet("Workers").?;
    try testing.expectEqualStrings("10.20.1.0/24", s.address_prefixes[0]);
    try testing.expectEqual(false, s.default_outbound_access.?);
    try testing.expect(!s.defaultOutbound());
    try testing.expect(s.hasEndpoint("microsoft.storage"));
    try testing.expectEqualStrings("eastus2", s.service_endpoints[0].locations[0]);
    try testing.expectEqual(null, s.security_group);
    const want = try ids.subnet(testing.allocator, sub, rg, "pb-vnet", "workers");
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, s.id);
}

test "a network made again: 200, its subnets become the spec's, and one in use is not taken away" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const spec: types.VirtualNetworkSpec = .{ .location = "eastus2", .address_prefixes = &.{"10.20.0.0/16"}, .subnets = &.{workers} };
    try rig.settle(try rig.client.beginCreateVirtualNetwork(sub, rg, "pb-vnet", spec));
    try rig.settle(try rig.client.beginCreateSubnet(sub, rg, "pb-vnet", "extra", .{ .address_prefix = "10.20.2.0/24" }));

    // Made again without "extra": it goes.
    try rig.settle(try rig.client.beginCreateVirtualNetwork(sub, rg, "pb-vnet", spec));
    var after = try rig.client.getVirtualNetwork(sub, rg, "pb-vnet");
    defer after.deinit();
    try testing.expectEqual(1, after.value.subnets.len);
    try testing.expectEqual(null, after.value.subnet("extra"));

    // Made again without "workers", which a VM uses: refused, and kept.
    try rig.fake.useSubnet(sub, rg, "pb-vnet", "workers");
    try testing.expectError(error.BadRequest, rig.client.beginCreateVirtualNetwork(sub, rg, "pb-vnet", .{ .location = "eastus2", .address_prefixes = &.{"10.20.0.0/16"} }));
    try testing.expectEqualStrings("InUseSubnetCannotBeDeleted", rig.diag.code());
    var kept = try rig.client.getSubnet(sub, rg, "pb-vnet", "workers");
    defer kept.deinit();
    try testing.expectEqual(1, kept.value.ip_configurations);

    // And in another location: refused.
    try testing.expectError(error.Conflict, rig.client.beginCreateVirtualNetwork(sub, rg, "pb-vnet", .{ .location = "westus2", .address_prefixes = &.{"10.20.0.0/16"}, .subnets = &.{workers} }));
    try testing.expectEqualStrings("InvalidResourceLocation", rig.diag.code());
}

test "a subnet alone: its network must be there, its range inside it and clear of the others" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    try testing.expectError(error.NotFound, rig.client.beginCreateSubnet(sub, rg, "pb-vnet", "workers", workers.spec));
    try testing.expectEqualStrings("ResourceNotFound", rig.diag.code());

    try rig.settle(try rig.client.beginCreateVirtualNetwork(sub, rg, "pb-vnet", .{ .location = "eastus2", .address_prefixes = &.{"10.20.0.0/16"}, .subnets = &.{workers} }));
    try testing.expectError(error.BadRequest, rig.client.beginCreateSubnet(sub, rg, "pb-vnet", "far", .{ .address_prefix = "10.30.0.0/24" }));
    try testing.expectEqualStrings("NetcfgSubnetRangeOutsideVnet", rig.diag.code());
    try testing.expectError(error.BadRequest, rig.client.beginCreateSubnet(sub, rg, "pb-vnet", "over", .{ .address_prefix = "10.20.1.128/25" }));
    try testing.expectEqualStrings("NetcfgSubnetRangesOverlap", rig.diag.code());

    // The same subnet made again with a new range is no overlap with itself.
    try rig.settle(try rig.client.beginCreateSubnet(sub, rg, "pb-vnet", "workers", .{ .address_prefix = "10.20.1.0/25", .default_outbound_access = true }));
    var got = try rig.client.getSubnet(sub, rg, "pb-vnet", "workers");
    defer got.deinit();
    try testing.expectEqualStrings("10.20.1.0/25", got.value.address_prefixes[0]);
    try testing.expect(got.value.defaultOutbound());
    try testing.expectEqual(0, got.value.service_endpoints.len);

    try testing.expectError(error.NotFound, rig.client.getSubnet(sub, rg, "pb-vnet", "nothing"));
    try testing.expectEqualStrings("NotFound", rig.diag.code());
}

test "a security group: its rules as sent, Azure's six below them, and the subnets it applies to" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const rules = [_]types.SecurityRule{
        .{ .name = "AllowSsh", .priority = 100, .direction = .inbound, .access = .allow, .protocol = .tcp, .source_address_prefixes = &.{ "203.0.113.0/24", "198.51.100.7" }, .destination_port_ranges = &.{"22"}, .description = "operators" },
        .{ .name = "DenyInternetOut", .priority = 100, .direction = .outbound, .access = .deny, .destination_address_prefixes = &.{"Internet"} },
    };
    try rig.settle(try rig.client.beginCreateSecurityGroup(sub, rg, "pb-nsg", .{ .location = "eastus2", .rules = &rules }));
    const nsg_id = try ids.securityGroup(testing.allocator, sub, rg, "pb-nsg");
    defer testing.allocator.free(nsg_id);
    try rig.settle(try rig.client.beginCreateVirtualNetwork(sub, rg, "pb-vnet", .{
        .location = "eastus2",
        .address_prefixes = &.{"10.20.0.0/16"},
        .subnets = &.{.{ .name = "workers", .spec = .{ .address_prefix = "10.20.1.0/24", .security_group = nsg_id } }},
    }));

    var got = try rig.client.getSecurityGroup(sub, rg, "pb-nsg");
    defer got.deinit();
    const g = got.value;
    try testing.expectEqualStrings(nsg_id, g.id);
    try testing.expectEqual(2, g.rules.len);
    const ssh = g.rule("allowssh").?;
    try testing.expectEqual(.tcp, ssh.protocol);
    try testing.expectEqual(.inbound, ssh.direction);
    try testing.expectEqual(2, ssh.source_address_prefixes.len);
    try testing.expectEqualStrings("198.51.100.7", ssh.source_address_prefixes[1]);
    try testing.expectEqualStrings("22", ssh.destination_port_ranges[0]);
    try testing.expectEqualStrings("*", ssh.source_port_ranges[0]);
    try testing.expectEqualStrings("operators", ssh.description);
    try testing.expectEqual(.deny, g.rule("DenyInternetOut").?.access);
    try testing.expectEqual(6, g.default_rules.len);
    try testing.expectEqual(65500, g.default_rules[2].priority);
    try testing.expectEqual(1, g.subnets.len);
    try testing.expectStringEndsWith(g.subnets[0], "/virtualNetworks/pb-vnet/subnets/workers");

    var s = try rig.client.getSubnet(sub, rg, "pb-vnet", "workers");
    defer s.deinit();
    try testing.expectEqualStrings(nsg_id, s.value.security_group.?);
}

test "a security group in use is not deleted; once no subnet names it, it is" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    try rig.settle(try rig.client.beginCreateSecurityGroup(sub, rg, "pb-nsg", .{ .location = "eastus2" }));
    const nsg_id = try ids.securityGroup(testing.allocator, sub, rg, "pb-nsg");
    defer testing.allocator.free(nsg_id);
    const with: types.SubnetSpec = .{ .address_prefix = "10.20.1.0/24", .security_group = nsg_id };
    try rig.settle(try rig.client.beginCreateVirtualNetwork(sub, rg, "pb-vnet", .{ .location = "eastus2", .address_prefixes = &.{"10.20.0.0/16"}, .subnets = &.{.{ .name = "workers", .spec = with }} }));

    try testing.expectError(error.BadRequest, rig.client.beginDeleteSecurityGroup(sub, rg, "pb-nsg"));
    try testing.expectEqualStrings("InUseNetworkSecurityGroupCannotBeDeleted", rig.diag.code());

    try rig.settle(try rig.client.beginCreateSubnet(sub, rg, "pb-vnet", "workers", .{ .address_prefix = "10.20.1.0/24" }));
    try rig.settle(try rig.client.beginDeleteSecurityGroup(sub, rg, "pb-nsg"));
    try testing.expectError(error.NotFound, rig.client.getSecurityGroup(sub, rg, "pb-nsg"));
    try testing.expectEqualStrings("ResourceNotFound", rig.diag.code());
}

test "a reference to a security group or NAT gateway not there is refused" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    try rig.settle(try rig.client.beginCreateVirtualNetwork(sub, rg, "pb-vnet", .{ .location = "eastus2", .address_prefixes = &.{"10.20.0.0/16"} }));
    const nsg_id = try ids.securityGroup(testing.allocator, sub, rg, "none");
    defer testing.allocator.free(nsg_id);
    try testing.expectError(error.BadRequest, rig.client.beginCreateSubnet(sub, rg, "pb-vnet", "workers", .{ .address_prefix = "10.20.1.0/24", .security_group = nsg_id }));
    try testing.expectEqualStrings("InvalidResourceReference", rig.diag.code());

    const nat_id = try ids.natGateway(testing.allocator, sub, rg, "pb-nat");
    defer testing.allocator.free(nat_id);
    try testing.expectError(error.BadRequest, rig.client.beginCreateSubnet(sub, rg, "pb-vnet", "workers", .{ .address_prefix = "10.20.1.0/24", .nat_gateway = nat_id }));
    try rig.fake.addNatGateway(sub, rg, "pb-nat");
    try rig.settle(try rig.client.beginCreateSubnet(sub, rg, "pb-vnet", "workers", .{ .address_prefix = "10.20.1.0/24", .nat_gateway = nat_id }));
    var got = try rig.client.getSubnet(sub, rg, "pb-vnet", "workers");
    defer got.deinit();
    try testing.expectEqualStrings(nat_id, got.value.nat_gateway.?);
}

test "deletes: Deleting until the operation ends, then gone; one in use refused; one not there done at once, but a subnet of a network not there NotFound" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    try rig.settle(try rig.client.beginCreateVirtualNetwork(sub, rg, "pb-vnet", .{ .location = "eastus2", .address_prefixes = &.{"10.20.0.0/16"}, .subnets = &.{workers} }));

    try rig.fake.useSubnet(sub, rg, "pb-vnet", "workers");
    try testing.expectError(error.BadRequest, rig.client.beginDeleteSubnet(sub, rg, "pb-vnet", "workers"));
    try testing.expectEqualStrings("InUseSubnetCannotBeDeleted", rig.diag.code());
    try testing.expectError(error.BadRequest, rig.client.beginDeleteVirtualNetwork(sub, rg, "pb-vnet"));
    rig.fake.findNetwork(sub, rg, "pb-vnet").?.subnet("workers").?.in_use = 0;

    var op = try rig.client.beginDeleteSubnet(sub, rg, "pb-vnet", "workers");
    defer op.deinit();
    try testing.expectEqual(.running, op.value.state);
    try testing.expectEqual(.DELETE, rig.fake.calls.items[rig.fake.calls.items.len - 1].method);
    var deleting = try rig.client.getSubnet(sub, rg, "pb-vnet", "workers");
    defer deleting.deinit();
    try testing.expectEqualStrings("Deleting", deleting.value.provisioning_state);
    try rig.client.waitOperation(&op, 600_000);
    try testing.expectEqual(.succeeded, op.value.state);
    try testing.expectError(error.NotFound, rig.client.getSubnet(sub, rg, "pb-vnet", "workers"));

    // Nothing there: done with the first answer, no poll.
    var calls = rig.fake.calls.items.len;
    var no_subnet = try rig.client.beginDeleteSubnet(sub, rg, "pb-vnet", "workers");
    defer no_subnet.deinit();
    try testing.expectEqual(.succeeded, no_subnet.value.state);
    try testing.expectEqual(calls + 1, rig.fake.calls.items.len);

    try rig.settle(try rig.client.beginDeleteVirtualNetwork(sub, rg, "pb-vnet"));
    try testing.expectError(error.NotFound, rig.client.getVirtualNetwork(sub, rg, "pb-vnet"));

    calls = rig.fake.calls.items.len;
    for ([_]types.Owned(core.operation.Operation){
        try rig.client.beginDeleteVirtualNetwork(sub, rg, "pb-vnet"),
        try rig.client.beginDeleteSecurityGroup(sub, rg, "pb-nsg"),
    }) |gone| {
        var g = gone;
        defer g.deinit();
        try testing.expectEqual(.succeeded, g.value.state);
    }
    try testing.expectEqual(calls + 2, rig.fake.calls.items.len);

    // But a subnet of a network not there is NotFound, as Network answers.
    try testing.expectError(error.NotFound, rig.client.beginDeleteSubnet(sub, rg, "pb-vnet", "workers"));
    try testing.expectEqualStrings("ResourceNotFound", rig.diag.code());
}

test "a create whose operation fails: an answer, with ARM's code, and the resource Failed" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    try rig.fake.failNextWrite("InternalServerError", "An error occurred.");
    var op = try rig.client.beginCreateVirtualNetwork(sub, rg, "pb-vnet", .{ .location = "eastus2", .address_prefixes = &.{"10.20.0.0/16"}, .subnets = &.{workers} });
    defer op.deinit();
    try rig.client.waitOperation(&op, 600_000);
    try testing.expectEqual(.failed, op.value.state);
    try testing.expectEqualStrings("InternalServerError", op.value.failure_code);
    try testing.expectEqualStrings("An error occurred.", op.value.failure_message);
    var got = try rig.client.getVirtualNetwork(sub, rg, "pb-vnet");
    defer got.deinit();
    try testing.expectEqualStrings("Failed", got.value.provisioning_state);
    try testing.expectEqualStrings("Failed", got.value.subnets[0].provisioning_state);
}

test "a group not there is NotFound, and an unregistered provider ProviderNotRegistered" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    try testing.expectError(error.NotFound, rig.client.getVirtualNetwork(sub, "other-rg", "pb-vnet"));
    try testing.expectEqualStrings("ResourceGroupNotFound", rig.diag.code());
    rig.fake.registered = false;
    try testing.expectError(error.ProviderNotRegistered, rig.client.beginCreateSecurityGroup(sub, rg, "pb-nsg", .{ .location = "eastus2" }));
    try testing.expectEqualStrings("MissingSubscriptionRegistration", rig.diag.code());
}

test "what Network would refuse, or would read as another resource, is refused before anything is sent" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const c = &rig.client;

    try testing.expectError(error.InvalidArgument, c.getVirtualNetwork("not-a-guid", rg, "pb-vnet"));
    try testing.expectEqualStrings("a subscription id is a GUID", rig.diag.message());
    for ([_][]const u8{ "", "v", "-vnet", "vnet.", "a/b", "..", "a?b" }) |name| {
        try testing.expectError(error.InvalidArgument, c.getVirtualNetwork(sub, rg, name));
    }
    try testing.expectError(error.InvalidArgument, c.getSubnet(sub, rg, "pb-vnet", "../x"));
    try testing.expectError(error.InvalidArgument, c.getSecurityGroup(sub, "rg.", "pb-nsg"));

    const bad_networks = [_]types.VirtualNetworkSpec{
        .{ .location = "east us", .address_prefixes = &.{"10.20.0.0/16"} },
        .{ .location = "eastus2", .address_prefixes = &.{} },
        .{ .location = "eastus2", .address_prefixes = &.{"10.20.0.1/16"} },
        .{ .location = "eastus2", .address_prefixes = &.{"10.20.0.0/16"}, .subnets = &.{ workers, workers } },
        .{ .location = "eastus2", .address_prefixes = &.{"10.20.0.0/16"}, .tags = &.{ .{ .name = "a", .value = "1" }, .{ .name = "A", .value = "2" } } },
    };
    for (bad_networks) |spec| try testing.expectError(error.InvalidArgument, c.beginCreateVirtualNetwork(sub, rg, "pb-vnet", spec));
    try testing.expectError(error.InvalidArgument, c.beginCreateVirtualNetwork(sub, rg, "pb-vnet", .{ .location = "eastus2", .address_prefixes = &.{"10.20.0.0/16"}, .subnets = &.{.{ .name = "w/x", .spec = workers.spec }} }));

    const bad_subnets = [_]types.SubnetSpec{
        .{ .address_prefix = "10.20.1.0" },
        .{ .address_prefix = "10.20.1.0/24", .service_endpoints = &.{"Microsoft Storage"} },
        .{ .address_prefix = "10.20.1.0/24", .security_group = "pb-nsg" },
        .{ .address_prefix = "10.20.1.0/24", .nat_gateway = "/subscriptions/" ++ sub ++ "/resourceGroups/rg/providers/Microsoft.Network/networkSecurityGroups/x" },
    };
    for (bad_subnets) |spec| try testing.expectError(error.InvalidArgument, c.beginCreateSubnet(sub, rg, "pb-vnet", "workers", spec));
    try testing.expectEqualStrings("nat_gateway is a NAT gateway's ARM id (ids.natGateway), not its name", rig.diag.message());

    const ok: types.SecurityRule = .{ .name = "r", .priority = 200, .direction = .inbound, .access = .allow };
    const bad_rules = [_][2]types.SecurityRule{
        .{ ok, .{ .name = "r2", .priority = 99, .direction = .inbound, .access = .allow } },
        .{ ok, .{ .name = "r2", .priority = 4097, .direction = .inbound, .access = .allow } },
        .{ ok, .{ .name = "r2", .priority = 200, .direction = .inbound, .access = .deny } },
        .{ ok, .{ .name = "R", .priority = 300, .direction = .inbound, .access = .allow } },
        .{ ok, .{ .name = "r2", .priority = 300, .direction = .inbound, .access = .allow, .protocol = .unknown } },
        .{ ok, .{ .name = "r2", .priority = 300, .direction = .inbound, .access = .allow, .destination_port_ranges = &.{} } },
        .{ ok, .{ .name = "r2", .priority = 300, .direction = .inbound, .access = .allow, .destination_port_ranges = &.{"22-21"} } },
        .{ ok, .{ .name = "r2", .priority = 300, .direction = .inbound, .access = .allow, .source_address_prefixes = &.{"a b"} } },
        .{ ok, .{ .name = "r2", .priority = 300, .direction = .inbound, .access = .allow, .description = "a\nb" } },
        .{ ok, .{ .name = "r_", .priority = 300, .direction = .unknown, .access = .allow } },
    };
    for (bad_rules) |pair| try testing.expectError(error.InvalidArgument, c.beginCreateSecurityGroup(sub, rg, "pb-nsg", .{ .location = "eastus2", .rules = &pair }));
    try testing.expectEqual(0, rig.fake.calls.items.len);

    // One priority in each direction is no clash.
    var both = try c.beginCreateSecurityGroup(sub, rg, "pb-nsg", .{ .location = "eastus2", .rules = &.{ ok, .{ .name = "out", .priority = 200, .direction = .outbound, .access = .allow } } });
    both.deinit();
}

/// A client over a scripted transport, for the exact shape of what it sends.
const Scripted = struct {
    fake: core.testing.FakeTransport,
    clock: core.testing.FakeClock = .{},
    token: core.testing.FakeTokenProvider = .{},
    diag: core.Diagnostics = .{},
    client: Client = undefined,

    fn init(s: *Scripted, script: []const core.testing.FakeTransport.Reply) !void {
        s.* = .{ .fake = .init(testing.allocator, script) };
        s.client = try .init(testing.allocator, s.clock.io(), .{
            .token_provider = s.token.provider(),
            .transport = s.fake.transport(),
            .diagnostics = &s.diag,
        });
    }

    fn deinit(s: *Scripted) void {
        s.client.deinit();
        s.fake.deinit();
    }
};

test "beginCreateSubnet sends one PUT: every property it controls, and a request id ARM echoes" {
    const script = comptime core.testing.asyncOperation(201, "https://management.azure.com/subscriptions/" ++ sub ++ "/providers/Microsoft.Network/locations/eastus2/operations/1?api-version=2026-03-01", "1", &.{"Succeeded"});
    var s: Scripted = undefined;
    try s.init(&script);
    defer s.deinit();
    const nsg = "/subscriptions/" ++ sub ++ "/resourceGroups/rg/providers/Microsoft.Network/networkSecurityGroups/pb-nsg";

    var op = try s.client.beginCreateSubnet(sub, "rg", "pb-vnet", "workers", .{ .address_prefix = "10.0.1.0/24", .service_endpoints = &.{"Microsoft.Storage"}, .security_group = nsg });
    defer op.deinit();
    const sent = try s.fake.streamRequest(0);
    try testing.expectEqual(.PUT, sent.method);
    try testing.expectEqualStrings("https://management.azure.com/subscriptions/" ++ sub ++ "/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/pb-vnet/subnets/workers?api-version=2026-03-01", sent.url);
    try testing.expectEqualStrings("application/json", sent.content_type.?);
    try testing.expectEqualStrings("{\"properties\":{\"addressPrefix\":\"10.0.1.0/24\",\"defaultOutboundAccess\":false,\"serviceEndpoints\":[{\"service\":\"Microsoft.Storage\"}],\"networkSecurityGroup\":{\"id\":\"" ++ nsg ++ "\"}}}", sent.body_prefix);
    try testing.expectEqual(36, sent.header("x-ms-client-request-id").?.len);
    try testing.expectEqualStrings("true", sent.header("x-ms-return-client-request-id").?);
    try s.client.waitOperation(&op, 60_000);
    try testing.expectEqual(.succeeded, op.value.state);
}

test "a network's PUT always carries its tags and subnets; a rule sends one value singular and more plural" {
    const script = [_]core.testing.FakeTransport.Reply{
        .{ .respond = .{ .status = 200, .body = "{\"properties\":{\"provisioningState\":\"Succeeded\"}}" } },
        .{ .respond = .{ .status = 200, .body = "{\"properties\":{\"provisioningState\":\"Succeeded\"}}" } },
    };
    var s: Scripted = undefined;
    try s.init(&script);
    defer s.deinit();

    var op = try s.client.beginCreateVirtualNetwork(sub, "rg", "pb-vnet", .{ .location = "eastus2", .address_prefixes = &.{ "10.0.0.0/16", "fd00:db8::/48" } });
    defer op.deinit();
    // A 200 with a terminal provisioningState and nothing to poll is done.
    try testing.expectEqual(.succeeded, op.value.state);
    try testing.expectEqualStrings("{\"location\":\"eastus2\",\"tags\":{},\"properties\":{\"addressSpace\":{\"addressPrefixes\":[\"10.0.0.0/16\",\"fd00:db8::/48\"]},\"subnets\":[]}}", (try s.fake.streamRequest(0)).body_prefix);

    var nsg = try s.client.beginCreateSecurityGroup(sub, "rg", "pb-nsg", .{ .location = "eastus2", .rules = &.{.{
        .name = "AllowSsh",
        .priority = 100,
        .direction = .inbound,
        .access = .allow,
        .protocol = .tcp,
        .source_address_prefixes = &.{ "203.0.113.0/24", "198.51.100.7" },
        .destination_port_ranges = &.{"22"},
    }} });
    defer nsg.deinit();
    try testing.expectEqualStrings("{\"location\":\"eastus2\",\"tags\":{},\"properties\":{\"securityRules\":[{\"name\":\"AllowSsh\",\"properties\":{\"priority\":100,\"direction\":\"Inbound\",\"access\":\"Allow\",\"protocol\":\"Tcp\",\"sourceAddressPrefixes\":[\"203.0.113.0/24\",\"198.51.100.7\"],\"sourcePortRange\":\"*\",\"destinationAddressPrefix\":\"*\",\"destinationPortRange\":\"22\"}}]}}", (try s.fake.streamRequest(1)).body_prefix);
}

test "a DELETE answered 204 is done, with nothing to poll" {
    const script = [_]core.testing.FakeTransport.Reply{.{ .respond = .{ .status = 204, .body = "" } }};
    var s: Scripted = undefined;
    try s.init(&script);
    defer s.deinit();
    var op = try s.client.beginDeleteVirtualNetwork(sub, "rg", "pb-vnet");
    defer op.deinit();
    try testing.expectEqual(.succeeded, op.value.state);
    try testing.expectEqual(.DELETE, (try s.fake.streamRequest(0)).method);
}

test "answers read leniently: nulls and missing fields are empty, unknown values unknown" {
    const script = [_]core.testing.FakeTransport.Reply{
        .{ .respond = .{ .body = "{\"name\":\"pb-vnet\",\"tags\":null,\"properties\":{\"addressSpace\":null,\"subnets\":[{\"name\":\"w\",\"properties\":{\"addressPrefixes\":[\"10.0.1.0/24\",\"10.0.2.0/24\"],\"serviceEndpoints\":null,\"natGateway\":null}},{\"name\":\"bare\"}]}}" } },
        .{ .respond = .{ .body = "{\"name\":\"pb-nsg\",\"properties\":{\"securityRules\":[{\"name\":\"x\",\"properties\":{\"priority\":300,\"direction\":\"Sideways\",\"access\":\"Maybe\",\"protocol\":\"Sctp\",\"sourcePortRanges\":[\"1\",\"2\"]}}]}}" } },
        .{ .respond = .{ .body = "<html>proxy</html>" } },
    };
    var s: Scripted = undefined;
    try s.init(&script);
    defer s.deinit();

    var n = try s.client.getVirtualNetwork(sub, "rg", "pb-vnet");
    defer n.deinit();
    try testing.expectEqual(0, n.value.tags.len);
    try testing.expectEqual(0, n.value.address_prefixes.len);
    try testing.expectEqual(2, n.value.subnets[0].address_prefixes.len);
    try testing.expectEqual(null, n.value.subnets[0].default_outbound_access);
    try testing.expect(n.value.subnets[0].defaultOutbound());
    try testing.expectEqual(0, n.value.subnets[1].address_prefixes.len);

    var g = try s.client.getSecurityGroup(sub, "rg", "pb-nsg");
    defer g.deinit();
    const r = g.value.rules[0];
    try testing.expectEqual(.unknown, r.direction);
    try testing.expectEqual(.unknown, r.access);
    try testing.expectEqual(.unknown, r.protocol);
    try testing.expectEqual(2, r.source_port_ranges.len);
    try testing.expectEqual(0, r.source_address_prefixes.len);
    try testing.expectEqual(0, g.value.default_rules.len);

    try testing.expectError(error.InvalidResponse, s.client.getSubnet(sub, "rg", "pb-vnet", "w"));
    try testing.expectStringStartsWith(s.diag.message(), "a subnet is not the JSON ARM sends");
}

test "an operation URL off ARM's origin is refused" {
    const script = [_]core.testing.FakeTransport.Reply{.{ .respond = .{
        .status = 201,
        .headers = &.{.{ .name = "Azure-AsyncOperation", .value = "https://evil.example/op" }},
        .body = "{}",
    } }};
    var s: Scripted = undefined;
    try s.init(&script);
    defer s.deinit();
    try testing.expectError(error.InvalidEndpoint, s.client.beginCreateSecurityGroup(sub, "rg", "pb-nsg", .{ .location = "eastus2" }));
}
