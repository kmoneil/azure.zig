//! The compute client over bodies production sent (t19's m0, 2026-11-07,
//! the ids replaced), Azure's spec example of an instance view, and
//! FakeCompute.

const std = @import("std");
const testing = std.testing;
const core = @import("core");
const compute = @import("root.zig");
const Client = compute.Client;
const FakeCompute = compute.testing.FakeCompute;
const FakeTransport = core.testing.FakeTransport;

const sub = "00000000-0000-4000-8000-0000000000aa";

const vm_created = @embedFile("testdata/vm_created.json");
const skus_eastus2 = @embedFile("testdata/skus_eastus2.json");
const locations = @embedFile("testdata/locations.json");
const instance_view_spec = @embedFile("testdata/instance_view_spec.json");

/// A client over a scripted transport, its requests kept.
const Scripted = struct {
    fake: FakeTransport,
    clock: compute.testing.FakeClock,
    token: compute.StaticToken,
    diag: compute.Diagnostics,
    client: Client,

    fn init(s: *Scripted, script: []const FakeTransport.Reply) !void {
        s.fake = .init(testing.allocator, script);
        s.clock = .{};
        s.token = .{ .token = "t" };
        s.diag = .{};
        s.client = try .init(testing.allocator, s.clock.io(), .{ .token_provider = s.token.provider(), .transport = s.fake.transport(), .diagnostics = &s.diag });
    }

    fn deinit(s: *Scripted) void {
        s.client.deinit();
        s.fake.deinit();
    }
};

fn ok(body: []const u8) FakeTransport.Reply {
    return .{ .respond = .{ .status = 200, .body = body } };
}

/// The production VM body with Azure's example instance view in it, as a
/// GET with `$expand=instanceView` answers.
fn withInstanceView(arena: std.mem.Allocator, view: []const u8) ![]const u8 {
    var vm = try std.json.parseFromSliceLeaky(std.json.Value, arena, vm_created, .{});
    const iv = try std.json.parseFromSliceLeaky(std.json.Value, arena, view, .{});
    try vm.object.getPtr("properties").?.object.put(arena, "instanceView", iv);
    return std.json.Stringify.valueAlloc(arena, vm, .{});
}

test "a VM as production answered its create: spot, deleted on eviction, still creating" {
    var s: Scripted = undefined;
    try s.init(&.{ok(vm_created)});
    defer s.deinit();
    var vm = try s.client.getVirtualMachine(sub, "rg", "m0-vm1");
    defer vm.deinit();
    const v = vm.value;
    try testing.expectEqualStrings("m0-vm1", v.name);
    try testing.expectEqualStrings("eastus2", v.location);
    try testing.expectEqualStrings("Standard_D2ds_v5", v.size);
    try testing.expectEqual(compute.Priority.spot, v.priority);
    try testing.expectEqual(compute.EvictionPolicy.delete, v.eviction_policy.?);
    try testing.expectEqual(-1, v.max_price.?);
    try testing.expectEqual(null, v.zone);
    try testing.expectEqual(compute.Provisioning.creating, v.state.provisioning);
    try testing.expectEqual(null, v.state.power);
    try testing.expectEqualStrings("m0", v.tag("azzig-job").?);
    try testing.expect(v.vm_id.len == 36);
    const req = try s.fake.request(0);
    try testing.expectEqualStrings("https://management.azure.com/subscriptions/" ++ sub ++ "/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/m0-vm1?api-version=2026-04-01&$expand=instanceView", req.url);
}

test "a VM's state from its instance view: running, and a failed allocation" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const running = try withInstanceView(arena.allocator(), instance_view_spec);
    const failed = try withInstanceView(arena.allocator(), "{\"statuses\":[{\"code\":\"ProvisioningState/failed/AllocationFailed\",\"level\":\"Error\"},{\"code\":\"PowerState/deallocated\"}]}");
    var s: Scripted = undefined;
    try s.init(&.{ ok(running), ok(failed) });
    defer s.deinit();
    var a = try s.client.getVirtualMachine(sub, "rg", "m0-vm1");
    defer a.deinit();
    try testing.expect(a.value.state.isRunning());
    var b = try s.client.getVirtualMachine(sub, "rg", "m0-vm1");
    defer b.deinit();
    try testing.expect(b.value.state.isFailed());
    try testing.expectEqualStrings("AllocationFailed", b.value.state.failure);
    try testing.expectEqual(compute.Power.deallocated, b.value.state.power.?);
}

