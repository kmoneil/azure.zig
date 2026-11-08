const std = @import("std");
const auth = @import("auth");
const compute = @import("compute");

pub fn main(init: std.process.Init) !void {
    const env = init.environ_map;
    const sub = env.get("AZURE_SUBSCRIPTION") orelse {
        std.debug.print("set AZURE_SUBSCRIPTION (and AZURE_LOCATION, eastus2 when unset), after az login\n", .{});
        return;
    };
    const location = env.get("AZURE_LOCATION") orelse "eastus2";
    var diag: compute.Diagnostics = .{};
    var cli: auth.AzureCli = try .init(init.gpa, .{ .diagnostics = &diag });
    defer cli.deinit();
    var client: compute.Client = try .init(init.gpa, init.io, .{ .token_provider = cli.provider(), .diagnostics = &diag });
    defer client.deinit();

    // The sizes this subscription may make here, as spot VMs with an
    // ephemeral OS disk, and the zones each may go in.
    var sizes = client.listSizes(sub, location) catch |err| {
        std.debug.print("{t}: {f}\n", .{ err, diag });
        return err;
    };
    defer sizes.deinit();
    const fit = try init.arena.allocator().alloc(compute.Size, sizes.value.len);
    for (compute.sizesThatFit(fit, sizes.value, .{ .spot = true, .ephemeral_os_disk = true, .max_vcpus = 4 })) |s| {
        std.debug.print("{s}  {d} vCPUs  {d} GB  zones:", .{ s.name, s.vcpus, s.memory_gb });
        for (s.zones) |z| std.debug.print(" {s}", .{z});
        std.debug.print("{s}\n", .{if (s.zones.len == 0) " none (no zone only)" else ""});
    }

    // Every spot VM's vCPUs count against one quota.
    var usages = try client.listUsages(sub, location);
    defer usages.deinit();
    if (compute.findUsage(usages.value, compute.spot_cores)) |u| std.debug.print("spot vCPUs: {d} of {d} in use\n", .{ u.current, u.limit });
}
