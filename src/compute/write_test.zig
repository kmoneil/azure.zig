//! The compute client's writes: a `VmSpec`'s body and checks, previews,
//! and creates, deletes, power and evictions over FakeCompute, with a
//! scripted transport where a failure must be exact.

const std = @import("std");
const testing = std.testing;
const core = @import("core");
const compute = @import("root.zig");
const Rig = @import("Client_test.zig").Rig;
const Scripted = @import("Client_test.zig").Scripted;
const FakeCompute = compute.testing.FakeCompute;

const sub = "00000000-0000-4000-8000-0000000000aa";
const subnet = "/subscriptions/" ++ sub ++ "/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/pb-vnet/subnets/workers";
const identity = "/subscriptions/" ++ sub ++ "/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/pb-worker";
const nsg = "/subscriptions/" ++ sub ++ "/resourceGroups/rg/providers/Microsoft.Network/networkSecurityGroups/pb-nsg";
const key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGV4YW1wbGUga2V5LCBub3QgYSByZWFsIG9uZSwgYXp6aWc azzig@example";
const vms = "https://management.azure.com/subscriptions/" ++ sub ++ "/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/";

/// A spot worker as puffball makes one: D2ds_v7 in zone 2, its OS disk
/// ephemeral on the NVMe disk, which v7 takes alone.
fn worker(attempt: []const u8) compute.VmSpec {
    return .{
        .location = "eastus2",
        .size = "Standard_D2ds_v7",
        .zone = "2",
        .os_disk = .{ .ephemeral = .nvme_disk },
        .disk_controller = .nvme,
        .admin_username = "azzig",
        .ssh_public_keys = &.{key},
        .nic = .{ .subnet = subnet },
        .tags = &.{.{ .name = "pb-job", .value = "j1" }},
        .attempt_tag = .{ .name = "pb-attempt", .value = attempt },
    };
}

/// The value at `keys` in `v`, objects and array indexes alike.
fn at(v: std.json.Value, keys: []const []const u8) !std.json.Value {
    var cur = v;
    for (keys) |k| cur = switch (cur) {
        .object => |o| o.get(k) orelse return error.TestNoSuchField,
        .array => |a| a.items[try std.fmt.parseInt(usize, k, 10)],
        else => return error.TestNoSuchField,
    };
    return cur;
}

fn expectText(want: []const u8, v: std.json.Value, keys: []const []const u8) !void {
    try testing.expectEqualStrings(want, (try at(v, keys)).string);
}

fn absent(v: std.json.Value, keys: []const []const u8) bool {
    _ = at(v, keys) catch return true;
    return false;
}

fn decoded(arena: std.mem.Allocator, v: std.json.Value, keys: []const []const u8) ![]const u8 {
    return core.base64.decode(arena, (try at(v, keys)).string);
}

