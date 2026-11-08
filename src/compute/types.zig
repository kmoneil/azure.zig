//! What the compute client gives back.

const std = @import("std");
const core = @import("core");

/// A value and the arena that holds it: one `deinit` frees both.
pub const Owned = core.Owned;
pub const Tag = core.arm.Tag;

pub const Priority = enum {
    regular,
    spot,
    /// `Low`, which Azure deprecates for Spot.
    low,
    spot_plus,
    unknown,

    pub fn parse(text: []const u8) Priority {
        if (std.ascii.eqlIgnoreCase(text, "Regular")) return .regular;
        if (std.ascii.eqlIgnoreCase(text, "Spot")) return .spot;
        if (std.ascii.eqlIgnoreCase(text, "Low")) return .low;
        if (std.ascii.eqlIgnoreCase(text, "SpotPlus")) return .spot_plus;
        return .unknown;
    }
};

pub const EvictionPolicy = enum {
    deallocate,
    delete,
    unknown,

    pub fn parse(text: []const u8) EvictionPolicy {
        if (std.ascii.eqlIgnoreCase(text, "Deallocate")) return .deallocate;
        if (std.ascii.eqlIgnoreCase(text, "Delete")) return .delete;
        return .unknown;
    }
};

/// Where Azure has got to with the VM itself: its `provisioningState`,
/// or the instance view's `ProvisioningState/...` status.
pub const Provisioning = enum {
    creating,
    updating,
    succeeded,
    failed,
    deleting,
    migrating,
    canceled,
    unknown,

    pub fn parse(text: []const u8) Provisioning {
        return parseIgnoringCase(Provisioning, text);
    }
};

/// The machine's power, the instance view's `PowerState/...` status.
pub const Power = enum {
    starting,
    running,
    stopping,
    stopped,
    deallocating,
    deallocated,
    unknown,

    pub fn parse(text: []const u8) Power {
        return parseIgnoringCase(Power, text);
    }
};

/// The tag of `E` that `text` names in any case, or `.unknown`.
fn parseIgnoringCase(comptime E: type, text: []const u8) E {
    var buf: [32]u8 = undefined;
    if (text.len > buf.len) return .unknown;
    return std.meta.stringToEnum(E, std.ascii.lowerString(&buf, text)) orelse .unknown;
}

/// A VM's state, typed from its instance view (measured through a spot
/// VM's life on 2026-11-07: creating, then starting at 6 s, running at
/// 17 s, succeeded at 32 s).
pub const State = struct {
    provisioning: Provisioning,
    /// Null when the answer carried no instance view, as a list's does.
    power: ?Power = null,
    /// The code after `ProvisioningState/failed/`, such as
    /// `AllocationFailed`, when there is one.
    failure: []const u8 = "",

    /// Running and done being made.
    pub fn isRunning(s: State) bool {
        return s.provisioning == .succeeded and s.power == .running;
    }

    /// A failed allocation or update: the VM is there, stuck, and costs
    /// its disks until the caller deletes it (the plan's decision 3).
    pub fn isFailed(s: State) bool {
        return s.provisioning == .failed;
    }
};

pub const VirtualMachine = struct {
    name: []const u8,
    id: []const u8,
    location: []const u8,
    /// Azure's own id for this incarnation, which a VM made again anew
    /// changes.
    vm_id: []const u8,
    size: []const u8,
    /// Null for a VM in no zone.
    zone: ?[]const u8 = null,
    priority: Priority = .regular,
    eviction_policy: ?EvictionPolicy = null,
    /// A spot VM's price limit in US dollars an hour; -1 is the on-demand
    /// price.
    max_price: ?f64 = null,
    state: State,
    time_created: []const u8 = "",
    tags: []const Tag = &.{},
    /// Its NICs' ARM ids. Azure names a NIC made with the VM after the
    /// spec's name for it, with a suffix of its own (measured:
    /// `m0-vm1-nic-10e88ade`).
    nics: []const []const u8 = &.{},

    pub fn tag(vm: VirtualMachine, name: []const u8) ?[]const u8 {
        return core.arm.findTag(vm.tags, name);
    }
};

