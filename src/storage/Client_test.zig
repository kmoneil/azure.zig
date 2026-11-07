//! The storage client against FakeBlob, and against answers as production
//! sent them.

const std = @import("std");
const testing = std.testing;
const core = @import("core");
const storage = @import("root.zig");
const Client = storage.Client;
const FakeBlob = storage.testing.FakeBlob;
const Etag = storage.Etag;

const Rig = struct {
    fake: FakeBlob,
    clock: storage.testing.FakeClock,
    diag: storage.Diagnostics,
    client: Client,

    fn init(rig: *Rig) !void {
        return rig.initWith(.{ .shared_key = storage.azurite_key }, true);
    }

    fn initWith(rig: *Rig, credential: storage.Credential, check_namespace: bool) !void {
        rig.fake = .init(testing.allocator);
        errdefer rig.fake.deinit();
        rig.clock = .{};
        rig.diag = .{};
        rig.client = try .init(testing.allocator, rig.clock.io(), .{
            .endpoint = .{ .custom = .{ .url = FakeBlob.default_url, .account = "azzigfake" } },
            .credential = credential,
            .transport = rig.fake.transport(),
            .diagnostics = &rig.diag,
            .check_hierarchical_namespace = check_namespace,
        });
        try rig.fake.addContainer("box");
    }

    fn deinit(rig: *Rig) void {
        rig.client.deinit();
        rig.fake.deinit();
    }

    fn put(rig: *Rig, name: []const u8, data: []const u8, conditions: storage.Conditions) !storage.Written {
        return rig.client.putBlob("box", name, data, .{ .conditions = conditions });
    }

    fn names(rig: *Rig, options: storage.ListOptions) ![]const u8 {
        var listing = try rig.client.listBlobs("box", options);
        defer listing.deinit();
        var out: std.ArrayList(u8) = .empty;
        for (listing.value.blobs) |b| try out.print(testing.allocator, "{s} ", .{b.name});
        for (listing.value.prefixes) |p| try out.print(testing.allocator, "[{s}] ", .{p});
        return out.toOwnedSlice(testing.allocator);
    }

    fn expectNames(rig: *Rig, expected: []const u8, options: storage.ListOptions) !void {
        const got = try rig.names(options);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(expected, got);
    }
};

test "a blob written, read whole and in part, its properties, listed and deleted" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const written = try rig.client.putBlob("box", "jobs/j 1/k.txt", "hello world", .{
        .content_type = "text/plain",
        .metadata = &.{.{ .name = "sha", .value = "abc" }},
    });
    // The first call read the account's properties.
    try testing.expectEqual(.HEAD, rig.fake.calls.items[0].method);
    try testing.expectEqualStrings("restype=account&comp=properties", rig.fake.calls.items[0].query);
    // The name went percent-encoded, and came out as it was.
    try testing.expectEqualStrings("/box/jobs/j 1/k.txt", rig.fake.calls.items[1].path);
    try testing.expect(written.etag.eql(Etag.parse(rig.fake.findBlob("box", "jobs/j 1/k.txt").?.etag).?));

    var whole = try rig.client.getBlob("box", "jobs/j 1/k.txt", .{});
    defer whole.deinit();
    try testing.expectEqualStrings("hello world", whole.value.data);
    try testing.expectEqual(11, whole.value.properties.size);
    try testing.expectEqualStrings("text/plain", whole.value.properties.content_type);
    try testing.expectEqualStrings("abc", whole.value.properties.meta("sha").?);
    try testing.expect(whole.value.properties.etag.eql(written.etag));
    try testing.expect(whole.value.properties.content_md5.len > 0);
    try testing.expect(whole.value.properties.last_modified != null);

    var part = try rig.client.getBlob("box", "jobs/j 1/k.txt", .{ .range = .{ .offset = 6, .length = 5 } });
    defer part.deinit();
    try testing.expectEqualStrings("world", part.value.data);
    try testing.expectEqual(11, part.value.properties.size);
    var tail = try rig.client.getBlob("box", "jobs/j 1/k.txt", .{ .range = .{ .offset = 10 } });
    defer tail.deinit();
    try testing.expectEqualStrings("d", tail.value.data);

    var props = try rig.client.getBlobProperties("box", "jobs/j 1/k.txt", .{});
    defer props.deinit();
    try testing.expectEqual(11, props.value.size);
    try testing.expectEqual(.block, props.value.blob_type);

    var listing = try rig.client.listBlobs("box", .{ .include_metadata = true });
    defer listing.deinit();
    try testing.expectEqual(1, listing.value.blobs.len);
    try testing.expectEqualStrings("jobs/j 1/k.txt", listing.value.blobs[0].name);
    try testing.expect(listing.value.blobs[0].etag.eql(written.etag));
    try testing.expectEqual(11, listing.value.blobs[0].size);
    try testing.expectEqualStrings("abc", listing.value.blobs[0].metadata[0].value);

    try testing.expect(try rig.client.deleteBlob("box", "jobs/j 1/k.txt", .{}));
    try testing.expect(!try rig.client.deleteBlob("box", "jobs/j 1/k.txt", .{}));
    try testing.expectError(error.NotFound, rig.client.getBlob("box", "jobs/j 1/k.txt", .{}));
    try testing.expectEqualStrings("BlobNotFound", rig.diag.code());
    try testing.expectEqual(404, rig.diag.http_status);
    // The account's properties were read once.
    var heads: usize = 0;
    for (rig.fake.calls.items) |c| if (std.mem.eql(u8, c.query, "restype=account&comp=properties")) {
        heads += 1;
    };
    try testing.expectEqual(1, heads);
}

