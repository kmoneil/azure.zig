//! The storage module against Azure itself: the test account
//! (kb/azure-resources), once with Shared Key and once with an Entra token
//! for a principal with Storage Blob Data Contributor there.
//!
//!     AZURE_TEST_STORAGE_ACCOUNT=<name> \
//!     AZURE_TEST_STORAGE_KEY=<key> \
//!     AZURE_TEST_STORAGE_TOKEN=$(AZURE_SCOPE=https://storage.azure.com/.default tools/azure-token.sh) \
//!         zig build test-integration-azure -Dtest-filter=storage
//!
//! Each test skips without the account and its credential. The key is
//! ARM's `listKeys` for the account; never print it. A run writes a few
//! small blobs under its own prefix in the container `azzig-test` and
//! deletes them, and makes and deletes a container of its own: a few cents
//! a month at most. tests/storage_scenario.zig says what a run does.

const std = @import("std");
const storage = @import("storage");
const scenario = @import("storage_scenario.zig");
const testing = std.testing;

fn runWith(env: *const std.process.Environ.Map, credential: storage.Credential) !void {
    var diag: storage.Diagnostics = .{};
    var client: storage.Client = try .init(testing.allocator, testing.io, .{
        .endpoint = .{ .account = .{ .name = env.get("AZURE_TEST_STORAGE_ACCOUNT").? } },
        .credential = credential,
        .diagnostics = &diag,
        .user_agent = "azure-zig-storage-integration/0.1",
    });
    defer client.deinit();
    try scenario.run(&client, &diag, .production);
}

test "storage in production with Shared Key: containers, blobs, conditions, listings" {
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    if (env.get("AZURE_TEST_STORAGE_ACCOUNT") == null) return error.SkipZigTest;
    const key = env.get("AZURE_TEST_STORAGE_KEY") orelse return error.SkipZigTest;
    try runWith(&env, .{ .shared_key = std.mem.trim(u8, key, &std.ascii.whitespace) });
}

test "storage in production with a token: the same, as the test principal" {
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    if (env.get("AZURE_TEST_STORAGE_ACCOUNT") == null) return error.SkipZigTest;
    const text = env.get("AZURE_TEST_STORAGE_TOKEN") orelse return error.SkipZigTest;
    var token: storage.StaticToken = .{ .token = std.mem.trim(u8, text, &std.ascii.whitespace) };
    try runWith(&env, .{ .token = token.provider() });
}