test "a spec's body: spot, deleted on eviction, Trusted Launch, ephemeral on the NVMe disk, one NIC made with the VM" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var spec = worker("a1");
    spec.custom_data = "#cloud-config\nruncmd: [\"/opt/pb/worker\"]\n";
    spec.user_data = "job=j1\x00\xff";
    spec.identities = &.{identity};
    const p = try r.client.preview(a, sub, "rg", "pb-j1-s0", .{ .create = spec });
    try testing.expectEqual(.PUT, p.method);
    try testing.expectEqualStrings(vms ++ "pb-j1-s0?api-version=2026-04-01", p.url);
    // A preview sends nothing.
    try testing.expectEqual(0, r.fake.calls.items.len);

    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, p.body, .{});
    try expectText("eastus2", v, &.{"location"});
    try expectText("2", v, &.{ "zones", "0" });
    try expectText("j1", v, &.{ "tags", "pb-job" });
    try expectText("a1", v, &.{ "tags", "pb-attempt" });
    try expectText("UserAssigned", v, &.{ "identity", "type" });
    try testing.expect(!absent(v, &.{ "identity", "userAssignedIdentities", identity }));
    const props = try at(v, &.{"properties"});
    try expectText("Spot", props, &.{"priority"});
    try expectText("Delete", props, &.{"evictionPolicy"});
    try testing.expectEqual(-1, (try at(props, &.{ "billingProfile", "maxPrice" })).integer);
    try expectText("Standard_D2ds_v7", props, &.{ "hardwareProfile", "vmSize" });
    try expectText("TrustedLaunch", props, &.{ "securityProfile", "securityType" });
    try testing.expect((try at(props, &.{ "securityProfile", "uefiSettings", "secureBootEnabled" })).bool);
    try testing.expect((try at(props, &.{ "securityProfile", "uefiSettings", "vTpmEnabled" })).bool);
    try expectText("Canonical", props, &.{ "storageProfile", "imageReference", "publisher" });
    try expectText("ubuntu-24_04-lts", props, &.{ "storageProfile", "imageReference", "offer" });
    try expectText("server", props, &.{ "storageProfile", "imageReference", "sku" });
    try expectText("latest", props, &.{ "storageProfile", "imageReference", "version" });
    try expectText("NVMe", props, &.{ "storageProfile", "diskControllerType" });
    const disk = try at(props, &.{ "storageProfile", "osDisk" });
    try expectText("FromImage", disk, &.{"createOption"});
    try expectText("Delete", disk, &.{"deleteOption"});
    try expectText("ReadOnly", disk, &.{"caching"});
    try expectText("Local", disk, &.{ "diffDiskSettings", "option" });
    try expectText("NvmeDisk", disk, &.{ "diffDiskSettings", "placement" });
    try expectText("Standard_LRS", disk, &.{ "managedDisk", "storageAccountType" });
    try testing.expect(absent(disk, &.{"diskSizeGB"}));
    try expectText("pb-j1-s0", props, &.{ "osProfile", "computerName" });
    try expectText("azzig", props, &.{ "osProfile", "adminUsername" });
    try testing.expectEqualStrings(spec.custom_data, try decoded(a, props, &.{ "osProfile", "customData" }));
    try testing.expectEqualStrings(spec.user_data, try decoded(a, props, &.{"userData"}));
    try testing.expect((try at(props, &.{ "osProfile", "linuxConfiguration", "disablePasswordAuthentication" })).bool);
    try expectText("/home/azzig/.ssh/authorized_keys", props, &.{ "osProfile", "linuxConfiguration", "ssh", "publicKeys", "0", "path" });
    try expectText(key, props, &.{ "osProfile", "linuxConfiguration", "ssh", "publicKeys", "0", "keyData" });
    const nic = try at(props, &.{ "networkProfile", "networkInterfaceConfigurations", "0" });
    try expectText("2022-11-01", props, &.{ "networkProfile", "networkApiVersion" });
    try expectText("pb-j1-s0-nic", nic, &.{"name"});
    try expectText("a1", nic, &.{ "tags", "pb-attempt" });
    try expectText("Delete", nic, &.{ "properties", "deleteOption" });
    try testing.expect((try at(nic, &.{ "properties", "primary" })).bool);
    try expectText(subnet, nic, &.{ "properties", "ipConfigurations", "0", "properties", "subnet", "id" });
    try testing.expect(absent(nic, &.{ "properties", "ipConfigurations", "0", "properties", "publicIPAddressConfiguration" }));
    try testing.expect(absent(nic, &.{ "properties", "networkSecurityGroup" }));
    try testing.expect((try at(props, &.{ "diagnosticsProfile", "bootDiagnostics", "enabled" })).bool);
}

