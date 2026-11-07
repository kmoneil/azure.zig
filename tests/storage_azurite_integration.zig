//! The storage module against Azurite, Blob Storage's emulator, with Shared
//! Key and its published key. It holds the client's signing to a service
//! that checks every signature:
//!
//!     npx azurite@3.37.0 --silent --inMemoryPersistence --blobHost 127.0.0.1 &
//!     AZURITE_TEST=1 zig build test-integration
//!
//! Without AZURITE_TEST every test skips; AZURITE_BLOB_URL names another
//! endpoint than http://127.0.0.1:10000. tests/storage_scenario.zig says
//! what a run does.

const std = @import("std");
const storage = @import("storage");
const scenario = @import("storage_scenario.zig");
const testing = std.testing;

test "storage on Azurite: containers, blobs, conditions, listings, as a Blob service answers them" {
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    if (env.get("AZURITE_TEST") == null) return error.SkipZigTest;
    var diag: storage.Diagnostics = .{};
    var client: storage.Client = try .init(testing.allocator, testing.io, .{
        .endpoint = .{ .azurite = .{ .url = env.get("AZURITE_BLOB_URL") orelse "http://127.0.0.1:10000" } },
        .credential = .{ .shared_key = storage.azurite_key },
        .diagnostics = &diag,
        .user_agent = "azure-zig-storage-azurite/0.1",
    });
    defer client.deinit();
    try scenario.run(&client, &diag, .azurite);
}