test "sizes as production offered them: D2ds_v5 in zone 4 alone, D2as_v5 not at all" {
    var s: Scripted = undefined;
    try s.init(&.{ok(skus_eastus2)});
    defer s.deinit();
    var sizes = try s.client.listSizes(sub, "eastus2");
    defer sizes.deinit();
    var names: [4][]const u8 = undefined;
    for (sizes.value, 0..) |size, i| names[i] = size.name;
    // D2as_v5 and B2s carry a Location restriction: gone.
    try testing.expectEqual(2, sizes.value.len);
    var d2ds: ?compute.Size = null;
    for (sizes.value) |size| if (std.mem.eql(u8, size.name, "Standard_D2ds_v5")) {
        d2ds = size;
    };
    const d = d2ds.?;
    try testing.expectEqual(2, d.vcpus);
    try testing.expectEqual(8, d.memory_gb);
    try testing.expect(d.spot and d.ephemeral_os_disk);
    try testing.expectEqual(76800, d.resource_disk_mb);
    try testing.expectEqual(1, d.zones.len);
    try testing.expectEqualStrings("4", d.zones[0]);
    var buf: [4]compute.Size = undefined;
    const fit = compute.sizesThatFit(&buf, sizes.value, .{ .spot = true, .ephemeral_os_disk = true });
    try testing.expectEqual(1, fit.len);
    try testing.expectEqualStrings("Standard_D2ds_v5", fit[0].name);
    try testing.expectEqual(0, compute.sizesThatFit(&buf, sizes.value, .{ .zone = "1" }).len);
    const req = try s.fake.request(0);
    try testing.expectStringEndsWith(req.url, "/providers/Microsoft.Compute/skus?api-version=2021-07-01&$filter=location%20eq%20%27eastus2%27");
}

test "locations as production listed them: eastus2's four zones and where each is" {
    var s: Scripted = undefined;
    try s.init(&.{ok(locations)});
    defer s.deinit();
    var list = try s.client.listLocations(sub);
    defer list.deinit();
    try testing.expectEqual(2, list.value.len);
    for (list.value) |l| if (std.mem.eql(u8, l.name, "eastus2")) {
        try testing.expectEqualStrings("East US 2", l.display_name);
        try testing.expectEqual(4, l.zones.len);
        for (l.zones) |z| if (std.mem.eql(u8, z.logical, "4")) try testing.expectEqualStrings("eastus2-az5", z.physical);
    };
}

test "usages: the spot quota by name" {
    var s: Scripted = undefined;
    try s.init(&.{ok("{\"value\":[{\"limit\":10,\"unit\":\"Count\",\"currentValue\":0,\"name\":{\"value\":\"cores\",\"localizedValue\":\"Total Regional vCPUs\"}},{\"limit\":3,\"unit\":\"Count\",\"currentValue\":2,\"name\":{\"value\":\"lowPriorityCores\",\"localizedValue\":\"Total Regional Low-priority vCPUs\"}}]}")});
    defer s.deinit();
    var usages = try s.client.listUsages(sub, "eastus2");
    defer usages.deinit();
    const spot = compute.findUsage(usages.value, compute.spot_cores).?;
    try testing.expectEqual(3, spot.limit);
    try testing.expectEqual(2, spot.current);
    try testing.expectEqual(null, compute.findUsage(usages.value, "nothing"));
}

/// A client over FakeCompute.
const Rig = struct {
    fake: FakeCompute,
    clock: compute.testing.FakeClock,
    token: compute.StaticToken,
    diag: compute.Diagnostics,
    client: Client,

    fn init(r: *Rig) !void {
        r.fake = try .init(testing.allocator);
        r.clock = .{};
        r.token = .{ .token = "t" };
        r.diag = .{};
        r.client = try .init(testing.allocator, r.clock.io(), .{ .token_provider = r.token.provider(), .transport = r.fake.transport(), .diagnostics = &r.diag });
    }

    fn deinit(r: *Rig) void {
        r.client.deinit();
        r.fake.deinit();
    }
};