test "a regular VM on a managed disk, without Trusted Launch, with a public IP and a NIC of the caller's naming" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var spec = worker("a1");
    spec.priority = .regular;
    spec.zone = null;
    spec.os_disk = .{ .managed = .{ .type = .premium_lrs, .size_gb = 64 } };
    spec.disk_controller = null;
    spec.security = .standard;
    spec.image = .{ .id = "/subscriptions/" ++ sub ++ "/resourceGroups/rg/providers/Microsoft.Compute/galleries/pb/images/worker/versions/1.0.0" };
    spec.nic = .{ .subnet = subnet, .name = "w-nic", .security_group = nsg, .accelerated_networking = true, .public_ip = true };
    spec.computer_name = "worker-host";
    spec.boot_diagnostics = false;
    const p = try r.client.preview(a, sub, "rg", "w1", .{ .create = spec });
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, p.body, .{});
    try testing.expect(absent(v, &.{"zones"}));
    try testing.expect(absent(v, &.{"identity"}));
    const props = try at(v, &.{"properties"});
    try expectText("Regular", props, &.{"priority"});
    try testing.expect(absent(props, &.{"evictionPolicy"}));
    try testing.expect(absent(props, &.{"billingProfile"}));
    try expectText("Standard", props, &.{ "securityProfile", "securityType" });
    try testing.expect(absent(props, &.{ "securityProfile", "uefiSettings" }));
    try expectText(spec.image.id, props, &.{ "storageProfile", "imageReference", "id" });
    try testing.expect(absent(props, &.{ "storageProfile", "diskControllerType" }));
    const disk = try at(props, &.{ "storageProfile", "osDisk" });
    try expectText("ReadWrite", disk, &.{"caching"});
    try expectText("Premium_LRS", disk, &.{ "managedDisk", "storageAccountType" });
    try testing.expectEqual(64, (try at(disk, &.{"diskSizeGB"})).integer);
    try testing.expect(absent(disk, &.{"diffDiskSettings"}));
    try expectText("worker-host", props, &.{ "osProfile", "computerName" });
    try testing.expect(absent(props, &.{ "osProfile", "customData" }));
    try testing.expect(absent(props, &.{"userData"}));
    const nic = try at(props, &.{ "networkProfile", "networkInterfaceConfigurations", "0" });
    try expectText("w-nic", nic, &.{"name"});
    try expectText(nsg, nic, &.{ "properties", "networkSecurityGroup", "id" });
    try testing.expect((try at(nic, &.{ "properties", "enableAcceleratedNetworking" })).bool);
    const ip = try at(nic, &.{ "properties", "ipConfigurations", "0", "properties", "publicIPAddressConfiguration" });
    try expectText("w1-ip", ip, &.{"name"});
    try expectText("Standard", ip, &.{ "sku", "name" });
    try expectText("Delete", ip, &.{ "properties", "deleteOption" });
    try testing.expect(!(try at(props, &.{ "diagnosticsProfile", "bootDiagnostics", "enabled" })).bool);
}

test "previews of the other writes: their methods and URLs, and no body" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { compute.Write, compute.transport.Method, []const u8 }{
        .{ .{ .delete = .{ .force = true } }, .DELETE, "w1?api-version=2026-04-01&forceDeletion=true" },
        .{ .{ .delete = .{} }, .DELETE, "w1?api-version=2026-04-01" },
        .{ .deallocate, .POST, "w1/deallocate?api-version=2026-04-01" },
        .{ .start, .POST, "w1/start?api-version=2026-04-01" },
        .{ .restart, .POST, "w1/restart?api-version=2026-04-01" },
        .{ .simulate_eviction, .POST, "w1/simulateEviction?api-version=2026-04-01" },
    };
    inline for (cases) |c| {
        const p = try r.client.preview(a, sub, "rg", "w1", c[0]);
        try testing.expectEqual(c[1], p.method);
        try testing.expectEqualStrings(vms ++ c[2], p.url);
        try testing.expectEqualStrings("", p.body);
    }
    const raw = "{\"location\":\"eastus2\",\"properties\":{}}";
    const p = try r.client.preview(a, sub, "rg", "w1", .{ .create_raw = raw });
    try testing.expectEqualStrings(raw, p.body);
    try testing.expectError(error.InvalidArgument, r.client.preview(a, sub, "rg", "w/1", .deallocate));
    try testing.expectEqual(0, r.fake.calls.items.len);
}

