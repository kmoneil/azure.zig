//! What both storage suites ask of a real Blob service, Azurite's and
//! production's: containers made and deleted, blobs written, read whole
//! and in part, conditions met and unmet, listings over pages, metadata
//! signed in the service's order, names that need encoding, and deletes.
//!
//! Everything a run writes is under its own prefix, `<run>/`, in the
//! container `azzig-test`, which is kept; the run deletes what it wrote,
//! and the next run deletes anything there a day old. A container of its
//! own, `azzig-test-<run>`, is made and deleted at once.
//!
//! Each `fact:` line is something the module or FakeBlob assumes of the
//! service, printed as found.

const std = @import("std");
const storage = @import("storage");
const testing = std.testing;

pub const container = "azzig-test";
/// What a run older than this left is deleted by the next.
pub const max_age_s = 24 * 60 * 60;

pub const Target = enum { azurite, production };

pub fn fact(comptime format: []const u8, args: anytype) void {
    std.debug.print("  fact: " ++ format ++ "\n", args);
}

/// Eight hex digits, a run's own.
pub fn runId(io: std.Io) [8]u8 {
    var bytes: [4]u8 = undefined;
    io.random(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

fn nowSeconds() i64 {
    return std.Io.Clock.real.now(testing.io).toSeconds();
}

/// Says what failed, as Diagnostics has it, then passes the error on.
fn explain(diag: *const storage.Diagnostics, err: anyerror) anyerror {
    std.debug.print("  failed: {t}: {f}\n", .{ err, diag.* });
    return err;
}

pub fn run(client: *storage.Client, diag: *storage.Diagnostics, target: Target) !void {
    const run_id = runId(testing.io);
    var buf: [64]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&buf, "{s}/", .{&run_id});

    fact("made {s}: {}", .{ container, client.createContainer(container) catch |err| return explain(diag, err) });
    fact("the account's namespace: {t}", .{client.namespace()});
    _ = try sweep(client, diag);
    defer cleanUp(client, prefix);

    try containers(client, diag, &run_id);
    try blobs(client, diag, prefix, target);
    try conditions(client, diag, prefix, target);
    try listings(client, diag, prefix);

    cleanUp(client, prefix);
    var left = client.listBlobs(container, .{ .prefix = prefix }) catch |err| return explain(diag, err);
    defer left.deinit();
    try testing.expectEqual(0, left.value.blobs.len);
}

/// Deletes the blobs earlier runs left a day ago or more.
fn sweep(client: *storage.Client, diag: *storage.Diagnostics) !usize {
    var all = client.listBlobs(container, .{}) catch |err| return explain(diag, err);
    defer all.deinit();
    var deleted: usize = 0;
    for (all.value.blobs) |b| {
        const modified = b.last_modified orelse continue;
        if (nowSeconds() - modified < max_age_s) continue;
        if (client.deleteBlob(container, b.name, .{}) catch false) deleted += 1;
    }
    fact("{d} blob(s) a day old or more deleted", .{deleted});
    return deleted;
}

fn cleanUp(client: *storage.Client, prefix: []const u8) void {
    var mine = client.listBlobs(container, .{ .prefix = prefix }) catch return;
    defer mine.deinit();
    for (mine.value.blobs) |b| _ = client.deleteBlob(container, b.name, .{}) catch {};
}

fn containers(client: *storage.Client, diag: *storage.Diagnostics, run_id: []const u8) !void {
    var buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&buf, "azzig-test-{s}", .{run_id});
    try testing.expect(client.createContainer(name) catch |err| return explain(diag, err));
    try testing.expect(!(client.createContainer(name) catch |err| return explain(diag, err)));
    var props = client.getContainerProperties(name) catch |err| return explain(diag, err);
    defer props.deinit();
    fact("a new container: lease state {s}, ETag {f}", .{ props.value.lease_state, props.value.etag });
    try testing.expect(client.deleteContainer(name) catch |err| return explain(diag, err));
    // Deleted, a container may go on answering for 30 seconds: either is
    // the service's.
    fact("a container just deleted, deleted again: {}", .{client.deleteContainer(name) catch |err| return explain(diag, err)});
}