test "conditions: create only, compare and swap, and a read's" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const first = try rig.put("k", "1", .if_absent);
    try testing.expectError(error.PreconditionFailed, rig.put("k", "2", .if_absent));
    try testing.expectEqualStrings("BlobAlreadyExists", rig.diag.code());
    try testing.expectEqual(409, rig.diag.http_status);

    const second = try rig.put("k", "2", .ifMatch(first.etag));
    try testing.expect(!second.etag.eql(first.etag));
    try testing.expectError(error.PreconditionFailed, rig.put("k", "3", .ifMatch(first.etag)));
    try testing.expectEqualStrings("ConditionNotMet", rig.diag.code());
    try testing.expectError(error.PreconditionFailed, rig.put("absent", "x", .ifMatch(first.etag)));

    // Reads: a stale If-Match is 412, a current If-None-Match 304, and a
    // conditional read of a blob not there 404, as production answers.
    try testing.expectError(error.PreconditionFailed, rig.client.getBlob("box", "k", .{ .conditions = .ifMatch(first.etag) }));
    try testing.expectError(error.NotModified, rig.client.getBlob("box", "k", .{ .conditions = .{ .if_none_match = .{ .etag = second.etag } } }));
    try testing.expectError(error.NotFound, rig.client.getBlob("box", "absent", .{ .conditions = .ifMatch(first.etag) }));
    var current = try rig.client.getBlob("box", "k", .{ .conditions = .ifMatch(second.etag) });
    defer current.deinit();
    try testing.expectEqualStrings("2", current.value.data);

    // Dates: a blob not changed since a later instant reads 304.
    const later = rig.fake.clock + 10;
    try testing.expectError(error.NotModified, rig.client.getBlobProperties("box", "k", .{ .if_modified_since = later }));
    try testing.expectError(error.PreconditionFailed, rig.put("k", "4", .{ .if_unmodified_since = later - 1000 }));

    try testing.expectError(error.PreconditionFailed, rig.client.deleteBlob("box", "k", .{ .conditions = .ifMatch(first.etag) }));
    try testing.expect(try rig.client.deleteBlob("box", "k", .{ .conditions = .ifMatch(second.etag) }));
}

test "a conditional write whose answer was lost: its token says it landed" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    rig.fake.lose_next_answer = true;
    const written = try rig.put("k", "mine", .if_absent);
    const blob = rig.fake.findBlob("box", "k").?;
    try testing.expectEqualStrings("mine", blob.data);
    try testing.expect(written.etag.eql(Etag.parse(blob.etag).?));
    try testing.expectEqual(32, blob.meta("azzigwrite").?.len);
    try testing.expectEqual(0, rig.diag.http_status);

    // Compare and swap, the same.
    rig.fake.lose_next_answer = true;
    const swapped = try rig.put("k", "mine again", .ifMatch(written.etag));
    try testing.expect(swapped.etag.eql(Etag.parse(rig.fake.findBlob("box", "k").?.etag).?));

    // Another writer's blob: refused, as it was, after the client looked.
    try rig.fake.putDirect("box", "theirs", "x");
    try testing.expectError(error.PreconditionFailed, rig.put("theirs", "mine", .if_absent));
    try testing.expectEqualStrings("BlobAlreadyExists", rig.diag.code());
    try testing.expectEqualStrings("x", rig.fake.findBlob("box", "theirs").?.data);

    // An unconditional write is tried again, and carries no token.
    rig.fake.lose_next_answer = true;
    _ = try rig.put("plain", "p", .{});
    try testing.expectEqual(null, rig.fake.findBlob("box", "plain").?.meta("azzigwrite"));
}

test "an empty blob reads as empty, whole or from 0; past its end is InvalidRange" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    _ = try rig.put("empty", "", .{});
    var whole = try rig.client.getBlob("box", "empty", .{});
    defer whole.deinit();
    try testing.expectEqualStrings("", whole.value.data);
    var ranged = try rig.client.getBlob("box", "empty", .{ .range = .{ .length = 1 } });
    defer ranged.deinit();
    try testing.expectEqualStrings("", ranged.value.data);
    try testing.expectEqual(0, ranged.value.properties.size);
    try testing.expectError(error.InvalidRange, rig.client.getBlob("box", "empty", .{ .range = .{ .offset = 1 } }));
    _ = try rig.put("three", "abc", .{});
    try testing.expectError(error.InvalidRange, rig.client.getBlob("box", "three", .{ .range = .{ .offset = 3, .length = 1 } }));
    try testing.expectEqualStrings("InvalidRange", rig.diag.code());
}

