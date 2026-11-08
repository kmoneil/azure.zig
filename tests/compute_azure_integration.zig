//! The compute module against Azure itself.
//!
//!     AZURE_TEST_SUBSCRIPTION=<guid> AZURE_TEST_TOKEN=$(tools/azure-token.sh) \
//!         zig build test-integration-azure -Dtest-filter=compute
//!
//! Without both variables every test skips. `AZURE_TEST_LOCATION` names
//! the region (eastus2 when unset). Each `fact:` line is what Azure
//! answered, which FakeCompute assumes: a run that prints another answer is
//! the fake to change.
//!
//! The first test reads: the sizes a region offers the subscription, its
//! zones, its quotas and its VMs, at no cost. The second, which also needs
//! `AZURE_TEST_COMPUTE_VMS=1`, makes spot VMs, for a few cents. It sweeps
//! the `azzig-` groups crashed runs left, then makes one of its own,
//! `azzig-compute-<run>`, with a private subnet made by the network
//! module, and in it:
//!
//! - a spot VM of `AZURE_TEST_COMPUTE_SIZE` (Standard_D2ds_v7 when unset)
//!   in the first zone the subscription may use, its OS disk ephemeral
//!   where the size puts one; created again by its own attempt and by
//!   another's; a second VM refused for the spot quota (3 vCPUs on the
//!   test subscription); a restart; and an eviction, waited to the VM's
//!   end;
//! - then a spot VM of `AZURE_TEST_COMPUTE_MANAGED_SIZE`
//!   (Standard_D2s_v7 when unset) on a managed Standard_LRS disk of 30 GB,
//!   deallocated, started and deleted.
//!
//! The group is deleted however the test ends, its VMs with it. A run
//! takes about ten minutes. The subscription's policy (kb/azure-resources)
//! holds every VM to spot, deleted on eviction, a Standard OS disk of 64 GB
//! at most, and no public IP: the specs here keep to it.

const std = @import("std");
const core = @import("core");
const compute = @import("compute");
const network = @import("network");
const resources = @import("resources");
const sweep = @import("sweep.zig");
const testing = std.testing;

fn fact(comptime format: []const u8, args: anytype) void {
    std.debug.print("  fact: " ++ format ++ "\n", args);
}

test "compute: sizes, zones, quotas and VMs as the test subscription has them" {
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    const sub = env.get("AZURE_TEST_SUBSCRIPTION") orelse return error.SkipZigTest;
    const text = env.get("AZURE_TEST_TOKEN") orelse return error.SkipZigTest;
    const location = env.get("AZURE_TEST_LOCATION") orelse "eastus2";
    var token: compute.StaticToken = .{ .token = std.mem.trim(u8, text, &std.ascii.whitespace) };
    var diag: compute.Diagnostics = .{};
    var client: compute.Client = try .init(testing.allocator, testing.io, .{ .token_provider = token.provider(), .diagnostics = &diag, .user_agent = "azure-zig-compute-integration/0.1" });
    defer client.deinit();
    errdefer std.debug.print("  failed: {f}\n", .{diag});

    var sizes = try client.listSizes(sub, location);
    defer sizes.deinit();
    try testing.expect(sizes.value.len > 0);
    var spot: usize = 0;
    for (sizes.value) |s| {
        try testing.expect(s.vcpus > 0 and s.memory_gb > 0);
        if (s.spot) spot += 1;
    }
    fact("{s} offers {d} VM size(s) to this subscription, {d} of them spot", .{ location, sizes.value.len, spot });
    const fit = try testing.allocator.alloc(compute.Size, sizes.value.len);
    defer testing.allocator.free(fit);
    for (compute.sizesThatFit(fit, sizes.value, .{ .spot = true, .ephemeral_os_disk = true, .max_vcpus = 2 })) |s| {
        fact("spot with an ephemeral OS disk, 2 vCPUs or fewer: {s}, {d} zone(s) usable, at {t}{s}", .{ s.name, s.zones.len, s.ephemeralPlacement().?, if (s.diskController() == .nvme) ", NVMe alone" else "" });
    }

    var locations = try client.listLocations(sub);
    defer locations.deinit();
    var found = false;
    for (locations.value) |l| if (std.mem.eql(u8, l.name, location)) {
        found = true;
        for (l.zones) |z| fact("{s} zone {s} is {s}", .{ location, z.logical, z.physical });
    };
    try testing.expect(found);

    var usages = try client.listUsages(sub, location);
    defer usages.deinit();
    const spot_cores = compute.findUsage(usages.value, compute.spot_cores) orelse return error.NoSpotQuota;
    fact("spot vCPUs: {d} of {d}", .{ spot_cores.current, spot_cores.limit });

    var vms = try client.listVirtualMachines(sub, .subscription, .{});
    defer vms.deinit();
    fact("{d} VM(s) in the subscription", .{vms.value.len});
}

