[Docs](../README.md) › Compute

# compute: virtual machines

Microsoft.Compute at api-version 2026-04-01, as puffball's spot workers
need it. This first milestone reads: a VM and its state, VMs listed by
group, subscription or region, the sizes a region offers this
subscription, its zones, and its quotas. Making, deleting and evicting
VMs comes next.

Measured on 2026-11-07 with a spot VM on the test subscription (t19's
m0). The live suite (`tests/compute_azure_integration.zig`) reads it all
again, and prints what the subscription has as `fact:` lines.

## A first program

It prints the sizes a region offers this subscription as spot VMs with
an ephemeral OS disk, the zones each may go in, and the spot quota, with
the Azure CLI's login (`az login`) and `AZURE_SUBSCRIPTION` set.

<!-- snippet: examples/compute_sizes.zig -->
```zig
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
```

## The calls

| Call | Does |
| --- | --- |
| `getVirtualMachine(sub, group, name)` | One VM with its instance view, its state typed; `NotFound` when there is none |
| `listVirtualMachines(sub, scope, options)` | The VMs of a group, the subscription or a region, every page read; `options.tag` keeps those with a tag and value |
| `listSizes(sub, location)` | The VM sizes the region offers this subscription, with the zones each may go in |
| `listLocations(sub)` | The regions, each with its zones as this subscription numbers them, and the physical zone each is |
| `listUsages(sub, location)` | The region's quotas: `cores`, each family's, and `lowPriorityCores` |

Every result is an `Owned(T)`: one `deinit` frees it.

## A VM's state

`state` comes from the instance view: `provisioning` (creating,
succeeded, failed...), `power` (starting, running, deallocated...), and
`failure`, the code after `ProvisioningState/failed/`, such as
`AllocationFailed`. A spot VM measured on 2026-11-07 read creating, then
starting at 6 s, running at 17 s and succeeded at 32 s. A list carries no
instance view, so a listed VM's `power` is null: get one for it.

<!-- snippet: tests/docs_examples.zig#vm-state -->
```zig
var vm = try client.getVirtualMachine(sub, "rg", "worker-1");
defer vm.deinit();
if (vm.value.state.isFailed()) {
    // The allocation failed (vm.value.state.failure names why): the VM
    // is there, stuck, until it is deleted.
}
```

A failed allocation leaves the VM there in `Failed`, costing its disks:
`isFailed` says so, and the caller deletes it. Compute has no filter on
tags, so `options.tag` reads every page and keeps the matches.

## Sizes, zones and quotas

`listSizes` reads Resource SKUs for the region and keeps the sizes this
subscription may make there: a size with a `Location` restriction
(`NotAvailableForSubscription`) is left out, and each size's zones are
the region's less those restricted. Either kind of refused size is 409
`SkuNotAvailable` on create. `sizesThatFit` picks those that meet a
`Shape`: vCPUs, memory, spot, an ephemeral OS disk, a zone.

<!-- snippet: tests/docs_examples.zig#sizes-that-fit -->
```zig
var sizes = try client.listSizes(sub, "eastus2");
defer sizes.deinit();
var buf: [16]compute.Size = undefined;
const fit = compute.sizesThatFit(&buf, sizes.value, .{ .spot = true, .ephemeral_os_disk = true, .max_vcpus = 2 });
// fit: Standard_D2ds_v5 alone, its one zone "4"
```

A zone is a subscription's own number for a physical zone, so zone 1
here may be zone 2 in another subscription: `listLocations` gives each
logical zone's physical one. eastus2 has four.

Every spot VM's vCPUs count against `lowPriorityCores` alone
(`compute.spot_cores`); a family's own quota does not stop one. Over it,
a create is 409 `OperationNotAllowed`, its message naming the quota.

## Errors

`Error` is closed: core's ARM refusals by status (`NotFound`,
`Conflict`, `PermissionDenied`, `Throttled` and the rest), the
transport's and the token provider's failures, `InvalidArgument` for a
name or id refused before sending, and `InvalidResponse` for an answer
that is not ARM's JSON. After a failure, `Diagnostics` has the status,
the code and message, and ARM's request ids.

## Testing code that uses this module

`testing.FakeCompute` is Compute's reads in memory, behind
`Options.transport`. It holds eastus2 and westus2 with their zone
mappings and quotas as measured; `addMeasuredSizes` adds eastus2's sizes
as the test subscription was offered them, `addSize` any other, and
`addVm` a VM in whatever state a test needs. Lists come `page_size` to a
page.

<!-- snippet: tests/docs_examples.zig#fake-compute -->
```zig
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
```

Making VMs, spot included, deleting them, evicting one on purpose, and
waiting on the operations come next (m2).
