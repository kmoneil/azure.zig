//! Azure Resource Manager's basics: the subscriptions a credential can see,
//! resource groups made, read, listed by tag and deleted, and resource
//! providers' registration.
//!
//! `Client.createResourceGroup` is one synchronous PUT that makes the group
//! or finds it there already. `Client.beginDeleteResourceGroup` begins a
//! long-running delete and `Client.waitOperation` follows it to its end.
//! `Client.registerProvider` registers a provider only when asked: it
//! needs rights at subscription scope, so nothing here does it on its own.
//!
//! Every client needs a `TokenProvider` for Resource Manager's scope, which
//! the `auth` module supplies; `testing.FakeResources` stands in for ARM.

const core = @import("core");
const types = @import("types.zig");

pub const Client = @import("Client.zig");
pub const Options = Client.Options;
pub const Error = Client.Error;
pub const api_version = Client.api_version;
pub const subscriptions_api_version = Client.subscriptions_api_version;

pub const Owned = types.Owned;
pub const Subscription = types.Subscription;
pub const Tag = types.Tag;
pub const ResourceGroup = types.ResourceGroup;
pub const GroupSpec = types.GroupSpec;
pub const CreatedGroup = types.CreatedGroup;
pub const TagFilter = types.TagFilter;
pub const DeleteOptions = types.DeleteOptions;
pub const Provider = types.Provider;
/// A long-running delete, as `beginDeleteResourceGroup` begins it.
pub const Operation = core.operation.Operation;

pub const Cloud = core.Cloud;
pub const TokenProvider = core.TokenProvider;
pub const StaticToken = core.StaticToken;
pub const Diagnostics = core.Diagnostics;
pub const RetryPolicy = core.RetryPolicy;
/// The HTTP seam: implement `transport.Transport` to send requests another
/// way, or to fake ARM in your own tests.
pub const transport = core.transport;

/// The naming rules the client checks before sending.
pub const limits = @import("validate.zig");

/// What a test of code that uses this module can stand on, with no Azure
/// and no network.
pub const testing = struct {
    /// Resource Manager in memory, behind `Options.transport`:
    /// subscriptions, resource groups (a delete answering 202 until done)
    /// and providers.
    pub const FakeResources = @import("fake_resources.zig").FakeResources;
    /// An `Io` whose clock a test moves, so a delete's polls take no time.
    pub const FakeClock = core.testing.FakeClock;
};

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("validate.zig");
    _ = @import("fake_resources.zig");
    _ = @import("Client_test.zig");
}
