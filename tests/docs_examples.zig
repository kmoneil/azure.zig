//! Code the documentation shows, compiled and run with the unit tests so
//! that it cannot drift from the library. tools/check_docs.py holds each
//! block marked `<!-- snippet: tests/docs_examples.zig#name -->` to the
//! lines between `// snippet: name` and `// end snippet` here. (gcp.zig's
//! pattern, at eae944c.)

const std = @import("std");
const resources = @import("resources");
const network = @import("network");
const prices = @import("prices");
const storage = @import("storage");
const auth = @import("auth");
const compute = @import("compute");

test "docs/resources: a client over FakeResources, and a list by tag" {
    const gpa = std.testing.allocator;
    // snippet: fake-resources
    var fake: resources.testing.FakeResources = .init(gpa);
    defer fake.deinit();
    try fake.addSubscription("0f9e8d7c-6b5a-4c3d-8e2f-1a0b9c8d7e6f", "test");
    var clock: resources.testing.FakeClock = .{};
    var token: resources.StaticToken = .{ .token = "t" };
    var client: resources.Client = try .init(gpa, clock.io(), .{
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    // end snippet

    const sub = "0f9e8d7c-6b5a-4c3d-8e2f-1a0b9c8d7e6f";
    const run = "1a2b3c4d";
    var made = try client.createResourceGroup(sub, "azzig-docs-1a2b3c4d", .{ .location = "eastus2", .tags = &.{.{ .name = "azzig-run", .value = run }} });
    made.deinit();
    // snippet: list-by-tag
    var mine = try client.listResourceGroups(sub, .{ .name = "azzig-run", .value = run });
    defer mine.deinit();
    // end snippet
    try std.testing.expectEqual(1, mine.value.len);
}

test "docs/network: a client over FakeNetwork, and a subnet behind a security group" {
    const gpa = std.testing.allocator;
    // snippet: fake-network
    var fake: network.testing.FakeNetwork = .init(gpa);
    defer fake.deinit();
    try fake.addGroup("0f9e8d7c-6b5a-4c3d-8e2f-1a0b9c8d7e6f", "rg");
    var clock: network.testing.FakeClock = .{};
    var token: network.StaticToken = .{ .token = "t" };
    var client: network.Client = try .init(gpa, clock.io(), .{
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    // end snippet

    const sub = "0f9e8d7c-6b5a-4c3d-8e2f-1a0b9c8d7e6f";
    // snippet: security-group
    var nsg_op = try client.beginCreateSecurityGroup(sub, "rg", "pb-nsg", .{
        .location = "eastus2",
        .rules = &.{.{
            .name = "AllowSsh",
            .priority = 100,
            .direction = .inbound,
            .access = .allow,
            .protocol = .tcp,
            .source_address_prefixes = &.{"203.0.113.0/24"},
            .destination_port_ranges = &.{"22"},
        }},
    });
    defer nsg_op.deinit();
    try client.waitOperation(&nsg_op, 60_000);

    const nsg_id = try network.ids.securityGroup(gpa, sub, "rg", "pb-nsg");
    defer gpa.free(nsg_id);
    var vnet_op = try client.beginCreateVirtualNetwork(sub, "rg", "pb-vnet", .{
        .location = "eastus2",
        .address_prefixes = &.{"10.20.0.0/16"},
        .subnets = &.{.{ .name = "workers", .spec = .{
            .address_prefix = "10.20.1.0/24",
            .service_endpoints = &.{"Microsoft.Storage"},
            .security_group = nsg_id,
        } }},
    });
    defer vnet_op.deinit();
    try client.waitOperation(&vnet_op, 60_000);
    // end snippet
    try std.testing.expectEqual(.succeeded, vnet_op.value.state);
    var subnet = try client.getSubnet(sub, "rg", "pb-vnet", "workers");
    defer subnet.deinit();
    try std.testing.expectEqualStrings(nsg_id, subnet.value.security_group.?);
}

test "docs/prices: a client over FakePrices" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // snippet: fake-prices
    var fake: prices.testing.FakePrices = .init(gpa);
    defer fake.deinit();
    try fake.addSize("eastus2", "Standard_D2as_v5", "Dasv5", "0.015919", "0.086");
    var client: prices.Client = try .init(gpa, io, .{ .transport = fake.transport() });
    defer client.deinit();
    // end snippet

    var spot = try client.list(.{ .sku = "Standard_D2as_v5" });
    defer spot.deinit();
    try std.testing.expectEqual(1, spot.value.prices.len);
}

test "docs/storage: a client over FakeBlob, a compare and swap, a listing after a name" {
    const gpa = std.testing.allocator;
    // snippet: fake-blob
    var fake: storage.testing.FakeBlob = .init(gpa);
    defer fake.deinit();
    try fake.addContainer("bucket");
    var clock: storage.testing.FakeClock = .{};
    var client: storage.Client = try .init(gpa, clock.io(), .{
        .endpoint = .{ .custom = .{ .url = storage.testing.FakeBlob.default_url, .account = "azzigfake" } },
        .credential = .{ .shared_key = storage.azurite_key },
        .transport = fake.transport(),
    });
    defer client.deinit();
    // end snippet

    // snippet: compare-and-swap
    // Create only: PreconditionFailed when the blob is there already.
    const first = try client.putBlob("bucket", "jobs/latest", "1", .{ .conditions = .if_absent });
    // Replace only the version read: compare and swap.
    var read = try client.getBlob("bucket", "jobs/latest", .{});
    defer read.deinit();
    _ = try client.putBlob("bucket", "jobs/latest", "2", .{ .conditions = .ifMatch(read.value.properties.etag) });
    // That version is gone now, so a swap from it is refused.
    const stale = client.putBlob("bucket", "jobs/latest", "3", .{ .conditions = .ifMatch(first.etag) });
    // end snippet
    try std.testing.expectError(error.PreconditionFailed, stale);

    // snippet: list-after
    for ([_][]const u8{ "events/000001", "events/000002", "events/000003" }) |name| {
        _ = try client.putBlob("bucket", name, "e", .{});
    }
    // The names under events/ that sort after the last one read.
    var newer = try client.listBlobs("bucket", .{ .prefix = "events/", .after = "events/000001" });
    defer newer.deinit();
    // newer.value.blobs: events/000002 and events/000003, each with its
    // name, ETag, size and content type.
    // end snippet
    try std.testing.expectEqual(2, newer.value.blobs.len);
    try std.testing.expectEqualStrings("events/000002", newer.value.blobs[0].name);
}

test "docs/auth: a ClientSecret over FakeEntra, one credential for two scopes" {
    const gpa = std.testing.allocator;
    var clock: auth.testing.FakeClock = .{};
    const io = clock.io();
    // snippet: fake-entra
    var fake: auth.testing.FakeEntra = .init(gpa);
    defer fake.deinit();
    try fake.addApp("00000000-0000-4000-8000-00000000aaaa", "00000000-0000-4000-8000-00000000a99a", "the-secret");
    var cred: auth.ClientSecret = try .init(gpa, io, .{
        .tenant_id = "00000000-0000-4000-8000-00000000aaaa",
        .client_id = "00000000-0000-4000-8000-00000000a99a",
        .secret = "the-secret",
        .transport = fake.transport(),
    });
    defer cred.deinit();
    // end snippet

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    // snippet: two-scopes
    // One credential, a token per scope, each cached until five minutes
    // before it expires.
    const p = cred.provider();
    const for_arm = try p.getToken(io, arena.allocator(), &.{"https://management.core.windows.net//.default"});
    const for_blobs = try p.getToken(io, arena.allocator(), &.{"https://storage.azure.com/.default"});
    // end snippet
    try std.testing.expect(!std.mem.eql(u8, for_arm, for_blobs));
    try std.testing.expectEqual(2, fake.requests);
}

test "docs/compute: a VM's state and the sizes that fit, over FakeCompute" {
    const gpa = std.testing.allocator;
    const sub = "0f9e8d7c-6b5a-4c3d-8e2f-1a0b9c8d7e6f";
    // snippet: fake-compute
    var fake: compute.testing.FakeCompute = try .init(gpa);
    defer fake.deinit();
    try fake.addMeasuredSizes();
    try fake.addVm(.{ .subscription = sub, .group = "rg", .name = "worker-1", .provisioning = "Failed", .failure = "AllocationFailed", .power = null });
    var clock: compute.testing.FakeClock = .{};
    var token: compute.StaticToken = .{ .token = "t" };
    var client: compute.Client = try .init(gpa, clock.io(), .{
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    // end snippet

    // snippet: vm-state
    var vm = try client.getVirtualMachine(sub, "rg", "worker-1");
    defer vm.deinit();
    if (vm.value.state.isFailed()) {
        // The allocation failed (vm.value.state.failure names why): the VM
        // is there, stuck, until it is deleted.
    }
    // end snippet
    try std.testing.expect(vm.value.state.isFailed());

    // snippet: sizes-that-fit
    var sizes = try client.listSizes(sub, "eastus2");
    defer sizes.deinit();
    var buf: [16]compute.Size = undefined;
    const fit = compute.sizesThatFit(&buf, sizes.value, .{ .spot = true, .ephemeral_os_disk = true, .max_vcpus = 2 });
    // fit: Standard_D2ds_v5 in zone 4 alone, and Standard_D2ds_v7 in all four
    // end snippet
    try std.testing.expectEqual(2, fit.len);
}

test "docs/compute: a spot VM made once, waited on, and its refusals by kind, over FakeCompute" {
    const gpa = std.testing.allocator;
    const sub = "0f9e8d7c-6b5a-4c3d-8e2f-1a0b9c8d7e6f";
    const subnet = "/subscriptions/" ++ sub ++ "/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/pb-vnet/subnets/workers";
    const public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGV4YW1wbGUga2V5LCBub3QgYSByZWFsIG9uZSwgYXp6aWc worker@example";
    var fake: compute.testing.FakeCompute = try .init(gpa);
    defer fake.deinit();
    try fake.addMeasuredSizes();
    var clock: compute.testing.FakeClock = .{};
    var token: compute.StaticToken = .{ .token = "t" };
    var diag: compute.Diagnostics = .{};
    var client: compute.Client = try .init(gpa, clock.io(), .{ .token_provider = token.provider(), .transport = fake.transport(), .diagnostics = &diag });
    defer client.deinit();

    // snippet: spot-create
    const spec: compute.VmSpec = .{
        .location = "eastus2",
        .size = "Standard_D2ds_v7",
        .zone = "2",
        // Where Size.ephemeralPlacement and Size.diskController say.
        .os_disk = .{ .ephemeral = .nvme_disk },
        .disk_controller = .nvme,
        .admin_username = "worker",
        .ssh_public_keys = &.{public_key},
        .nic = .{ .subnet = subnet },
        .tags = &.{.{ .name = "job", .value = "j1" }},
        // Only this attempt at the VM carries it.
        .attempt_tag = .{ .name = "attempt", .value = "j1-s0-a1" },
    };
    var op = client.beginCreateVirtualMachine(sub, "rg", "worker-1", spec) catch |err| {
        // .capacity: another zone, size or region, or later. .quota: not
        // until a VM ends.
        std.log.err("{t}, {t}: {f}", .{ err, compute.RefusalClass.ofDiagnostics(&diag), diag });
        return err;
    };
    defer op.deinit();
    try client.waitOperation(&op, 10 * 60 * 1000);
    // op.value.state is .succeeded, or .failed with op.value.failure_code
    // end snippet
    try std.testing.expectEqual(.succeeded, op.value.state);

    // snippet: create-again
    // The same attempt again, as after a timeout: the VM is this one's.
    var again = try client.beginCreateVirtualMachine(sub, "rg", "worker-1", spec);
    defer again.deinit();
    // again.value.state == .succeeded, and no second VM
    // end snippet
    try std.testing.expectEqual(.succeeded, again.value.state);
    try std.testing.expectEqual(1, fake.vms.items.len);

    // snippet: refusal-class
    // A second spot VM, past the test subscription's 3 spot vCPUs.
    try std.testing.expectError(error.Conflict, client.beginCreateVirtualMachine(sub, "rg", "worker-2", spec));
    try std.testing.expectEqual(.quota, compute.RefusalClass.ofDiagnostics(&diag));
    // end snippet

    // snippet: fake-compute-writes
    try fake.failNextCreate("AllocationFailed", "Allocation failed.");
    fake.lose_next_create = true; // made, then answered 504
    fake.eviction_reads = 3; // an evicted VM's reads before it is gone
    fake.operation_polls = 2; // an operation's reads before it ends
    // end snippet
    var evict = try client.beginDeleteVirtualMachine(sub, "rg", "worker-1", .{ .force = true });
    defer evict.deinit();
}
