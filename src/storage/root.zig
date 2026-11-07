//! storage: Blob Storage, as puffball's bucket needs it. Containers, and
//! blobs written in one request, read whole or in part, listed and
//! deleted, with conditions and opaque ETags; Shared Key or an Entra token;
//! and `testing.FakeBlob`, Blob Storage in memory.

const core = @import("core");
const types = @import("types.zig");

pub const Client = @import("Client.zig");
pub const Owned = types.Owned;
pub const Etag = types.Etag;
pub const Match = types.Match;
pub const Conditions = types.Conditions;
pub const Range = types.Range;
pub const Metadata = types.Metadata;
pub const BlobType = types.BlobType;
pub const BlobProperties = types.BlobProperties;
pub const Blob = types.Blob;
pub const Written = types.Written;
pub const ContainerProperties = types.ContainerProperties;
pub const ListedBlob = types.ListedBlob;
pub const Listing = types.Listing;
pub const PutOptions = types.PutOptions;
pub const GetOptions = types.GetOptions;
pub const DeleteOptions = types.DeleteOptions;
pub const ListOptions = types.ListOptions;
pub const Endpoint = types.Endpoint;
pub const Credential = types.Credential;
pub const azurite_key = types.azurite_key;
pub const isAfter = types.isAfter;

pub const Cloud = core.Cloud;
pub const TokenProvider = core.TokenProvider;
pub const StaticToken = core.StaticToken;
pub const Diagnostics = core.Diagnostics;
pub const RetryPolicy = core.RetryPolicy;
pub const transport = core.transport;

/// The rules names and metadata are held to before anything is sent.
pub const limits = @import("validate.zig");
/// The Shared Key signer, for a caller that signs requests of its own.
pub const shared_key = @import("shared_key.zig");

/// Fakes for tests of code that uses this module.
pub const testing = struct {
    pub const FakeBlob = @import("fake_blob.zig").FakeBlob;
    pub const FakeClock = core.testing.FakeClock;
};

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("xml.zig");
    _ = @import("validate.zig");
    _ = @import("shared_key.zig");
    _ = @import("types.zig");
    _ = @import("hook.zig");
    _ = @import("Client.zig");
    _ = @import("fake_blob.zig");
    _ = @import("Client_test.zig");
}