test "listings: every page, an empty one included; after; a delimiter; an encoded name" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    rig.fake.page_size = 2;
    rig.fake.empty_page_every = 2;
    for ([_][]const u8{ "c", "a/2", "b/1", "a/1", "k\xef\xbf\xbe", "a/3" }) |name| _ = try rig.put(name, name, .{});
    const before = rig.fake.calls.items.len;
    try rig.expectNames("a/1 a/2 a/3 b/1 c k\xef\xbf\xbe ", .{});
    // Six names two to a page, and every second page empty.
    try testing.expect(rig.fake.calls.items.len - before >= 4);
    try rig.expectNames("a/1 a/2 a/3 ", .{ .prefix = "a/" });
    // After a name: startFrom, which includes it, and the client's filter.
    try rig.expectNames("a/3 b/1 c k\xef\xbf\xbe ", .{ .after = "a/2" });
    try rig.expectNames("", .{ .after = "z" });
    try rig.expectNames("c k\xef\xbf\xbe [a/] [b/] ", .{ .delimiter = "/" });
    // A prefix that `after` lies within may still hold names past it.
    try rig.expectNames("c k\xef\xbf\xbe [a/] [b/] ", .{ .delimiter = "/", .after = "a/2" });
    try rig.expectNames("k\xef\xbf\xbe ", .{ .delimiter = "/", .after = "c" });
    try rig.expectNames("a/1 a/2 a/3 ", .{ .prefix = "a/", .page_size = 1, .after = "" });
    _ = try rig.client.deleteBlob("box", "a/3", .{});
    try rig.expectNames("a/1 a/2 ", .{ .prefix = "a/" });
}

test "a listing as production sent it: the byte order mark, elements the client does not read" {
    // Production's body of 2026-11-07, byte for byte but for the
    // account's name in ServiceEndpoint.
    const body = @embedFile("testdata/production_listing.xml");
    var fake: core.testing.FakeTransport = .init(testing.allocator, &.{.{ .respond = .{ .status = 200, .body = body } }});
    defer fake.deinit();
    var clock: storage.testing.FakeClock = .{};
    var client: Client = try .init(testing.allocator, clock.io(), .{
        .endpoint = .{ .account = .{ .name = "azzigexample1" } },
        .credential = .{ .shared_key = storage.azurite_key },
        .transport = fake.transport(),
        .check_hierarchical_namespace = false,
    });
    defer client.deinit();
    var listing = try client.listBlobs("azzig-m0-718nrr6d", .{ .prefix = "k", .after = "k2" });
    defer listing.deinit();
    // startFrom k2 answered k2, k3 and k4; after k2 drops k2.
    try testing.expectEqual(2, listing.value.blobs.len);
    try testing.expectEqualStrings("k3", listing.value.blobs[0].name);
    try testing.expectEqualStrings("0x8DF3CCF2869CE79", listing.value.blobs[0].etag.slice());
    try testing.expectEqual(2, listing.value.blobs[0].size);
    try testing.expectEqualStrings("application/octet-stream", listing.value.blobs[0].content_type);
    const req = try fake.streamRequest(0);
    try testing.expectEqualStrings("https://azzigexample1.blob.core.windows.net/azzig-m0-718nrr6d?restype=container&comp=list&prefix=k&startFrom=k2", req.url);
}