test "a spec Compute would refuse is refused before anything is sent" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    var big: [compute.max_data_len + 1]u8 = @splat('x');
    var names: [compute.max_tags][4]u8 = undefined;
    var many: [compute.max_tags]compute.Tag = undefined;
    for (&many, &names, 0..) |*t, *n, i| t.* = .{ .name = try std.fmt.bufPrint(n, "t{d}", .{i}), .value = "" };
    const Case = enum { location, size, zone, eviction, max_price, ephemeral_deallocated, disk_size, image, image_id, admin, root, no_keys, key, host, computer_name, custom_data, user_data, subnet, subnet_name, nic_name, nsg, identity, identity_twice, tag, tags_alike, too_many_tags };
    for (std.enums.values(Case)) |c| {
        var spec = worker("a1");
        var name: []const u8 = "w1";
        switch (c) {
            .location => spec.location = "east us",
            .size => spec.size = "Standard D2",
            .zone => spec.zone = "1/2",
            .eviction => spec.priority = .{ .spot = .{ .eviction_policy = .unknown } },
            .max_price => spec.priority = .{ .spot = .{ .max_price = 0 } },
            .ephemeral_deallocated => spec.priority = .{ .spot = .{ .eviction_policy = .deallocate } },
            .disk_size => spec.os_disk = .{ .managed = .{ .size_gb = 4096 } },
            .image => spec.image = .{ .marketplace = .{ .publisher = "Canonical", .offer = "", .sku = "server" } },
            .image_id => spec.image = .{ .id = "images/worker" },
            .admin => spec.admin_username = "9lives",
            .root => spec.admin_username = "Root",
            .no_keys => spec.ssh_public_keys = &.{},
            .key => spec.ssh_public_keys = &.{"ssh-ed25519 AAAA\nssh-rsa BBBB"},
            .host => name = "pb_worker.1",
            .computer_name => spec.computer_name = "-worker",
            .custom_data => spec.custom_data = &big,
            .user_data => spec.user_data = &big,
            .subnet => spec.nic.subnet = "workers",
            .subnet_name => spec.nic.subnet = "/subscriptions/" ++ sub ++ "/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/pb-vnet/subnets/../x",
            .nic_name => spec.nic.name = "nic/0",
            .nsg => spec.nic.security_group = subnet,
            .identity => spec.identities = &.{"pb-worker"},
            .identity_twice => spec.identities = &.{ identity, "/SUBSCRIPTIONS/" ++ sub ++ "/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/PB-WORKER" },
            .tag => spec.tags = &.{.{ .name = "a/b", .value = "1" }},
            .tags_alike => spec.attempt_tag = .{ .name = "PB-JOB", .value = "j2" },
            .too_many_tags => spec.tags = &many,
        }
        r.diag = .{};
        if (r.client.beginCreateVirtualMachine(sub, "rg", name, spec)) |op| {
            var o = op;
            o.deinit();
            std.debug.print("case {t} was not refused\n", .{c});
            return error.TestUnexpectedResult;
        } else |err| try testing.expectEqual(error.InvalidArgument, err);
        try testing.expect(r.diag.message().len > 0);
    }
    try testing.expectEqual(0, r.fake.calls.items.len);
    // A VM's name that is no host name, with a computer_name that is one.
    var spec = worker("a1");
    spec.computer_name = "pb-worker-1";
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    _ = try r.client.preview(arena.allocator(), sub, "rg", "pb_worker.1", .{ .create = spec });
    try testing.expectError(error.InvalidArgument, r.client.preview(arena.allocator(), sub, "rg", "w1", .{ .create_raw = "[1]" }));
    try testing.expectError(error.InvalidArgument, r.client.preview(arena.allocator(), sub, "rg", "w1", .{ .create_raw = "{" }));
}

test "a create over FakeCompute: If-None-Match, waited to running, its NIC named by Azure, its cores counted" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    try r.fake.addMeasuredSizes();
    var op = try r.client.beginCreateVirtualMachine(sub, "rg", "w1", worker("a1"));
    defer op.deinit();
    try testing.expectEqual(.running, op.value.state);
    try testing.expectEqual(.async_operation, op.value.follow);
    try testing.expectEqualStrings("*", r.fake.calls.items[0].if_none_match.?);
    try r.client.waitOperation(&op, 120_000);
    try testing.expectEqual(.succeeded, op.value.state);
    var vm = try r.client.getVirtualMachine(sub, "rg", "w1");
    defer vm.deinit();
    try testing.expect(vm.value.state.isRunning());
    try testing.expectEqualStrings("2", vm.value.zone.?);
    try testing.expectEqual(compute.Priority.spot, vm.value.priority);
    try testing.expectEqualStrings("a1", vm.value.tag("pb-attempt").?);
    try testing.expectEqual(1, vm.value.nics.len);
    try testing.expectStringStartsWith(vm.value.nics[0], "/subscriptions/" ++ sub ++ "/resourceGroups/rg/providers/Microsoft.Network/networkInterfaces/w1-nic-");
    try testing.expectEqual(2, r.fake.findUsage("eastus2", compute.spot_cores).?.current);
}

