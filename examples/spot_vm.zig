const std = @import("std");
const auth = @import("auth");
const compute = @import("compute");

pub fn main(init: std.process.Init) !void {
    const env = init.environ_map;
    // After az login: a subscription, a resource group of yours, a subnet's
    // ARM id (the network_workers example makes one), and an SSH public key.
    const sub = env.get("AZURE_SUBSCRIPTION");
    const group = env.get("AZURE_GROUP");
    const subnet = env.get("AZURE_SUBNET");
    const key = env.get("AZURE_SSH_PUBLIC_KEY");
    if (sub == null or group == null or subnet == null or key == null) {
        std.debug.print("set AZURE_SUBSCRIPTION, AZURE_GROUP, AZURE_SUBNET and AZURE_SSH_PUBLIC_KEY, after az login\n", .{});
        return;
    }
    const location = env.get("AZURE_LOCATION") orelse "eastus2";
    var diag: compute.Diagnostics = .{};
    var cli: auth.AzureCli = try .init(init.gpa, .{ .diagnostics = &diag });
    defer cli.deinit();
    var client: compute.Client = try .init(init.gpa, init.io, .{ .token_provider = cli.provider(), .diagnostics = &diag });
    defer client.deinit();

    // The first 2-vCPU size that runs as spot with an ephemeral OS disk
    // and Trusted Launch, and its first zone.
    var sizes = client.listSizes(sub.?, location) catch |err| {
        std.debug.print("{t}: {f}\n", .{ err, diag });
        return err;
    };
    defer sizes.deinit();
    const fit = try init.arena.allocator().alloc(compute.Size, sizes.value.len);
    const shape: compute.Shape = .{ .spot = true, .ephemeral_os_disk = true, .trusted_launch = true, .min_vcpus = 2, .max_vcpus = 2 };
    const sizes_fit = compute.sizesThatFit(fit, sizes.value, shape);
    if (sizes_fit.len == 0) return error.NoSizeFits;
    const size = sizes_fit[0];

    const spec: compute.VmSpec = .{
        .location = location,
        .size = size.name,
        .zone = if (size.zones.len > 0) size.zones[0] else null,
        .os_disk = .{ .ephemeral = size.ephemeralPlacement().? },
        .disk_controller = size.diskController(),
        .admin_username = "worker",
        .ssh_public_keys = &.{std.mem.trim(u8, key.?, &std.ascii.whitespace)},
        .nic = .{ .subnet = subnet.? },
        .tags = &.{.{ .name = "example", .value = "spot_vm" }},
        .attempt_tag = .{ .name = "attempt", .value = "1" },
    };
    const preview = try client.preview(init.arena.allocator(), sub.?, group.?, "spot-1", .{ .create = spec });
    std.debug.print("{t} {s}\n", .{ preview.method, preview.url });

    var op = client.beginCreateVirtualMachine(sub.?, group.?, "spot-1", spec) catch |err| {
        // Capacity and quota refusals are answers a scheduler acts on.
        std.debug.print("{t} ({t}): {f}\n", .{ err, compute.RefusalClass.ofDiagnostics(&diag), diag });
        return err;
    };
    defer op.deinit();
    try client.waitOperation(&op, 10 * 60 * 1000);
    if (op.value.state != .succeeded) {
        std.debug.print("create {t}: {s} ({t})\n", .{ op.value.state, op.value.failure_code, compute.RefusalClass.ofOperation(&op.value) });
    }
    var vm = try client.getVirtualMachine(sub.?, group.?, "spot-1");
    defer vm.deinit();
    std.debug.print("{s}: {s} in zone {s}, {t}, running {}\n", .{ vm.value.name, vm.value.size, vm.value.zone orelse "none", vm.value.state.provisioning, vm.value.state.isRunning() });

    // A VM that is made, or failed, is deleted: a failed one costs its
    // disks until it is.
    var gone = try client.beginDeleteVirtualMachine(sub.?, group.?, "spot-1", .{ .force = true });
    defer gone.deinit();
    try client.waitOperation(&gone, 10 * 60 * 1000);
    std.debug.print("deleted: {t}\n", .{gone.value.state});
}