test "production's answers to a HEAD of a blob not there, and a range of an empty one" {
    const not_found: core.testing.FakeTransport.Reply = .{ .respond = .{ .status = 404, .body = "", .headers = &.{
        .{ .name = "x-ms-error-code", .value = "BlobNotFound" },
        .{ .name = "x-ms-request-id", .value = "c4ed0345-001e-0044-73b8-6e30e5000000" },
    } } };
    const empty_range: core.testing.FakeTransport.Reply = .{ .respond = .{ .status = 416, .body = "\xef\xbb\xbf<?xml version=\"1.0\" encoding=\"utf-8\"?><Error><Code>InvalidRange</Code><Message>The range specified is invalid for the current size of the resource.\nRequestId:4d17a1e5-c01e-0016-0cb8-6e4c0d000000\nTime:2026-11-07T13:00:56.3793657Z</Message></Error>", .headers = &.{
        .{ .name = "Content-Range", .value = "bytes */0" },
        .{ .name = "x-ms-error-code", .value = "InvalidRange" },
    } } };
    const empty_head: core.testing.FakeTransport.Reply = .{ .respond = .{ .status = 200, .body = "", .headers = &.{
        .{ .name = "Content-Length", .value = "0" },
        .{ .name = "ETag", .value = "\"0x8DF3CCF27F4A5B1\"" },
        .{ .name = "Last-Modified", .value = "Sat, 07 Nov 2026 13:00:56 GMT" },
    } } };
    var fake: core.testing.FakeTransport = .init(testing.allocator, &.{ not_found, empty_range, empty_head });
    defer fake.deinit();
    var clock: storage.testing.FakeClock = .{};
    var diag: storage.Diagnostics = .{};
    var client: Client = try .init(testing.allocator, clock.io(), .{
        .endpoint = .{ .account = .{ .name = "azzigexample1" } },
        .credential = .{ .shared_key = storage.azurite_key },
        .transport = fake.transport(),
        .diagnostics = &diag,
        .check_hierarchical_namespace = false,
    });
    defer client.deinit();
    try testing.expectError(error.NotFound, client.getBlobProperties("box", "absent", .{}));
    try testing.expectEqualStrings("BlobNotFound", diag.code());
    try testing.expectEqualStrings("c4ed0345-001e-0044-73b8-6e30e5000000", diag.requestId());
    var empty = try client.getBlob("box", "empty", .{ .range = .{ .length = 4 } });
    defer empty.deinit();
    try testing.expectEqualStrings("", empty.value.data);
    try testing.expectEqualStrings("0x8DF3CCF27F4A5B1", empty.value.properties.etag.slice());
    try testing.expectEqual(.HEAD, (try fake.streamRequest(2)).method);
}

test "containers: made, made again, read, deleted, deleted again" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    try testing.expect(try rig.client.createContainer("box2"));
    try testing.expect(!try rig.client.createContainer("box2"));
    var props = try rig.client.getContainerProperties("box2");
    defer props.deinit();
    try testing.expectEqualStrings("available", props.value.lease_state);
    try testing.expect(try rig.client.deleteContainer("box2"));
    try testing.expect(!try rig.client.deleteContainer("box2"));
    try testing.expectError(error.ContainerNotFound, rig.client.getContainerProperties("box2"));
    try testing.expectError(error.ContainerNotFound, rig.client.putBlob("box2", "k", "x", .{}));
    try testing.expectEqualStrings("ContainerNotFound", rig.diag.code());
    try testing.expectError(error.ContainerNotFound, rig.client.listBlobs("box2", .{}));
}

test "a hierarchical account is refused: by its properties, or by a listing's directory" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    rig.fake.hierarchical = true;
    try testing.expectError(error.HierarchicalNamespace, rig.client.listBlobs("box", .{}));
    try testing.expectStringStartsWith(rig.diag.message(), "the account has a hierarchical namespace");
    // Known once, refused at once after.
    const calls = rig.fake.calls.items.len;
    try testing.expectError(error.HierarchicalNamespace, rig.put("k", "x", .{}));
    try testing.expectEqual(calls, rig.fake.calls.items.len);

    var unread: Rig = undefined;
    try unread.init();
    defer unread.deinit();
    unread.fake.hierarchical = true;
    unread.fake.account_info_forbidden = true;
    try unread.fake.putDirect("box", "a/b", "x");
    // The namespace unknown, a write goes; the listing finds a directory.
    _ = try unread.put("k", "x", .{});
    try testing.expectError(error.HierarchicalNamespace, unread.client.listBlobs("box", .{}));
    try testing.expectError(error.HierarchicalNamespace, unread.put("k", "y", .{}));
}

fn accountChecks(fake: *const FakeBlob) usize {
    var n: usize = 0;
    for (fake.calls.items) |c| if (std.mem.eql(u8, c.query, "restype=account&comp=properties")) {
        n += 1;
    };
    return n;
}

test "siblings: one account check for all of them, freed in any order" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.fake.deinit();
    var diags: [3]storage.Diagnostics = @splat(.{});
    var siblings: [3]Client = undefined;
    for (&siblings, &diags) |*s, *d| s.* = try rig.client.sibling(d);
    // A custom transport is shared, as the built-in one is not.
    for (siblings) |s| try testing.expectEqual(null, s.http);
    _ = try siblings[1].putBlob("box", "k", "x", .{});
    try testing.expectEqual(1, accountChecks(&rig.fake));
    try testing.expectEqual(.flat, rig.client.namespace());
    // The first goes; the others, the account known, never check again.
    rig.client.deinit();
    for (&siblings) |*s| {
        var got = try s.getBlob("box", "k", .{});
        got.deinit();
        try testing.expectEqual(.flat, s.namespace());
    }
    try testing.expectEqual(1, accountChecks(&rig.fake));
    // Each reports into its own Diagnostics.
    try testing.expectError(error.NotFound, siblings[2].getBlob("box", "absent", .{}));
    try testing.expectEqualStrings("BlobNotFound", diags[2].code());
    try testing.expectEqualStrings("", diags[0].code());
    for (&siblings) |*s| s.deinit();
}

