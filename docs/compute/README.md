[Docs](../README.md) › Compute

# compute: virtual machines

Microsoft.Compute at api-version 2026-04-01, as puffball's spot workers
need it: a VM made from a `VmSpec` once, however often the create is
tried; deleted, deallocated, started, restarted, and evicted on purpose;
every write previewed; refusals told apart by kind. And the reads: a VM
and its state, VMs listed by group, subscription or region, the sizes a
region offers this subscription, its zones, and its quotas.

Measured on 2026-11-07 with spot VMs on the test subscription (t19's
m0), and on 2026-11-08 by the live suite
(`tests/compute_azure_integration.zig`), which makes spot VMs again and
prints what Azure answered as `fact:` lines.

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
| `beginCreateVirtualMachine(sub, group, name, spec)` | Makes the VM from a `VmSpec`, once: see [Made once](#made-once) |
| `beginCreateVirtualMachineRaw(sub, group, name, body, attempt_tag)` | The same from a JSON body of the caller's own, sent as given, for what `VmSpec` has no field for |
| `beginDeleteVirtualMachine(sub, group, name, options)` | Deletes the VM, its OS disk and NIC with it; `.force = true` skips the graceful shutdown. A VM not there: done already |
| `beginDeallocateVirtualMachine`, `beginStartVirtualMachine`, `beginRestartVirtualMachine` | Stops and releases the host (no compute charge; not for an ephemeral OS disk), starts, restarts |
| `simulateEviction(sub, group, name)` | Has Azure evict the spot VM as it would for capacity |
| `waitOperation(&op, timeout_ms)` | Polls a write's operation until it ends or the time is up |
| `preview(arena, sub, group, name, write)` | The request a write sends, without sending it |

Every result is an `Owned(T)`: one `deinit` frees it. A `begin` call
returns the write's `Operation`, which `waitOperation` follows through
`Azure-AsyncOperation` (a create's first answer is 201 asking
`Retry-After: 10`); it ends `.succeeded`, or `.failed` with ARM's
`failure_code` and `failure_message`. A failed operation is an answer,
not an error.

## Making a spot VM

A `VmSpec` holds what puffball's workers need, with defaults that make a
spot VM evicted by deletion at any price up to on-demand (`maxPrice`
-1), on Ubuntu 24.04 (Gen2), its OS disk ephemeral, with Trusted Launch
named outright (secure boot and a vTPM), password sign-in off, boot
diagnostics in managed storage, and one NIC made with the VM and deleted
with it, in the subnet named. It is checked before anything is sent: a
name Compute would refuse, an ephemeral disk with eviction by
deallocation, a subnet given by name rather than ARM id, a refused admin
name, more than 50 tags, and the like are `InvalidArgument`, with why in
`Diagnostics`.

<!-- snippet: tests/docs_examples.zig#spot-create -->
```zig
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
```

Where the OS disk goes depends on the size. v5's `ds` sizes put an
ephemeral one on the resource disk and take SCSI; v6's and v7's put it
on a local NVMe disk, take NVMe alone, and take Gen2 images alone
(measured 2026-11-08). `Size.ephemeralPlacement()` and
`Size.diskController()` say what a spec names for a size. `.managed`
puts the OS disk on a managed disk instead, which can be deallocated.

`custom_data` (what cloud-init reads on first boot) and `user_data`
(what the VM reads from IMDS) are bytes, up to 65535 each, sent as
base64. Azure keeps both readable on the VM and advises against secrets
in them. Azure names the NIC after the spec's name for it (the VM's name
and `-nic` by default) with a suffix of its own, so `VirtualMachine.nics`
gives its id.

## Made once

