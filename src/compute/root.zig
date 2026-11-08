//! compute: virtual machines on Resource Manager, as puffball's spot
//! workers need them. A VM made from a `VmSpec` (or a body of the
//! caller's own) once, however often the create is tried; deleted,
//! deallocated, started, restarted, and evicted on purpose; every write
//! previewed. A VM and its state from the instance view, lists by group,
//! subscription or region with a tag filter, the sizes a region offers
//! this subscription, its zones, and its quotas. `testing.FakeCompute` is
//! Compute in memory.

const core = @import("core");
const types = @import("types.zig");
const spec = @import("spec.zig");

pub const Client = @import("Client.zig");
pub const Write = Client.Write;
pub const DeleteOptions = Client.DeleteOptions;
pub const Operation = core.operation.Operation;
pub const OperationState = core.operation.State;
pub const PreparedRequest = core.PreparedRequest;
pub const RefusalClass = types.RefusalClass;
pub const VmSpec = spec.VmSpec;
pub const VmPriority = spec.Priority;
pub const Spot = spec.Spot;
pub const Image = spec.Image;
pub const Marketplace = spec.Marketplace;
pub const OsDisk = spec.OsDisk;
pub const ManagedDisk = spec.Managed;
pub const StorageType = spec.StorageType;
pub const Security = spec.Security;
pub const Nic = spec.Nic;
pub const max_data_len = spec.max_data_len;
pub const max_tags = spec.max_tags;
pub const DiskController = types.DiskController;
pub const EphemeralPlacement = types.EphemeralPlacement;
pub const DiskControllers = types.DiskControllers;
pub const EphemeralPlacements = types.EphemeralPlacements;
pub const Owned = types.Owned;
pub const Tag = types.Tag;
pub const Priority = types.Priority;
pub const EvictionPolicy = types.EvictionPolicy;
pub const Provisioning = types.Provisioning;
pub const Power = types.Power;
pub const State = types.State;
pub const VirtualMachine = types.VirtualMachine;
pub const Size = types.Size;
pub const Shape = types.Shape;
pub const sizesThatFit = types.sizesThatFit;
pub const ZoneMapping = types.ZoneMapping;
pub const Location = types.Location;
pub const Usage = types.Usage;
pub const spot_cores = types.spot_cores;
pub const findUsage = types.findUsage;
pub const ListScope = types.ListScope;
pub const ListOptions = types.ListOptions;

pub const Cloud = core.Cloud;
pub const TokenProvider = core.TokenProvider;
pub const StaticToken = core.StaticToken;
pub const Diagnostics = core.Diagnostics;
pub const RetryPolicy = core.RetryPolicy;
pub const transport = core.transport;

/// Fakes for tests of code that uses this module.
pub const testing = struct {
    pub const FakeCompute = @import("fake_compute.zig").FakeCompute;
    pub const FakeClock = core.testing.FakeClock;
};

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("types.zig");
    _ = @import("spec.zig");
    _ = @import("Client.zig");
    _ = @import("fake_compute.zig");
    _ = @import("Client_test.zig");
    _ = @import("write_test.zig");
}