test "siblings: a hierarchical account found by one is refused by all" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    rig.fake.hierarchical = true;
    var other = try rig.client.sibling(null);
    defer other.deinit();
    try testing.expectError(error.HierarchicalNamespace, other.listBlobs("box", .{}));
    const calls = rig.fake.calls.items.len;
    try testing.expectError(error.HierarchicalNamespace, rig.put("k", "x", .{}));
    try testing.expectEqual(calls, rig.fake.calls.items.len);
}

test "siblings: with the built-in transport each has a connection of its own" {
    var clock: storage.testing.FakeClock = .{};
    var client: Client = try .init(testing.allocator, clock.io(), .{
        .endpoint = .{ .account = .{ .name = "azzigexample1" } },
        .credential = .{ .shared_key = storage.azurite_key },
    });
    defer client.deinit();
    var other = try client.sibling(null);
    defer other.deinit();
    try testing.expect(client.http != null and other.http != null and client.http != other.http);
    try testing.expectEqualStrings(client.engine.base_url, other.engine.base_url);
    try testing.expect(client.engine.base_url.ptr != other.engine.base_url.ptr);
}

test "the account's name and the user agent outlive the options they came in" {
    var fake: FakeBlob = .init(testing.allocator);
    defer fake.deinit();
    try fake.addContainer("box");
    var clock: storage.testing.FakeClock = .{};
    const account = try testing.allocator.dupe(u8, "azzigfake");
    const agent = try testing.allocator.dupe(u8, "app/1.0");
    var client: Client = try .init(testing.allocator, clock.io(), .{
        .endpoint = .{ .custom = .{ .url = FakeBlob.default_url, .account = account } },
        .credential = .{ .shared_key = storage.azurite_key },
        .transport = fake.transport(),
        .user_agent = agent,
    });
    defer client.deinit();
    @memset(account, 'x');
    testing.allocator.free(account);
    testing.allocator.free(agent);
    _ = try client.putBlob("box", "k", "x", .{});
    try testing.expectEqualStrings("azzigfake", client.accountName());
}

test "not asked: no account properties read" {
    var rig: Rig = undefined;
    try rig.initWith(.{ .shared_key = storage.azurite_key }, false);
    defer rig.deinit();
    rig.fake.hierarchical = true;
    _ = try rig.put("k", "x", .{});
    try testing.expectEqual(1, rig.fake.calls.items.len);
}

test "refused before anything is sent" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const e = Etag.parse("0x1").?;
    try testing.expectError(error.InvalidArgument, rig.client.putBlob("C1", "k", "x", .{}));
    try testing.expectError(error.InvalidArgument, rig.client.putBlob("box", "", "x", .{}));
    try testing.expectError(error.InvalidArgument, rig.client.putBlob("box", "a\\b", "x", .{}));
    try testing.expectError(error.InvalidArgument, rig.client.putBlob("box", "a/./b", "x", .{}));
    try testing.expectError(error.InvalidArgument, rig.client.putBlob("box", "k", "x", .{ .metadata = &.{.{ .name = "a-b", .value = "1" }} }));
    try testing.expectError(error.InvalidArgument, rig.client.putBlob("box", "k", "x", .{ .metadata = &.{.{ .name = "azzigwrite", .value = "1" }} }));
    try testing.expectError(error.InvalidArgument, rig.client.putBlob("box", "k", "x", .{ .content_type = "text/plain\r\nX-Evil: 1" }));
    try testing.expectError(error.InvalidArgument, rig.client.putBlob("box", "k", "x", .{ .conditions = .{ .if_match = e, .if_none_match = .any } }));
    try testing.expectError(error.InvalidArgument, rig.client.getBlob("box", "k", .{ .range = .{ .length = 0 } }));
    try testing.expectError(error.InvalidArgument, rig.client.getBlob("box", "k", .{ .range = .{ .offset = std.math.maxInt(u64), .length = 2 } }));
    try testing.expectError(error.InvalidArgument, rig.client.listBlobs("box", .{ .page_size = 0 }));
    try testing.expectError(error.InvalidArgument, rig.client.listBlobs("box", .{ .delimiter = "" }));
    try testing.expectError(error.InvalidArgument, rig.client.listBlobs("box", .{ .prefix = "a\nb" }));
    try testing.expectError(error.InvalidArgument, rig.client.deleteBlob("box", "k", .{ .conditions = .{ .if_match = e, .if_modified_since = 1 } }));
    try testing.expectError(error.InvalidArgument, rig.client.createContainer("a--b"));
    try testing.expectEqual(0, rig.fake.calls.items.len);
    try testing.expectStringStartsWith(rig.diag.message(), "a container name is 3 to 63");

    var diag: storage.Diagnostics = .{};
    var clock: storage.testing.FakeClock = .{};
    for ([_]Client.Options{
        .{ .endpoint = .{ .account = .{ .name = "Bad" } }, .credential = .{ .shared_key = storage.azurite_key }, .diagnostics = &diag },
        .{ .endpoint = .{ .account = .{ .name = "good" } }, .credential = .{ .shared_key = "not base64!" }, .diagnostics = &diag },
        .{ .endpoint = .{ .custom = .{ .url = "https://h/path", .account = "good" } }, .credential = .{ .shared_key = storage.azurite_key }, .diagnostics = &diag },
        .{ .endpoint = .{ .azurite = .{ .url = "127.0.0.1:10000" } }, .credential = .{ .shared_key = storage.azurite_key }, .diagnostics = &diag },
    }) |options| try testing.expectError(error.InvalidArgument, Client.init(testing.allocator, clock.io(), options));
}