const Fixture = struct {
    env: std.process.Environ.Map,
    token: core.StaticToken,
    diag: core.Diagnostics,
    groups: resources.Client,
    networks: network.Client,
    client: compute.Client,
    subscription: []const u8,
    location: []const u8,
    group: []const u8 = "",

    fn init(f: *Fixture) !bool {
        const gpa = testing.allocator;
        f.env = try testing.environ.createMap(gpa);
        errdefer f.env.deinit();
        f.subscription = f.env.get("AZURE_TEST_SUBSCRIPTION") orelse return f.skip();
        const token = f.env.get("AZURE_TEST_TOKEN") orelse return f.skip();
        if (!std.mem.eql(u8, f.env.get("AZURE_TEST_COMPUTE_VMS") orelse "", "1")) return f.skip();
        f.location = f.env.get("AZURE_TEST_LOCATION") orelse "eastus2";
        f.token = .{ .token = std.mem.trim(u8, token, &std.ascii.whitespace) };
        f.diag = .{};
        const ua = "azure-zig-compute-integration/0.1";
        f.groups = try .init(gpa, testing.io, .{ .token_provider = f.token.provider(), .diagnostics = &f.diag, .user_agent = ua });
        errdefer f.groups.deinit();
        f.networks = try .init(gpa, testing.io, .{ .token_provider = f.token.provider(), .diagnostics = &f.diag, .user_agent = ua });
        errdefer f.networks.deinit();
        f.client = try .init(gpa, testing.io, .{ .token_provider = f.token.provider(), .diagnostics = &f.diag, .user_agent = ua });
        return true;
    }

    fn skip(f: *Fixture) bool {
        f.env.deinit();
        return false;
    }

    fn deinit(f: *Fixture) void {
        f.client.deinit();
        f.networks.deinit();
        f.groups.deinit();
        f.env.deinit();
    }

    /// Says what failed, as Diagnostics has it, then passes the error on.
    fn explain(f: *Fixture, err: anyerror) anyerror {
        std.debug.print("  failed: {t}: {f}\n", .{ err, f.diag });
        return err;
    }

    /// Waits on a compute write to its end, which must be success, and
    /// says how long it took.
    fn settle(f: *Fixture, comptime what: []const u8, begun: anyerror!compute.Owned(compute.Operation)) !void {
        const started = nowSeconds();
        var op = begun catch |err| return f.explain(err);
        defer op.deinit();
        fact(what ++ ": followed by {t}, first wait {d} ms", .{ op.value.follow, op.value.delay_ms });
        f.client.waitOperation(&op, 15 * 60 * 1000) catch |err| return f.explain(err);
        if (op.value.state != .succeeded) {
            std.debug.print("  " ++ what ++ " ended {t}: {s}: {s} ({t})\n", .{ op.value.state, op.value.failure_code, op.value.failure_message, compute.RefusalClass.ofOperation(&op.value) });
            return error.OperationNotSucceeded;
        }
        fact(what ++ ": done in {d} s", .{nowSeconds() - started});
    }

    /// A refusal expected, as `expected`: its error, status, code and
    /// class printed as found.
    fn refused(f: *Fixture, comptime what: []const u8, expected: anyerror, begun: anyerror!compute.Owned(compute.Operation)) !void {
        if (begun) |op| {
            var o = op;
            o.deinit();
            std.debug.print("  " ++ what ++ ": not refused\n", .{});
            return error.NotRefused;
        } else |err| {
            fact(what ++ ": {t}, {d} {s}, {t}", .{ err, f.diag.http_status, f.diag.code(), compute.RefusalClass.ofDiagnostics(&f.diag) });
            if (err != expected) return error.WrongRefusal;
        }
    }

    fn vm(f: *Fixture, name: []const u8) !compute.Owned(compute.VirtualMachine) {
        return f.client.getVirtualMachine(f.subscription, f.group, name) catch |err| return f.explain(err);
    }

    /// Reads the VM every ten seconds until it is gone, and says when.
    fn awaitGone(f: *Fixture, comptime what: []const u8, name: []const u8, timeout_s: i64) !void {
        const started = nowSeconds();
        var last: ?compute.State = null;
        while (nowSeconds() - started < timeout_s) {
            var v = f.client.getVirtualMachine(f.subscription, f.group, name) catch |err| switch (err) {
                error.NotFound => {
                    fact(what ++ ": the VM gone after {d} s", .{nowSeconds() - started});
                    return;
                },
                else => return f.explain(err),
            };
            defer v.deinit();
            const s = v.value.state;
            if (last == null or last.?.provisioning != s.provisioning or last.?.power != s.power) {
                fact(what ++ ": +{d} s {t} {s}", .{ nowSeconds() - started, s.provisioning, if (s.power) |p| @tagName(p) else "-" });
            }
            last = s;
            try testing.io.sleep(.fromSeconds(10), .awake);
        }
        return error.VmNotGone;
    }
};

