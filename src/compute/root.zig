//! compute: virtual machines on Resource Manager, as puffball's spot
//! workers need them. m1 reads: a VM and its state from the instance
//! view, lists by group, subscription or region with a tag filter, the
//! sizes a region offers this subscription, its zones, and its quotas.
//! `testing.FakeCompute` is Compute's reads in memory.

const core = @import("core");
const types = @import("types.zig");

pub const Client = @import("Client.zig");
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
    _ = @import("Client.zig");
    _ = @import("fake_compute.zig");
    _ = @import("Client_test.zig");
}