/// How a VM's disks attach: SCSI, as v5 sizes have, or NVMe, which v6's
/// and v7's take alone.
pub const DiskController = enum {
    scsi,
    nvme,

    pub fn wireName(c: DiskController) []const u8 {
        return switch (c) {
            .scsi => "SCSI",
            .nvme => "NVMe",
        };
    }
};

/// Where an ephemeral OS disk goes on the VM's host.
pub const EphemeralPlacement = enum {
    /// The temporary disk, as v5's `ds` sizes have.
    resource_disk,
    /// The host cache.
    cache_disk,
    /// The local NVMe disk, as v6's and v7's `ds` sizes have.
    nvme_disk,

    pub fn wireName(p: EphemeralPlacement) []const u8 {
        return switch (p) {
            .resource_disk => "ResourceDisk",
            .cache_disk => "CacheDisk",
            .nvme_disk => "NvmeDisk",
        };
    }
};

pub const DiskControllers = struct {
    scsi: bool = true,
    nvme: bool = false,
};

pub const EphemeralPlacements = struct {
    resource_disk: bool = false,
    cache_disk: bool = false,
    nvme_disk: bool = false,

    pub fn has(p: EphemeralPlacements, placement: EphemeralPlacement) bool {
        return switch (placement) {
            .resource_disk => p.resource_disk,
            .cache_disk => p.cache_disk,
            .nvme_disk => p.nvme_disk,
        };
    }
};

/// A VM size as a region offers it to this subscription, from Resource
/// SKUs.
pub const Size = struct {
    name: []const u8,
    vcpus: u32,
    memory_gb: f64,
    /// Whether it can run as Spot (`LowPriorityCapable`).
    spot: bool,
    /// Whether an ephemeral OS disk can go on it.
    ephemeral_os_disk: bool,
    /// The temporary (resource) disk, where an ephemeral OS disk goes on
    /// v5's sizes; 0 on v6's and v7's, which have an NVMe disk instead.
    resource_disk_mb: u64,
    /// The zones it may be made in, after the subscription's restrictions,
    /// in order. Empty where the region has none, or every one is
    /// restricted: then only a VM in no zone.
    zones: []const []const u8,
    /// The controllers it takes (`DiskControllerTypes`): SCSI alone where
    /// Resource SKUs name none, as for v5's sizes.
    disk_controllers: DiskControllers = .{},
    /// Where an ephemeral OS disk may go on it
    /// (`SupportedEphemeralOSDiskPlacements`).
    ephemeral_placements: EphemeralPlacements = .{},
    /// The local NVMe disk (`NvmeDiskSizeInMiB`, in MiB), where an
    /// ephemeral OS disk goes on v6's and v7's sizes.
    nvme_disk_mb: u64 = 0,
    /// False where Resource SKUs say `TrustedLaunchDisabled`: a spec's
    /// default security, Trusted Launch, is refused on it.
    trusted_launch: bool = true,

    pub fn inZone(s: Size, zone: []const u8) bool {
        for (s.zones) |z| if (std.mem.eql(u8, z, zone)) return true;
        return false;
    }

    /// Where a spec's ephemeral OS disk goes on this size: the resource
    /// disk where it may, else the NVMe disk, else the cache; null where
    /// none may.
    pub fn ephemeralPlacement(s: Size) ?EphemeralPlacement {
        if (!s.ephemeral_os_disk) return null;
        for ([_]EphemeralPlacement{ .resource_disk, .nvme_disk, .cache_disk }) |p| if (s.ephemeral_placements.has(p)) return p;
        return null;
    }

    /// The controller a spec names for this size: NVMe where it takes NVMe
    /// alone, else null, Azure's default (SCSI).
    pub fn diskController(s: Size) ?DiskController {
        return if (s.disk_controllers.nvme and !s.disk_controllers.scsi) .nvme else null;
    }
};

