//! auth: credentials for every module, through core's `TokenProvider`.
//! `ClientSecret` signs an app in to Entra ID with a client secret;
//! `AzureCli` takes the Azure CLI's login; `StaticToken` holds a token got
//! elsewhere. Each caches its tokens per scope and refreshes them before
//! they expire, so one credential serves several clients at once.
//! `testing.FakeEntra` is Entra's token endpoint in memory.

const core = @import("core");

pub const ClientSecret = @import("ClientSecret.zig");
pub const AzureCli = @import("AzureCli.zig");
pub const Cache = @import("Cache.zig");
pub const StaticToken = core.StaticToken;
pub const TokenProvider = core.TokenProvider;
pub const Diagnostics = core.Diagnostics;
pub const Cloud = core.Cloud;
pub const RetryPolicy = core.RetryPolicy;
/// An allocator that zeroes what it frees, for memory that held a secret,
/// such as a key file read before a credential is made from it.
pub const WipingAllocator = core.WipingAllocator;
pub const transport = core.transport;

/// The token endpoint's rules: tenants, client ids and scopes as Entra
/// takes them for an app's own sign-in.
pub const entra = @import("entra.zig");

/// Fakes for tests of code that uses this module.
pub const testing = struct {
    pub const FakeEntra = @import("fake_entra.zig").FakeEntra;
    pub const FakeClock = core.testing.FakeClock;
};

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("form.zig");
    _ = @import("Cache.zig");
    _ = @import("token_response.zig");
    _ = @import("entra.zig");
    _ = @import("ClientSecret.zig");
    _ = @import("AzureCli.zig");
    _ = @import("fake_entra.zig");
    _ = @import("auth_test.zig");
}