/// Recomputes a recorded request's signature from what was sent, the
/// path, query and headers as they went, and holds the client's to it.
fn expectSigned(req: core.testing.FakeTransport.RecordedStream, account: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rest = req.url[std.mem.indexOfPos(u8, req.url, "https://".len, "/").?..];
    const q = std.mem.indexOfScalar(u8, rest, '?');
    var params: std.ArrayList(storage.shared_key.Param) = .empty;
    if (q) |i| {
        var it = std.mem.splitScalar(u8, rest[i + 1 ..], '&');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=').?;
            const value = try a.dupe(u8, pair[eq + 1 ..]);
            try params.append(a, .{ .name = pair[0..eq], .value = std.Uri.percentDecodeInPlace(value) });
        }
    }
    var headers: std.ArrayList(core.transport.Header) = .empty;
    var sent: ?[]const u8 = null;
    for (req.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Authorization")) sent = h.value else try headers.append(a, h);
    }
    const key = try storage.shared_key.Key.decode(storage.azurite_key);
    const expected = try storage.shared_key.authorization(a, account, &key, .{
        .method = req.method,
        .path = rest[0 .. q orelse rest.len],
        .query = params.items,
        .headers = headers.items,
        .content_type = req.content_type,
        .content_length = req.body_len,
    });
    try testing.expectEqualStrings(expected, sent.?);
}

test "Shared Key: each request signed over what it sent; a token instead goes as a bearer" {
    const ok: core.testing.FakeTransport.Reply = .{ .respond = .{ .status = 201, .body = "", .headers = &.{.{ .name = "ETag", .value = "\"0x1\"" }} } };
    const listed: core.testing.FakeTransport.Reply = .{ .respond = .{ .status = 200, .body = "<EnumerationResults><Blobs/><NextMarker/></EnumerationResults>" } };
    var fake: core.testing.FakeTransport = .init(testing.allocator, &.{ ok, listed, ok });
    defer fake.deinit();
    var clock: storage.testing.FakeClock = .{};
    var client: Client = try .init(testing.allocator, clock.io(), .{
        .endpoint = .{ .account = .{ .name = "azzigexample1" } },
        .credential = .{ .shared_key = storage.azurite_key },
        .transport = fake.transport(),
        .check_hierarchical_namespace = false,
    });
    defer client.deinit();
    _ = try client.putBlob("box", "a b/caf\xc3\xa9+1", "hello", .{ .conditions = .if_absent, .metadata = &.{ .{ .name = "a1", .value = "x" }, .{ .name = "ab", .value = "y" } } });
    var listing = try client.listBlobs("box", .{ .prefix = "a b/", .after = "a b/k&=2", .include_metadata = true, .page_size = 7 });
    listing.deinit();
    try testing.expect(try client.deleteBlob("box", "k", .{}));

    const put = try fake.streamRequest(0);
    try testing.expectEqualStrings("https://azzigexample1.blob.core.windows.net/box/a%20b/caf%C3%A9%2B1", put.url);
    try testing.expectEqual(null, put.bearer);
    try testing.expectEqualStrings("2026-04-06", put.header("x-ms-version").?);
    try testing.expect(put.header("x-ms-date") != null);
    try testing.expectEqual(36, put.header("x-ms-client-request-id").?.len);
    try testing.expectEqualStrings("*", put.header("If-None-Match").?);
    try testing.expectEqualStrings("BlockBlob", put.header("x-ms-blob-type").?);
    try testing.expectEqualStrings("application/octet-stream", put.header("x-ms-blob-content-type").?);
    try testing.expectEqualStrings(&core.crc64.toBase64(core.crc64.hash("hello")), put.header("x-ms-content-crc64").?);
    try testing.expectEqual(null, put.content_type);
    for (0..3) |i| try expectSigned(try fake.streamRequest(i), "azzigexample1");
    const list = try fake.streamRequest(1);
    try testing.expectEqualStrings("https://azzigexample1.blob.core.windows.net/box?restype=container&comp=list&prefix=a%20b%2F&startFrom=a%20b%2Fk%26%3D2&maxresults=7&include=metadata", list.url);

    var token: storage.StaticToken = .{ .token = "tok" };
    var bearer_fake: core.testing.FakeTransport = .init(testing.allocator, &.{ok});
    defer bearer_fake.deinit();
    var bearer: Client = try .init(testing.allocator, clock.io(), .{
        .endpoint = .{ .account = .{ .name = "azzigexample1" } },
        .credential = .{ .token = token.provider() },
        .transport = bearer_fake.transport(),
        .check_hierarchical_namespace = false,
    });
    defer bearer.deinit();
    _ = try bearer.putBlob("box", "k", "x", .{});
    const sent = try bearer_fake.streamRequest(0);
    try testing.expectEqualStrings("tok", sent.bearer.?);
    try testing.expectEqual(null, sent.header("Authorization"));
}