/// What a caller needs of a size.
pub const Shape = struct {
    min_vcpus: u32 = 1,
    max_vcpus: ?u32 = null,
    min_memory_gb: f64 = 0,
    spot: bool = false,
    ephemeral_os_disk: bool = false,
    /// Sizes that take Trusted Launch, a spec's default security.
    trusted_launch: bool = false,
    /// In this zone; null: any, a VM in no zone included.
    zone: ?[]const u8 = null,

    pub fn fits(shape: Shape, s: Size) bool {
        if (s.vcpus < shape.min_vcpus) return false;
        if (shape.max_vcpus) |m| if (s.vcpus > m) return false;
        if (s.memory_gb < shape.min_memory_gb) return false;
        if (shape.spot and !s.spot) return false;
        if (shape.ephemeral_os_disk and !s.ephemeral_os_disk) return false;
        if (shape.trusted_launch and !s.trusted_launch) return false;
        if (shape.zone) |z| if (!s.inZone(z)) return false;
        return true;
    }
};

/// The sizes of `sizes` that fit `shape`, in `out`'s order.
pub fn sizesThatFit(out: []Size, sizes: []const Size, shape: Shape) []Size {
    var n: usize = 0;
    for (sizes) |s| if (shape.fits(s)) {
        out[n] = s;
        n += 1;
    };
    return out[0..n];
}

/// A logical zone, as this subscription numbers it, and the physical one
/// it is: another subscription's zone 1 may be another place.
pub const ZoneMapping = struct {
    logical: []const u8,
    physical: []const u8,
};

pub const Location = struct {
    name: []const u8,
    display_name: []const u8,
    /// Empty for a region without zones.
    zones: []const ZoneMapping,
};

/// One quota in a region: how much is used, and the limit.
pub const Usage = struct {
    /// `cores`, `lowPriorityCores` (every spot vCPU), `standardDDSv5Family`...
    name: []const u8,
    display_name: []const u8,
    current: i64,
    limit: i64,
};

/// The quota every spot VM's vCPUs count against, and only it.
pub const spot_cores = "lowPriorityCores";

/// The usage named `name`, or null.
pub fn findUsage(usages: []const Usage, name: []const u8) ?Usage {
    for (usages) |u| if (std.mem.eql(u8, u.name, name)) return u;
    return null;
}

/// Which VMs a list covers.
pub const ListScope = union(enum) {
    subscription,
    group: []const u8,
    /// Every VM of the subscription in a region.
    location: []const u8,
};

pub const ListOptions = struct {
    /// Only VMs with this tag and value. Compute has no filter of its own
    /// for tags: the client reads every page and keeps the matches.
    tag: ?Tag = null,
};

/// What kind of refusal a write met, from its HTTP status and ARM's code
/// and message, so a scheduler can choose what to do next.
pub const RefusalClass = enum {
    /// No room now: `SkuNotAvailable`, `AllocationFailed`,
    /// `ZonalAllocationFailed`, and the `Overconstrained` codes. Another
    /// zone, size or region, or later. `SkuNotAvailable` is also what a
    /// size or zone the subscription may never use gets (measured, 409),
    /// and `listSizes` leaves those out: one of its sizes that meets it is
    /// short of room.
    capacity,
    /// A quota, as `OperationNotAllowed` names one: "exceeding approved
    /// LowPriorityCores quota" (measured, 409). Not until usage drops or
    /// the limit rises.
    quota,
    /// 429: a throttle, Compute's or ARM's. `Diagnostics.retry_after_ms`
    /// says how long, when the loop gave up waiting.
    throttled,
    /// The request itself: a 400, the spot codes among them, such as
    /// `SpotPriceGreaterThanProvidedMaxPrice`.
    invalid,
    /// The subscription's Azure Policy (`RequestDisallowedByPolicy`, 403).
    policy,
    other,

    /// The class of a refusal with HTTP `status`, ARM's `code` and its
    /// message. A failed operation has no status of its own: pass 0.
    pub fn of(status: u16, code: []const u8, message: []const u8) RefusalClass {
        if (status == 429) return .throttled;
        if (oneOf(code, &capacity_codes)) return .capacity;
        if (oneOf(code, &.{ "OperationNotAllowed", "QuotaExceeded" }) and std.ascii.findIgnoreCase(message, "quota") != null) return .quota;
        if (std.ascii.eqlIgnoreCase(code, "RequestDisallowedByPolicy")) return .policy;
        if (status == 400 or oneOf(code, &invalid_codes)) return .invalid;
        return .other;
    }

    /// The class of the latest call's refusal.
    pub fn ofDiagnostics(d: *const core.Diagnostics) RefusalClass {
        return of(d.http_status, d.code(), d.message());
    }

    /// The class of a failed operation's failure.
    pub fn ofOperation(op: *const core.operation.Operation) RefusalClass {
        return of(0, op.failure_code, op.failure_message);
    }

    const capacity_codes = [_][]const u8{
        "SkuNotAvailable",
        "AllocationFailed",
        "ZonalAllocationFailed",
        "OverconstrainedAllocationRequest",
        "OverconstrainedZonalAllocationRequest",
    };

    const invalid_codes = [_][]const u8{
        "InvalidParameter",
        "AzureSpotIsNotSupportedForThisVMSize",
        "SpotPriceGreaterThanProvidedMaxPrice",
        "MaxPriceValueInvalid",
        "EvictionPolicyCanBeSetOnlyOnAzureSpotVirtualMachines",
        "AzureSpotFeatureNotEnabledForSubscription",
    };

    fn oneOf(code: []const u8, codes: []const []const u8) bool {
        for (codes) |c| if (std.ascii.eqlIgnoreCase(code, c)) return true;
        return false;
    }
};