test "FakeCompute: a VM's states, lists by scope over pages, and a tag filter" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    r.fake.page_size = 2;
    const job: []const FakeCompute.Tag = &.{.{ .name = "job", .value = "j1" }};
    try r.fake.addVm(.{ .subscription = sub, .group = "rg", .name = "w1", .tags = job });
    try r.fake.addVm(.{ .subscription = sub, .group = "rg", .name = "w2", .tags = job, .provisioning = "Creating", .power = "starting" });
    try r.fake.addVm(.{ .subscription = sub, .group = "rg", .name = "w3", .provisioning = "Failed", .failure = "AllocationFailed", .power = null });
    try r.fake.addVm(.{ .subscription = sub, .group = "other", .name = "x1", .location = "westus2", .zone = "2" });
    // The same tag with another value: the filter must compare the value.
    try r.fake.addVm(.{ .subscription = sub, .group = "other", .name = "x2", .tags = &.{.{ .name = "job", .value = "j2" }} });

    var w1 = try r.client.getVirtualMachine(sub, "rg", "w1");
    defer w1.deinit();
    try testing.expect(w1.value.state.isRunning());
    var w2 = try r.client.getVirtualMachine(sub, "rg", "w2");
    defer w2.deinit();
    try testing.expectEqual(compute.Power.starting, w2.value.state.power.?);
    var w3 = try r.client.getVirtualMachine(sub, "rg", "w3");
    defer w3.deinit();
    try testing.expect(w3.value.state.isFailed());
    try testing.expectEqualStrings("AllocationFailed", w3.value.state.failure);
    try testing.expectError(error.NotFound, r.client.getVirtualMachine(sub, "rg", "absent"));
    try testing.expectEqualStrings("ResourceNotFound", r.diag.code());

    var all = try r.client.listVirtualMachines(sub, .subscription, .{});
    defer all.deinit();
    try testing.expectEqual(5, all.value.len);
    var in_rg = try r.client.listVirtualMachines(sub, .{ .group = "rg" }, .{});
    defer in_rg.deinit();
    try testing.expectEqual(3, in_rg.value.len);
    // A list has no instance view: provisioning, no power.
    try testing.expectEqual(null, in_rg.value[0].state.power);
    var west = try r.client.listVirtualMachines(sub, .{ .location = "westus2" }, .{});
    defer west.deinit();
    try testing.expectEqual(1, west.value.len);
    try testing.expectEqualStrings("2", west.value[0].zone.?);
    var tagged = try r.client.listVirtualMachines(sub, .subscription, .{ .tag = .{ .name = "job", .value = "j1" } });
    defer tagged.deinit();
    try testing.expectEqual(2, tagged.value.len);
    // Five VMs two to a page: three requests for each of the two lists.
    var pages: usize = 0;
    for (r.fake.calls.items) |c| if (std.mem.startsWith(u8, c.path, "/subscriptions/" ++ sub ++ "/providers/Microsoft.Compute/virtualMachines")) {
        pages += 1;
    };
    try testing.expectEqual(6, pages);
}

test "FakeCompute: the measured sizes, zones and quotas" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    try r.fake.addMeasuredSizes();
    var sizes = try r.client.listSizes(sub, "eastus2");
    defer sizes.deinit();
    try testing.expectEqual(2, sizes.value.len);
    for (sizes.value) |s| {
        try testing.expectEqual(1, s.zones.len);
        try testing.expectEqualStrings("4", s.zones[0]);
    }
    var none = try r.client.listSizes(sub, "westus2");
    defer none.deinit();
    try testing.expectEqual(0, none.value.len);
    var locs = try r.client.listLocations(sub);
    defer locs.deinit();
    try testing.expectEqual(2, locs.value.len);
    var usages = try r.client.listUsages(sub, "eastus2");
    defer usages.deinit();
    try testing.expectEqual(3, compute.findUsage(usages.value, compute.spot_cores).?.limit);
}

test "refused before anything is sent" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    try testing.expectError(error.InvalidArgument, r.client.getVirtualMachine("not-a-guid", "rg", "w1"));
    try testing.expectError(error.InvalidArgument, r.client.getVirtualMachine(sub, "rg", "a/b"));
    try testing.expectError(error.InvalidArgument, r.client.getVirtualMachine(sub, "bad group!", "w1"));
    try testing.expectError(error.InvalidArgument, r.client.listVirtualMachines(sub, .{ .location = "east us" }, .{}));
    try testing.expectError(error.InvalidArgument, r.client.listSizes(sub, "east'us"));
    try testing.expectError(error.InvalidArgument, r.client.listUsages("x", "eastus2"));
    try testing.expectEqual(0, r.fake.calls.items.len);
}

test "a next link off ARM's origin is refused" {
    var s: Scripted = undefined;
    try s.init(&.{ok("{\"value\":[],\"nextLink\":\"https://evil.example/subscriptions/x/providers/Microsoft.Compute/virtualMachines?page=2\"}")});
    defer s.deinit();
    try testing.expectError(error.InvalidEndpoint, s.client.listVirtualMachines(sub, .subscription, .{}));
}