test "Azurite: path style, the account in the path and in what is signed" {
    const ok: core.testing.FakeTransport.Reply = .{ .respond = .{ .status = 201, .body = "" } };
    var fake: core.testing.FakeTransport = .init(testing.allocator, &.{ok});
    defer fake.deinit();
    var clock: storage.testing.FakeClock = .{};
    var client: Client = try .init(testing.allocator, clock.io(), .{
        .endpoint = .{ .azurite = .{} },
        .credential = .{ .shared_key = storage.azurite_key },
        .transport = fake.transport(),
        .check_hierarchical_namespace = false,
    });
    defer client.deinit();
    try testing.expect(try client.createContainer("box"));
    const req = try fake.streamRequest(0);
    try testing.expectEqualStrings("http://127.0.0.1:10000/devstoreaccount1/box?restype=container", req.url);
    try testing.expectEqual(.none, req.body_tag);
    try testing.expectEqual(0, req.body_len);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var headers: std.ArrayList(core.transport.Header) = .empty;
    for (req.headers) |h| if (!std.ascii.eqlIgnoreCase(h.name, "Authorization")) try headers.append(arena.allocator(), h);
    const key = try storage.shared_key.Key.decode(storage.azurite_key);
    const expected = try storage.shared_key.authorization(arena.allocator(), "devstoreaccount1", &key, .{
        .method = .PUT,
        .path = "/devstoreaccount1/box",
        .query = &.{.{ .name = "restype", .value = "container" }},
        .headers = headers.items,
    });
    try testing.expectEqualStrings(expected, req.header("Authorization").?);
}

test "retries: a busy server's 503 again, Azurite's FeatureNotSupported never" {
    const busy: core.testing.FakeTransport.Reply = .{ .respond = .{ .status = 503, .body = "", .headers = &.{.{ .name = "x-ms-error-code", .value = "ServerBusy" }} } };
    const ok: core.testing.FakeTransport.Reply = .{ .respond = .{ .status = 201, .body = "", .headers = &.{.{ .name = "ETag", .value = "\"0x2\"" }} } };
    const unsupported: core.testing.FakeTransport.Reply = .{ .respond = .{ .status = 500, .body = "", .headers = &.{.{ .name = "x-ms-error-code", .value = "FeatureNotSupported" }} } };
    var fake: core.testing.FakeTransport = .init(testing.allocator, &.{ busy, ok, unsupported });
    defer fake.deinit();
    var clock: storage.testing.FakeClock = .{};
    var client: Client = try .init(testing.allocator, clock.io(), .{
        .endpoint = .{ .account = .{ .name = "azzigexample1" } },
        .credential = .{ .shared_key = storage.azurite_key },
        .transport = fake.transport(),
        .check_hierarchical_namespace = false,
    });
    defer client.deinit();
    const written = try client.putBlob("box", "k", "x", .{});
    try testing.expectEqualStrings("0x2", written.etag.slice());
    try testing.expectEqual(2, fake.stream_requests.items.len);
    // Each attempt signed afresh, over its own date.
    for (fake.stream_requests.items[0..2]) |r| try expectSigned(r, "azzigexample1");
    try testing.expectError(error.FeatureNotSupported, client.putBlob("box", "k", "x", .{}));
    try testing.expectEqual(3, fake.stream_requests.items.len);
}

// The client over FakeBlob against a model: a map from name to bytes and
// ETag, as puffball's bucket is. Answers lost after a write landed are the
// fake's to make; a conditional write's token must settle each.

const Model = struct {
    names: [keys.len]?Entry = @splat(null),

    const Entry = struct { data: []const u8, etag: Etag };
    const keys = [_][]const u8{ "a", "a/b", "a/c", "b", "b/c" };
};