const testing = std.testing;

test "states, priorities and policies parse leniently" {
    try testing.expectEqual(Provisioning.creating, Provisioning.parse("Creating"));
    try testing.expectEqual(Provisioning.succeeded, Provisioning.parse("succeeded"));
    try testing.expectEqual(Provisioning.unknown, Provisioning.parse("Bogus"));
    try testing.expectEqual(Power.deallocated, Power.parse("deallocated"));
    try testing.expectEqual(Priority.spot, Priority.parse("Spot"));
    try testing.expectEqual(Priority.spot_plus, Priority.parse("SpotPlus"));
    try testing.expectEqual(EvictionPolicy.delete, EvictionPolicy.parse("Delete"));
    const s: State = .{ .provisioning = .succeeded, .power = .running };
    try testing.expect(s.isRunning());
    try testing.expect((State{ .provisioning = .failed, .failure = "AllocationFailed" }).isFailed());
    try testing.expect(!(State{ .provisioning = .succeeded }).isRunning());
}

test "a shape fits the sizes that meet it, its zone included" {
    const sizes = [_]Size{
        .{ .name = "a", .vcpus = 2, .memory_gb = 8, .spot = true, .ephemeral_os_disk = true, .resource_disk_mb = 76800, .zones = &.{"4"} },
        .{ .name = "b", .vcpus = 2, .memory_gb = 8, .spot = true, .ephemeral_os_disk = false, .resource_disk_mb = 0, .zones = &.{"4"} },
        .{ .name = "c", .vcpus = 4, .memory_gb = 16, .spot = false, .ephemeral_os_disk = true, .resource_disk_mb = 153600, .zones = &.{ "1", "2" } },
    };
    var buf: [3]Size = undefined;
    try testing.expectEqual(3, sizesThatFit(&buf, &sizes, .{}).len);
    const spot_eph = sizesThatFit(&buf, &sizes, .{ .spot = true, .ephemeral_os_disk = true });
    try testing.expectEqual(1, spot_eph.len);
    try testing.expectEqualStrings("a", spot_eph[0].name);
    try testing.expectEqual(1, sizesThatFit(&buf, &sizes, .{ .min_vcpus = 4 }).len);
    try testing.expectEqual(2, sizesThatFit(&buf, &sizes, .{ .max_vcpus = 2 }).len);
    try testing.expectEqual(1, sizesThatFit(&buf, &sizes, .{ .zone = "1" }).len);
    try testing.expectEqual(0, sizesThatFit(&buf, &sizes, .{ .zone = "3" }).len);
    try testing.expectEqual(1, sizesThatFit(&buf, &sizes, .{ .min_memory_gb = 12 }).len);
}