fn blobs(client: *storage.Client, diag: *storage.Diagnostics, prefix: []const u8, target: Target) !void {
    var buf: [128]u8 = undefined;
    // A space, an accented letter and a plus, each of which goes encoded.
    const name = try std.fmt.bufPrint(&buf, "{s}a b/caf\xc3\xa9+1.txt", .{prefix});
    const written = client.putBlob(container, name, "hello world", .{
        .content_type = "text/plain; charset=utf-8",
        // Names whose order a byte sort and the service's collation agree
        // on, signed.
        .metadata = &.{ .{ .name = "ab", .value = "b" }, .{ .name = "a1", .value = "a one" } },
    }) catch |err| return explain(diag, err);
    fact("a new blob's ETag: {f}", .{written.etag});

    var whole = client.getBlob(container, name, .{}) catch |err| return explain(diag, err);
    defer whole.deinit();
    try testing.expectEqualStrings("hello world", whole.value.data);
    try testing.expect(whole.value.properties.etag.eql(written.etag));
    try testing.expectEqualStrings("text/plain; charset=utf-8", whole.value.properties.content_type);
    try testing.expectEqualStrings("a one", whole.value.properties.meta("a1").?);
    try testing.expectEqualStrings("b", whole.value.properties.meta("ab").?);
    try testing.expectEqual(.block, whole.value.properties.blob_type);
    fact("Content-MD5 on a whole read: {s}", .{whole.value.properties.content_md5});

    var part = client.getBlob(container, name, .{ .range = .{ .offset = 6, .length = 5 } }) catch |err| return explain(diag, err);
    defer part.deinit();
    try testing.expectEqualStrings("world", part.value.data);
    try testing.expectEqual(11, part.value.properties.size);

    const empty_name = try std.fmt.bufPrint(buf[64..], "{s}empty", .{prefix});
    _ = client.putBlob(container, empty_name, "", .{}) catch |err| return explain(diag, err);
    var empty = client.getBlob(container, empty_name, .{ .range = .{ .length = 1 } }) catch |err| return explain(diag, err);
    defer empty.deinit();
    try testing.expectEqualStrings("", empty.value.data);
    try testing.expectEqual(0, empty.value.properties.size);
    // A range from the blob's end: 416 in production as the research has
    // it; Azurite answers it with no bytes.
    if (client.getBlob(container, name, .{ .range = .{ .offset = 11 } })) |b| {
        var blob = b;
        defer blob.deinit();
        fact("a range from the end: answered, {d} byte(s)", .{blob.value.data.len});
        if (target == .production) return error.TestExpectedInvalidRange;
    } else |err| {
        fact("a range from the end: {t}, {d} {s}", .{ err, diag.http_status, diag.code() });
        try testing.expectEqual(error.InvalidRange, err);
    }

    try testing.expect(client.deleteBlob(container, empty_name, .{}) catch |err| return explain(diag, err));
    try testing.expect(!(client.deleteBlob(container, empty_name, .{}) catch |err| return explain(diag, err)));
    try testing.expectError(error.NotFound, client.getBlobProperties(container, empty_name, .{}));
    fact("a HEAD of a blob not there: {d} {s}", .{ diag.http_status, diag.code() });
    try testing.expectError(error.ContainerNotFound, client.getBlob("azzig-none", "k", .{}));
}