test "a create met again: its own by the attempt tag, another's refused, and none read without a tag" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    try r.fake.addMeasuredSizes();
    var first = try r.client.beginCreateVirtualMachine(sub, "rg", "w1", worker("a1"));
    defer first.deinit();
    try r.client.waitOperation(&first, 120_000);

    // The same attempt again: 412, then the VM read, made already.
    const before = r.fake.calls.items.len;
    var again = try r.client.beginCreateVirtualMachine(sub, "rg", "w1", worker("a1"));
    defer again.deinit();
    try testing.expectEqual(.succeeded, again.value.state);
    try testing.expectEqual(.provisioning_state, again.value.follow);
    try testing.expectEqual(0, r.diag.http_status);
    try testing.expectEqual(before + 2, r.fake.calls.items.len);
    try testing.expectEqual(.PUT, r.fake.calls.items[before].method);
    try testing.expectEqual(.GET, r.fake.calls.items[before + 1].method);

    // Another attempt's VM: the 412 stands.
    try testing.expectError(error.PreconditionFailed, r.client.beginCreateVirtualMachine(sub, "rg", "w1", worker("a2")));
    try testing.expectEqual(412, r.diag.http_status);
    try testing.expectEqualStrings("PreconditionFailed", r.diag.code());

    // No attempt tag: nothing to read the VM for.
    var spec = worker("a1");
    spec.attempt_tag = null;
    const untagged = r.fake.calls.items.len;
    try testing.expectError(error.PreconditionFailed, r.client.beginCreateVirtualMachine(sub, "rg", "w1", spec));
    try testing.expectEqual(untagged + 1, r.fake.calls.items.len);
    try testing.expectEqual(1, r.fake.vms.items.len);
    try testing.expectEqual(2, r.fake.findUsage("eastus2", compute.spot_cores).?.current);
}

test "a create whose answer was lost: the loop's retry meets the VM, and takes it for its own" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    try r.fake.addMeasuredSizes();
    r.fake.operation_polls = 2;
    r.fake.lose_next_create = true;
    var op = try r.client.beginCreateVirtualMachine(sub, "rg", "w1", worker("a1"));
    defer op.deinit();
    // 504, the retry's 412, then the VM read: still being made.
    try testing.expectEqual(3, r.fake.calls.items.len);
    try testing.expectEqual(.GET, r.fake.calls.items[2].method);
    try testing.expectEqual(.provisioning_state, op.value.follow);
    try testing.expectEqual(.running, op.value.state);
    try r.client.waitOperation(&op, 120_000);
    try testing.expectEqual(.succeeded, op.value.state);
    try testing.expectEqual(1, r.fake.vms.items.len);
    try testing.expectEqual(2, r.fake.findUsage("eastus2", compute.spot_cores).?.current);
}

test "a lost answer with no VM behind it: the PUT's own failure and its diagnostics" {
    var s: Scripted = undefined;
    const refused = comptime core.testing.armRefusal(500, "InternalServerError", "An internal error occurred.");
    try s.init(&.{ refused, refused, refused, refused, core.testing.armRefusal(404, "ResourceNotFound", "The Resource was not found.") });
    defer s.deinit();
    try testing.expectError(error.ServerError, s.client.beginCreateVirtualMachine(sub, "rg", "w1", worker("a1")));
    try testing.expectEqual(500, s.diag.http_status);
    try testing.expectEqualStrings("InternalServerError", s.diag.code());
    // Four attempts at the PUT, streamed, then the read of the VM.
    try testing.expectEqual(.PUT, (try s.fake.streamRequest(3)).method);
    const read = try s.fake.request(0);
    try testing.expectEqual(.GET, read.method);
    try testing.expectStringEndsWith(read.url, "/virtualMachines/w1?api-version=2026-04-01");
}