fn againstModel(_: void, input: []const u8) !void {
    var g: core.testing.ByteGen = .init(input);
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    errdefer std.debug.print("diagnostics: {f}\n", .{rig.diag});
    rig.fake.page_size = g.intRange(usize, 1, 3);
    rig.fake.empty_page_every = g.intRange(usize, 0, 3);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var model: Model = .{};
    const stale = Etag.parse("0x8DF000000000001").?;
    for (0..g.intRange(usize, 1, 30)) |_| {
        const k = g.intRange(usize, 0, Model.keys.len - 1);
        const key = Model.keys[k];
        switch (g.intRange(u8, 0, 5)) {
            0, 1, 2 => {
                const data = try arena.allocator().dupe(u8, g.slice(8));
                const kind = g.intRange(u8, 0, 2);
                const known = model.names[k];
                const conditions: storage.Conditions = switch (kind) {
                    0 => .{},
                    1 => .if_absent,
                    else => .ifMatch(if (known != null and g.boolean()) known.?.etag else stale),
                };
                const expect_ok = switch (kind) {
                    0 => true,
                    1 => known == null,
                    else => known != null and conditions.if_match.?.eql(known.?.etag),
                };
                rig.fake.lose_next_answer = g.boolean();
                if (rig.put(key, data, conditions)) |written| {
                    try testing.expect(expect_ok);
                    model.names[k] = .{ .data = data, .etag = written.etag };
                } else |err| {
                    try testing.expectEqual(error.PreconditionFailed, err);
                    try testing.expect(!expect_ok);
                    rig.fake.lose_next_answer = false;
                }
            },
            3 => {
                if (rig.client.getBlob("box", key, .{})) |got| {
                    var blob = got;
                    defer blob.deinit();
                    const known = model.names[k] orelse return error.TestUnexpectedBlob;
                    try testing.expectEqualStrings(known.data, blob.value.data);
                    try testing.expect(known.etag.eql(blob.value.properties.etag));
                } else |err| {
                    try testing.expectEqual(error.NotFound, err);
                    try testing.expectEqual(null, model.names[k]);
                }
            },
            4 => {
                try testing.expectEqual(model.names[k] != null, try rig.client.deleteBlob("box", key, .{}));
                model.names[k] = null;
            },
            else => try listAgainstModel(&rig, &model, g.pick([]const u8, &.{ "", "a", "a/", "b" }), if (g.boolean()) Model.keys[g.intRange(usize, 0, Model.keys.len - 1)] else null),
        }
    }
}

fn listAgainstModel(rig: *Rig, model: *const Model, prefix: []const u8, after: ?[]const u8) !void {
    var listing = try rig.client.listBlobs("box", .{ .prefix = prefix, .after = after });
    defer listing.deinit();
    var i: usize = 0;
    for (Model.keys, model.names) |key, entry| {
        const e = entry orelse continue;
        if (!std.mem.startsWith(u8, key, prefix) or !storage.isAfter(key, after)) continue;
        try testing.expect(i < listing.value.blobs.len);
        try testing.expectEqualStrings(key, listing.value.blobs[i].name);
        try testing.expect(e.etag.eql(listing.value.blobs[i].etag));
        i += 1;
    }
    try testing.expectEqual(i, listing.value.blobs.len);
}

test "fuzz storage: the client over FakeBlob is a bucket, lost answers and all" {
    try core.testing.fuzzBytes({}, againstModel, .{
        .random_runs = 200,
        .corpus = &.{
            "",
            // Create only, its answer lost, then again: refused.
            "\x02\x00\x01\x00\x00\x00\x02\x01\x01\x00\x00\x00\x02\x01\x00",
        },
    });
}

test "Shared Key: a retry long after the first attempt carries a date and signature of its own" {
    const later: core.testing.FakeTransport.Reply = .{ .respond = .{ .status = 503, .body = "", .headers = &.{
        .{ .name = "x-ms-error-code", .value = "ServerBusy" },
        .{ .name = "Retry-After", .value = "30" },
    } } };
    const ok: core.testing.FakeTransport.Reply = .{ .respond = .{ .status = 201, .body = "", .headers = &.{.{ .name = "ETag", .value = "\"0x3\"" }} } };
    var fake: core.testing.FakeTransport = .init(testing.allocator, &.{ later, ok });
    defer fake.deinit();
    var clock: storage.testing.FakeClock = .{ .now_ns = 1_794_000_000 * std.time.ns_per_s };
    var client: Client = try .init(testing.allocator, clock.io(), .{
        .endpoint = .{ .account = .{ .name = "azzigexample1" } },
        .credential = .{ .shared_key = storage.azurite_key },
        .transport = fake.transport(),
        .check_hierarchical_namespace = false,
    });
    defer client.deinit();
    _ = try client.putBlob("box", "k", "x", .{});
    const first = try fake.streamRequest(0);
    const second = try fake.streamRequest(1);
    // 30 s apart on the fake clock, so the dates differ, and so do the
    // signatures; each is good for its own request.
    try testing.expect(!std.mem.eql(u8, first.header("x-ms-date").?, second.header("x-ms-date").?));
    try testing.expect(!std.mem.eql(u8, first.header("Authorization").?, second.header("Authorization").?));
    try expectSigned(first, "azzigexample1");
    try expectSigned(second, "azzigexample1");
    // One date each: the signer's in place of the call's.
    var dates: usize = 0;
    for (second.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, "x-ms-date")) {
        dates += 1;
    };
    try testing.expectEqual(1, dates);
}