fn conditions(client: *storage.Client, diag: *storage.Diagnostics, prefix: []const u8, target: Target) !void {
    var buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&buf, "{s}cas", .{prefix});
    const first = client.putBlob(container, name, "1", .{ .conditions = .if_absent }) catch |err| return explain(diag, err);
    try testing.expectError(error.PreconditionFailed, client.putBlob(container, name, "2", .{ .conditions = .if_absent }));
    fact("create only over a blob: {d} {s}", .{ diag.http_status, diag.code() });
    const second = client.putBlob(container, name, "2", .{ .conditions = .ifMatch(first.etag) }) catch |err| return explain(diag, err);
    try testing.expectError(error.PreconditionFailed, client.putBlob(container, name, "3", .{ .conditions = .ifMatch(first.etag) }));
    fact("compare and swap, stale: {d} {s}", .{ diag.http_status, diag.code() });

    try testing.expectError(error.PreconditionFailed, client.getBlob(container, name, .{ .conditions = .ifMatch(first.etag) }));
    try testing.expectError(error.NotModified, client.getBlob(container, name, .{ .conditions = .{ .if_none_match = .{ .etag = second.etag } } }));
    var current = client.getBlob(container, name, .{ .conditions = .ifMatch(second.etag) }) catch |err| return explain(diag, err);
    defer current.deinit();
    try testing.expectEqualStrings("2", current.value.data);

    // A conditional read of a blob not there: 404 in production, 412 in
    // Azurite (t14's m0).
    var absent_buf: [64]u8 = undefined;
    const absent = try std.fmt.bufPrint(&absent_buf, "{s}absent", .{prefix});
    const got = client.getBlob(container, absent, .{ .conditions = .ifMatch(first.etag) });
    if (got) |b| {
        var blob = b;
        blob.deinit();
        return error.TestUnexpectedBlob;
    } else |err| {
        fact("a conditional read of a blob not there: {t}, {d} {s}", .{ err, diag.http_status, diag.code() });
        try testing.expectEqual(switch (target) {
            .production => error.NotFound,
            .azurite => error.PreconditionFailed,
        }, err);
    }
    try testing.expectError(error.PreconditionFailed, client.putBlob(container, absent, "x", .{ .conditions = .ifMatch(first.etag) }));

    try testing.expectError(error.PreconditionFailed, client.deleteBlob(container, name, .{ .conditions = .ifMatch(first.etag) }));
    try testing.expect(client.deleteBlob(container, name, .{ .conditions = .ifMatch(second.etag) }) catch |err| return explain(diag, err));
}

fn listings(client: *storage.Client, diag: *storage.Diagnostics, prefix: []const u8) !void {
    const names = [_][]const u8{ "l/a/1", "l/a/2", "l/b/1", "l/c", "l/d" };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (names) |n| {
        const full = try std.fmt.allocPrint(a, "{s}{s}", .{ prefix, n });
        _ = client.putBlob(container, full, n, .{ .metadata = &.{.{ .name = "n", .value = n }} }) catch |err| return explain(diag, err);
    }
    const under = try std.fmt.allocPrint(a, "{s}l/", .{prefix});

    // Two to a page: three pages.
    var paged = client.listBlobs(container, .{ .prefix = under, .page_size = 2, .include_metadata = true }) catch |err| return explain(diag, err);
    defer paged.deinit();
    try testing.expectEqual(names.len, paged.value.blobs.len);
    for (names, paged.value.blobs) |n, b| {
        try testing.expectStringEndsWith(b.name, n);
        try testing.expectEqualStrings(n, b.metadata[0].value);
    }

    // After a name: startFrom includes it, the client's filter drops it.
    const after = try std.fmt.allocPrint(a, "{s}l/a/2", .{prefix});
    var later = client.listBlobs(container, .{ .prefix = under, .after = after }) catch |err| return explain(diag, err);
    defer later.deinit();
    try testing.expectEqual(3, later.value.blobs.len);
    try testing.expectStringEndsWith(later.value.blobs[0].name, "l/b/1");

    var grouped = client.listBlobs(container, .{ .prefix = under, .delimiter = "/" }) catch |err| return explain(diag, err);
    defer grouped.deinit();
    try testing.expectEqual(2, grouped.value.blobs.len);
    try testing.expectEqual(2, grouped.value.prefixes.len);
    try testing.expectStringEndsWith(grouped.value.prefixes[0], "l/a/");
    fact("a listing grouped by '/': {d} blob(s), {d} prefix(es)", .{ grouped.value.blobs.len, grouped.value.prefixes.len });
}