test "refusals by kind: a quota and capacity are refusals of their own, and no VM is read for them" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    try r.fake.addMeasuredSizes();
    var first = try r.client.beginCreateVirtualMachine(sub, "rg", "w1", worker("a1"));
    defer first.deinit();

    // Two spot vCPUs more than the three allowed.
    var calls = r.fake.calls.items.len;
    try testing.expectError(error.Conflict, r.client.beginCreateVirtualMachine(sub, "rg", "w2", worker("a1")));
    try testing.expectEqual(compute.RefusalClass.quota, compute.RefusalClass.ofDiagnostics(&r.diag));
    try testing.expect(std.mem.indexOf(u8, r.diag.message(), "LowPriorityCores") != null);
    try testing.expectEqual(calls + 1, r.fake.calls.items.len);

    // D2ds_v5 in a zone restricted for the subscription, and D2as_v5 anywhere.
    var spec = worker("a1");
    spec.size = "Standard_D2ds_v5";
    spec.zone = "1";
    spec.os_disk = .{ .ephemeral = .resource_disk };
    spec.disk_controller = null;
    r.fake.findUsage("eastus2", compute.spot_cores).?.limit = 10;
    calls = r.fake.calls.items.len;
    try testing.expectError(error.Conflict, r.client.beginCreateVirtualMachine(sub, "rg", "w3", spec));
    try testing.expectEqual(compute.RefusalClass.capacity, compute.RefusalClass.ofDiagnostics(&r.diag));
    try testing.expectEqual(calls + 1, r.fake.calls.items.len);
    spec.size = "Standard_D2as_v5";
    spec.zone = null;
    try testing.expectError(error.Conflict, r.client.beginCreateVirtualMachine(sub, "rg", "w3", spec));
    try testing.expectEqualStrings("SkuNotAvailable", r.diag.code());
}

test "a failed allocation: the operation fails as capacity, the VM stays Failed until deleted" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    try r.fake.addMeasuredSizes();
    try r.fake.failNextCreate("AllocationFailed", "Allocation failed. We do not have sufficient capacity for the requested VM size in this region.");
    var op = try r.client.beginCreateVirtualMachine(sub, "rg", "w1", worker("a1"));
    defer op.deinit();
    try r.client.waitOperation(&op, 120_000);
    try testing.expectEqual(.failed, op.value.state);
    try testing.expectEqualStrings("AllocationFailed", op.value.failure_code);
    try testing.expectEqual(compute.RefusalClass.capacity, compute.RefusalClass.ofOperation(&op.value));
    {
        var vm = try r.client.getVirtualMachine(sub, "rg", "w1");
        defer vm.deinit();
        try testing.expect(vm.value.state.isFailed());
        try testing.expectEqualStrings("AllocationFailed", vm.value.state.failure);
    }
    var gone = try r.client.beginDeleteVirtualMachine(sub, "rg", "w1", .{ .force = true });
    defer gone.deinit();
    try testing.expectStringEndsWith(r.fake.calls.items[r.fake.calls.items.len - 1].path, "&forceDeletion=true");
    try r.client.waitOperation(&gone, 120_000);
    try testing.expectEqual(.succeeded, gone.value.state);
    try testing.expectError(error.NotFound, r.client.getVirtualMachine(sub, "rg", "w1"));
    try testing.expectEqual(0, r.fake.findUsage("eastus2", compute.spot_cores).?.current);
}

test "an eviction: 204 at once, the VM gone some reads later, its cores freed" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    try r.fake.addMeasuredSizes();
    r.fake.eviction_reads = 2;
    var op = try r.client.beginCreateVirtualMachine(sub, "rg", "w1", worker("a1"));
    defer op.deinit();
    try r.client.waitOperation(&op, 120_000);
    try r.client.simulateEviction(sub, "rg", "w1");
    // As it was, then being deleted, as the live suite saw it.
    const seen = [_]compute.State{ .{ .provisioning = .succeeded, .power = .running }, .{ .provisioning = .deleting } };
    for (seen) |want| {
        var vm = try r.client.getVirtualMachine(sub, "rg", "w1");
        defer vm.deinit();
        try testing.expectEqual(want.provisioning, vm.value.state.provisioning);
        try testing.expectEqual(want.power, vm.value.state.power);
    }
    try testing.expectError(error.NotFound, r.client.getVirtualMachine(sub, "rg", "w1"));
    try testing.expectEqual(0, r.fake.findUsage("eastus2", compute.spot_cores).?.current);
    try testing.expectError(error.NotFound, r.client.simulateEviction(sub, "rg", "w1"));
}