The create's PUT carries `If-None-Match: *`, so it never updates a VM
already there: that is 412 `PreconditionFailed`, whether the VM is
running or still being made (measured). When the PUT meets a VM, or its
answer is lost (a timeout, or a 5xx after the loop's retries), the
client reads the VM: one carrying the spec's `attempt_tag` is this
create's own, made by an earlier attempt, and the operation follows its
`provisioningState`. Any other VM there is `PreconditionFailed`. So a
create tried again, by the loop's retries or by its caller, makes one VM
(the plan's decision 2).

<!-- snippet: tests/docs_examples.zig#create-again -->
```zig
// The same attempt again, as after a timeout: the VM is this one's.
var again = try client.beginCreateVirtualMachine(sub, "rg", "worker-1", spec);
defer again.deinit();
// again.value.state == .succeeded, and no second VM
```

Without an attempt tag, a VM there is always `PreconditionFailed`.

## Refusals by kind

`RefusalClass.ofDiagnostics(&diag)`, after a refused write, and
`RefusalClass.ofOperation(&op.value)`, after a failed operation, say
what a scheduler does next:

| Class | Codes | Next |
| --- | --- | --- |
| `capacity` | `SkuNotAvailable` (409, measured), `AllocationFailed`, `ZonalAllocationFailed`, the `Overconstrained` codes | Another zone, size or region, or later |
| `quota` | `OperationNotAllowed` naming a quota: "exceeding approved LowPriorityCores quota" (409, measured) | Not until usage drops or the limit rises |
| `throttled` | Any 429 | Wait as `Diagnostics.retry_after_ms` says |
| `invalid` | A 400, the spot codes among them (`SpotPriceGreaterThanProvidedMaxPrice`...) | Fix the request |
| `policy` | `RequestDisallowedByPolicy` (403) | The subscription's policy forbids it |
| `other` | The rest | |

<!-- snippet: tests/docs_examples.zig#refusal-class -->
```zig
// A second spot VM, past the test subscription's 3 spot vCPUs.
try std.testing.expectError(error.Conflict, client.beginCreateVirtualMachine(sub, "rg", "worker-2", spec));
try std.testing.expectEqual(.quota, compute.RefusalClass.ofDiagnostics(&diag));
```

`SkuNotAvailable` is also what a size or zone the subscription may never
use gets. `listSizes` leaves those out, so a size from it that meets
`SkuNotAvailable` is short of room. A failed allocation leaves the VM
there, `Failed` (`State.isFailed`), costing its disks until the caller
deletes it (decision 3).

## Previews

`preview(arena, sub, group, name, write)` builds the request a
`Write` (`.create`, `.create_raw`, `.delete`, `.deallocate`, `.start`,
`.restart`, `.simulate_eviction`) sends, without sending it: its method,
URL and body, byte for byte what the call sends, checked as the call
checks it. Headers are not part of it, so neither is a token; a create's
body carries `custom_data` and `user_data` as base64.

## Evictions and deletes

`simulateEviction` is 204 at once. Under eviction policy Delete the VM
reads as it was, then `Deleting`, then is gone with its NIC: at 21 s on
2026-11-08, at 87 s on 2026-11-07, when it read running until then. Its
vCPUs leave the spot quota with it. A delete of a VM not there has
nothing to do: its operation has succeeded already.

On 2026-11-08 the live suite's D2ds_v7, in zone 1 at NvmeDisk, was
running 46 s after its create, and restarted in 51 s; a D2s_v7 on a
managed disk was made in 45 s, deallocated in 11 s, started in 10 s and
deleted in 11 s. Every one of those writes was followed through
`Azure-AsyncOperation`, asking 10 s between polls.

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
`SkuNotAvailable` on create. Each size says which disk controllers it
takes, where an ephemeral OS disk may go on it, and whether it takes
Trusted Launch, a spec's default. `sizesThatFit` picks those that meet a
`Shape`: vCPUs, memory, spot, an ephemeral OS disk, Trusted Launch, a
zone.

<!-- snippet: tests/docs_examples.zig#sizes-that-fit -->
```zig
var sizes = try client.listSizes(sub, "eastus2");
defer sizes.deinit();
var buf: [16]compute.Size = undefined;
const fit = compute.sizesThatFit(&buf, sizes.value, .{ .spot = true, .ephemeral_os_disk = true, .max_vcpus = 2 });
// fit: Standard_D2ds_v5 in zone 4 alone, and Standard_D2ds_v7 in all four
```

A zone is a subscription's own number for a physical zone, so zone 1
here may be zone 2 in another subscription: `listLocations` gives each
logical zone's physical one. eastus2 has four.

Every spot VM's vCPUs count against `lowPriorityCores` alone
(`compute.spot_cores`); a family's own quota does not stop one. Over it,
a create is 409 `OperationNotAllowed`, its message naming the quota.

## Errors

`Error` is closed: core's ARM refusals by status (`NotFound`,
`Conflict`, `PreconditionFailed`, `PermissionDenied`, `Throttled` and
the rest), the transport's and the token provider's failures,
`InvalidArgument` for a name, id or spec refused before sending,
`InvalidResponse` for an answer that is not ARM's JSON, and
`InvalidOperation` for a write whose answer cannot be followed. After a
failure, `Diagnostics` has the status, the code and message, and ARM's
request ids.

## Testing code that uses this module

`testing.FakeCompute` is Compute in memory, behind `Options.transport`.
It holds eastus2 and westus2 with their zone mappings and quotas as
measured; `addMeasuredSizes` adds eastus2's sizes as the test
subscription was offered them, `addSize` any other, and `addVm` a VM in
whatever state a test needs. Lists come `page_size` to a page.

Its writes answer as Compute was measured to: a create is 201 and its
operation runs `operation_polls` reads before it ends; a VM there
already is 412 under `If-None-Match: *`; a size or zone not offered is
409 `SkuNotAvailable` (so a test adds the sizes it makes); a create past
the quota is 409 `OperationNotAllowed`, each made VM's vCPUs counted
until it is gone; an evicted VM reads as it was for `eviction_reads`
reads, then is gone. A test can arrange a failed allocation and a lost
answer:

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

<!-- snippet: tests/docs_examples.zig#fake-compute-writes -->
```zig
try fake.failNextCreate("AllocationFailed", "Allocation failed.");
fake.lose_next_create = true; // made, then answered 504
fake.eviction_reads = 3; // an evicted VM's reads before it is gone
fake.operation_polls = 2; // an operation's reads before it ends
```

`examples/spot_vm.zig` makes a spot VM in a subnet of yours from the
first size that fits, waits on it, and deletes it (`zig build
example-spot_vm`, after `az login`).
