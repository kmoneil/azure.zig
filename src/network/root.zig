//! Virtual networks, their subnets, and network security groups, on Azure
//! Resource Manager (Microsoft.Network, api-version 2026-03-01): enough
//! network for a fleet of spot VMs.
//!
//! Every write is long-running. `Client.beginCreateVirtualNetwork` and the
//! other `begin` calls send it and return the `Operation`,
//! `Client.waitOperation` follows it to its end, and the `get` calls read
//! what it made. A create makes the resource exactly its spec, whether it
//! is new or there already: a network's subnets and a group's rules become
//! the spec's. A delete of what is not there has nothing to do, and
//! succeeds.
//!
//! A subnet is private unless its spec says otherwise
//! (`SubnetSpec.default_outbound_access`): its VMs reach Storage in their
//! own region and the instance metadata service, and nothing else on the
//! internet without a NAT gateway.
//!
//! Every client needs a `TokenProvider` for Resource Manager's scope, which
//! the `auth` module supplies; `testing.FakeNetwork` stands in for ARM.

const core = @import("core");
const types = @import("types.zig");

pub const Client = @import("Client.zig");
pub const Options = Client.Options;
pub const Error = Client.Error;
pub const api_version = Client.api_version;

pub const Owned = types.Owned;
pub const Tag = types.Tag;
pub const VirtualNetworkSpec = types.VirtualNetworkSpec;
pub const VirtualNetwork = types.VirtualNetwork;
pub const SubnetSpec = types.SubnetSpec;
pub const NamedSubnet = types.NamedSubnet;
pub const Subnet = types.Subnet;
pub const ServiceEndpoint = types.ServiceEndpoint;
pub const SecurityGroupSpec = types.SecurityGroupSpec;
pub const SecurityGroup = types.SecurityGroup;
pub const SecurityRule = types.SecurityRule;
/// A long-running write, as the `begin` calls begin it.
pub const Operation = core.operation.Operation;

pub const Cloud = core.Cloud;
pub const TokenProvider = core.TokenProvider;
pub const StaticToken = core.StaticToken;
pub const Diagnostics = core.Diagnostics;
pub const RetryPolicy = core.RetryPolicy;
/// The HTTP seam: implement `transport.Transport` to send requests another
/// way, or to fake ARM in your own tests.
pub const transport = core.transport;

/// The ARM ids of Network's resources, from their names.
pub const ids = @import("ids.zig");

/// The naming and address rules the client checks before sending.
pub const limits = @import("validate.zig");

/// What a test of code that uses this module can stand on, with no Azure
/// and no network.
pub const testing = struct {
    /// Microsoft.Network in memory, behind `Options.transport`: virtual
    /// networks and their subnets, and network security groups, each write
    /// an operation that runs for a set number of polls.
    pub const FakeNetwork = @import("fake_network.zig").FakeNetwork;
    /// An `Io` whose clock a test moves, so an operation's polls take no
    /// time.
    pub const FakeClock = core.testing.FakeClock;
};

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("validate.zig");
    _ = @import("ids.zig");
    _ = @import("fake_network.zig");
    _ = @import("Client_test.zig");
}