test "deallocate, start and restart a VM on a managed disk; one with an ephemeral disk is not deallocated" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    try r.fake.addMeasuredSizes();
    var spec = worker("a1");
    spec.size = "Standard_D2s_v7";
    spec.os_disk = .{ .managed = .{ .size_gb = 30 } };
    var made = try r.client.beginCreateVirtualMachine(sub, "rg", "w1", spec);
    defer made.deinit();
    try r.client.waitOperation(&made, 120_000);
    const steps = [_]struct { *const fn (*compute.Client, []const u8, []const u8, []const u8) compute.Client.Error!compute.Owned(compute.Operation), compute.Power }{
        .{ compute.Client.beginDeallocateVirtualMachine, .deallocated },
        .{ compute.Client.beginStartVirtualMachine, .running },
        .{ compute.Client.beginRestartVirtualMachine, .running },
    };
    for (steps) |s| {
        var op = try s[0](&r.client, sub, "rg", "w1");
        defer op.deinit();
        try testing.expectEqual(.running, op.value.state);
        try r.client.waitOperation(&op, 120_000);
        try testing.expectEqual(.succeeded, op.value.state);
        var vm = try r.client.getVirtualMachine(sub, "rg", "w1");
        defer vm.deinit();
        try testing.expectEqual(s[1], vm.value.state.power.?);
    }
    try r.fake.addVm(.{ .subscription = sub, .group = "rg", .name = "e1" });
    try testing.expectError(error.Conflict, r.client.beginDeallocateVirtualMachine(sub, "rg", "e1"));
    try testing.expectEqualStrings("OperationNotAllowed", r.diag.code());
}

test "a delete of a VM not there has nothing to do" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    var op = try r.client.beginDeleteVirtualMachine(sub, "rg", "absent", .{});
    defer op.deinit();
    try testing.expectEqual(.succeeded, op.value.state);
    try testing.expectEqual(1, r.fake.calls.items.len);
}

test "a raw create: the caller's body, sent as given, claimed by its attempt tag" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    try r.fake.addMeasuredSizes();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const body = (try r.client.preview(arena.allocator(), sub, "rg", "w1", .{ .create = worker("a1") })).body;
    var op = try r.client.beginCreateVirtualMachineRaw(sub, "rg", "w1", body, .{ .name = "pb-attempt", .value = "a1" });
    defer op.deinit();
    try testing.expectEqualStrings(body, r.fake.calls.items[0].body);
    var again = try r.client.beginCreateVirtualMachineRaw(sub, "rg", "w1", body, .{ .name = "pb-attempt", .value = "a1" });
    defer again.deinit();
    try testing.expectEqual(.provisioning_state, again.value.follow);
}

test "the refusal classes, from status, code and message" {
    const of = compute.RefusalClass.of;
    try testing.expectEqual(.throttled, of(429, "OperationNotAllowed", "The server rejected the request because too many requests have been received for this subscription."));
    try testing.expectEqual(.quota, of(409, "OperationNotAllowed", "Operation could not be completed as it results in exceeding approved LowPriorityCores quota."));
    try testing.expectEqual(.other, of(409, "OperationNotAllowed", "Operation 'deallocate' is not supported for VMs with an ephemeral OS disk."));
    for ([_][]const u8{ "SkuNotAvailable", "allocationfailed", "ZonalAllocationFailed", "OverconstrainedAllocationRequest", "OverconstrainedZonalAllocationRequest" }) |code| {
        try testing.expectEqual(.capacity, of(0, code, ""));
    }
    try testing.expectEqual(.policy, of(403, "RequestDisallowedByPolicy", "Resource 'w1' was disallowed by policy."));
    try testing.expectEqual(.invalid, of(400, "InvalidParameter", "The value of parameter maxPrice is invalid."));
    try testing.expectEqual(.invalid, of(409, "SpotPriceGreaterThanProvidedMaxPrice", ""));
    try testing.expectEqual(.other, of(404, "ResourceNotFound", ""));
}
