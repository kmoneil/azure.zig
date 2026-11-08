//! The compute module's reads against Azure itself: the sizes a region
//! offers the test subscription, its locations' zones, its quotas, and its
//! VMs. Reads only: nothing is made, and it costs nothing.
//!
//!     AZURE_TEST_SUBSCRIPTION=<guid> AZURE_TEST_TOKEN=$(tools/azure-token.sh) \
//!         zig build test-integration-azure -Dtest-filter=compute
//!
//! Without both variables it skips. `AZURE_TEST_LOCATION` names the region
//! (eastus2 when unset). Each `fact:` line is what the subscription has,
//! which may change as Azure changes what it offers.

const std = @import("std");
const compute = @import("compute");
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
        fact("spot with an ephemeral OS disk, 2 vCPUs or fewer: {s}, {d} zone(s) usable", .{ s.name, s.zones.len });
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