fn nowSeconds() i64 {
    return std.Io.Clock.real.now(testing.io).toSeconds();
}

/// A public key no one holds the private half of: 32 random bytes in
/// OpenSSH's ed25519 form. Nobody can sign in, and nothing needs to.
fn throwawayKey(buf: []u8, comment: []const u8) ![]const u8 {
    var blob: [51]u8 = undefined;
    @memcpy(blob[0..19], "\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20");
    testing.io.random(blob[19..]);
    var b64: [68]u8 = undefined;
    return std.fmt.bufPrint(buf, "ssh-ed25519 {s} {s}", .{ std.base64.standard.Encoder.encode(&b64, &blob), comment });
}

test "compute: spot VMs made once, refused for quota, restarted, evicted, deallocated, started and deleted" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const gpa = testing.allocator;
    const sub = f.subscription;
    _ = sweep.sweep(&f.groups, sub, nowSeconds()) catch |err| return f.explain(err);

    const run = sweep.runId(testing.io);
    var name_buf: [64]u8 = undefined;
    f.group = try std.fmt.bufPrint(&name_buf, "azzig-compute-{s}", .{&run});
    const rg = f.group;
    var created_buf: [20]u8 = undefined;
    const tags = [_]compute.Tag{
        .{ .name = sweep.run_tag, .value = &run },
        .{ .name = sweep.created_tag, .value = try std.fmt.bufPrint(&created_buf, "{d}", .{nowSeconds()}) },
    };
    var made = f.groups.createResourceGroup(sub, rg, .{ .location = f.location, .tags = &tags }) catch |err| return f.explain(err);
    made.deinit();
    // From here on the group exists: delete it, VMs and all, however the
    // test ends.
    defer if (f.groups.beginDeleteResourceGroup(sub, rg, .{ .force_vms = true })) |op| {
        var o = op;
        o.deinit();
    } else |_| {};

    // A private subnet, as puffball's workers have.
    var vnet = f.networks.beginCreateVirtualNetwork(sub, rg, "pb-vnet", .{
        .location = f.location,
        .address_prefixes = &.{"10.30.0.0/16"},
        .subnets = &.{.{ .name = "workers", .spec = .{ .address_prefix = "10.30.1.0/24" } }},
        .tags = &tags,
    }) catch |err| return f.explain(err);
    defer vnet.deinit();
    f.networks.waitOperation(&vnet, 10 * 60 * 1000) catch |err| return f.explain(err);
    try testing.expectEqual(.succeeded, vnet.value.state);
    const subnet = try network.ids.subnet(gpa, sub, rg, "pb-vnet", "workers");
    defer gpa.free(subnet);

    // The size, where its OS disk goes, and its first usable zone.
    var sizes = f.client.listSizes(sub, f.location) catch |err| return f.explain(err);
    defer sizes.deinit();
    const size_name = f.env.get("AZURE_TEST_COMPUTE_SIZE") orelse "Standard_D2ds_v7";
    const size = for (sizes.value) |s| {
        if (std.ascii.eqlIgnoreCase(s.name, size_name)) break s;
    } else {
        std.debug.print("  {s} is not offered in {s}\n", .{ size_name, f.location });
        return error.SizeNotOffered;
    };
    const placement = size.ephemeralPlacement() orelse return error.SizeTakesNoEphemeralDisk;
    const zone: ?[]const u8 = if (size.zones.len > 0) size.zones[0] else null;
    fact("{s}: zone {s}, ephemeral at {t}, controller {s}", .{ size.name, zone orelse "none", placement, if (size.diskController()) |c| @tagName(c) else "Azure's default" });
    {
        var usages = f.client.listUsages(sub, f.location) catch |err| return f.explain(err);
        defer usages.deinit();
        const spot = compute.findUsage(usages.value, compute.spot_cores) orelse return error.NoSpotQuota;
        if (spot.current + size.vcpus > spot.limit) {
            std.debug.print("  spot vCPUs {d} of {d} in use already: another run's VM?\n", .{ spot.current, spot.limit });
            return error.SpotQuotaInUse;
        }
    }

    var key_buf: [160]u8 = undefined;
    const key = try throwawayKey(&key_buf, rg);
    var spec: compute.VmSpec = .{
        .location = f.location,
        .size = size.name,
        .zone = zone,
        .os_disk = .{ .ephemeral = placement },
        .disk_controller = size.diskController(),
        .admin_username = "azzig",
        .ssh_public_keys = &.{key},
        .custom_data = "#cloud-config\n",
        .user_data = "azzig compute suite",
        .nic = .{ .subnet = subnet },
        .tags = &tags,
        .attempt_tag = .{ .name = "azzig-attempt", .value = "a1" },
    };

    // Made, and made again by the same attempt: its own.
    try f.settle("spot VM create", f.client.beginCreateVirtualMachine(sub, rg, "vm1", spec));
    {
        var v = try f.vm("vm1");
        defer v.deinit();
        try testing.expect(v.value.state.isRunning());
        try testing.expectEqual(compute.Priority.spot, v.value.priority);
        try testing.expectEqual(compute.EvictionPolicy.delete, v.value.eviction_policy.?);
        try testing.expectEqualStrings("a1", v.value.tag("azzig-attempt").?);
        try testing.expectEqual(1, v.value.nics.len);
        fact("vm1's NIC: {s}", .{v.value.nics[0][std.mem.lastIndexOfScalar(u8, v.value.nics[0], '/').? + 1 ..]});
    }
    var again = f.client.beginCreateVirtualMachine(sub, rg, "vm1", spec) catch |err| return f.explain(err);
    fact("the create again, by its own attempt: {t}, followed by {t}", .{ again.value.state, again.value.follow });
    try testing.expectEqual(.succeeded, again.value.state);
    again.deinit();
    spec.attempt_tag = .{ .name = "azzig-attempt", .value = "a2" };
    try f.refused("the create again, by another attempt", error.PreconditionFailed, f.client.beginCreateVirtualMachine(sub, rg, "vm1", spec));

    // A second spot VM, past the spot quota.
    spec.attempt_tag = .{ .name = "azzig-attempt", .value = "a1" };
    try f.refused("a second spot VM", error.Conflict, f.client.beginCreateVirtualMachine(sub, rg, "vm2", spec));
    try testing.expectEqual(compute.RefusalClass.quota, compute.RefusalClass.ofDiagnostics(&f.diag));

    try f.settle("restart", f.client.beginRestartVirtualMachine(sub, rg, "vm1"));
    f.client.simulateEviction(sub, rg, "vm1") catch |err| return f.explain(err);
    try f.awaitGone("eviction", "vm1", 10 * 60);

    // A managed disk, which can be deallocated.
    var managed = spec;
    managed.size = f.env.get("AZURE_TEST_COMPUTE_MANAGED_SIZE") orelse "Standard_D2s_v7";
    const managed_size = for (sizes.value) |s| {
        if (std.ascii.eqlIgnoreCase(s.name, managed.size)) break s;
    } else return error.SizeNotOffered;
    managed.zone = if (managed_size.zones.len > 0) managed_size.zones[0] else null;
    managed.os_disk = .{ .managed = .{ .type = .standard_lrs, .size_gb = 30 } };
    managed.disk_controller = managed_size.diskController();
    try f.settle("managed-disk VM create", f.client.beginCreateVirtualMachine(sub, rg, "vm2", managed));
    try f.settle("deallocate", f.client.beginDeallocateVirtualMachine(sub, rg, "vm2"));
    {
        var v = try f.vm("vm2");
        defer v.deinit();
        try testing.expectEqual(compute.Power.deallocated, v.value.state.power.?);
    }
    try f.settle("start", f.client.beginStartVirtualMachine(sub, rg, "vm2"));
    {
        var v = try f.vm("vm2");
        defer v.deinit();
        try testing.expect(v.value.state.isRunning());
    }
    try f.settle("delete, forced", f.client.beginDeleteVirtualMachine(sub, rg, "vm2", .{ .force = true }));
    try testing.expectError(error.NotFound, f.client.getVirtualMachine(sub, rg, "vm2"));
    try f.settle("delete of a VM not there", f.client.beginDeleteVirtualMachine(sub, rg, "vm2", .{}));
}
