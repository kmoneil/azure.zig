//! Shared Key, the Blob service's own signature: HMAC-SHA256, keyed with
//! the account key, over a canonical form of the request
//! (https://learn.microsoft.com/en-us/rest/api/storageservices/authorize-with-shared-key).
//!
//! ```
//! VERB \n Content-Encoding \n Content-Language \n Content-Length \n
//! Content-MD5 \n Content-Type \n Date \n If-Modified-Since \n If-Match \n
//! If-None-Match \n If-Unmodified-Since \n Range \n
//! CanonicalizedHeaders CanonicalizedResource
//! ```
//!
//! Content-Length is empty when it is zero, and Date when `x-ms-date` is
//! sent, as the client always does. CanonicalizedHeaders is every
//! `x-ms-*` header, its name lowercased, sorted, `name:value\n` each.
//! CanonicalizedResource is `/`, the account, and the path exactly as sent,
//! then each query parameter, its name lowercased and its value decoded,
//! sorted by name, as `\nname:value`.
//!
//! The service sorts header names in Go's collation, which ignores `-` and
//! puts `_` before digits before letters, not in byte order. For the names
//! the client sends, its own and metadata names of `[a-z][a-z0-9]*`, the two
//! orders agree, so a byte sort is right; a test holds them to it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const core = @import("core");
const transport = core.transport;

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const base64 = std.base64.standard;

/// An account key, decoded. Azure's are 64 bytes.
pub const Key = struct {
    bytes: [max_len]u8 = undefined,
    len: u8 = 0,

    pub const max_len = 128;

    /// The key from its base64, as the portal and `listKeys` give it.
    pub fn decode(text: []const u8) error{InvalidKey}!Key {
        var key: Key = .{};
        const n = base64.Decoder.calcSizeForSlice(text) catch return error.InvalidKey;
        if (n == 0 or n > max_len) return error.InvalidKey;
        base64.Decoder.decode(key.bytes[0..n], text) catch return error.InvalidKey;
        key.len = @intCast(n);
        return key;
    }

    pub fn slice(key: *const Key) []const u8 {
        return key.bytes[0..key.len];
    }
};

/// One query parameter, its value as it means, before encoding.
pub const Param = struct {
    name: []const u8,
    value: []const u8,
};

/// What the signature covers of one request.
pub const Request = struct {
    method: transport.Method,
    /// The path as sent, percent-encoded, without the query.
    path: []const u8,
    query: []const Param = &.{},
    /// Every header sent but Content-Type and Content-Length, which the
    /// transport writes from the two fields below.
    headers: []const transport.Header,
    content_type: ?[]const u8 = null,
    content_length: u64 = 0,
};

/// The headers whose values stand on lines of their own, in order.
const standard = [_][]const u8{
    "Content-Encoding",  "Content-Language", "Content-Length", "Content-MD5",         "Content-Type", "Date",
    "If-Modified-Since", "If-Match",         "If-None-Match",  "If-Unmodified-Since", "Range",
};

/// The string the signature is the HMAC of, for `account`.
pub fn stringToSign(arena: Allocator, account: []const u8, req: Request) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    write(&out.writer, arena, account, req) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn write(w: *Writer, arena: Allocator, account: []const u8, req: Request) (Writer.Error || Allocator.Error)!void {
    try w.print("{t}\n", .{req.method});
    try writeStandard(w, req);
    try writeCanonicalHeaders(w, arena, req.headers);
    try writeResource(w, arena, account, req);
}

/// The standard headers' lines, each its value or empty.
fn writeStandard(w: *Writer, req: Request) Writer.Error!void {
    for (standard) |name| {
        if (std.mem.eql(u8, name, "Content-Length")) {
            if (req.content_length != 0) try w.print("{d}", .{req.content_length});
        } else if (std.mem.eql(u8, name, "Content-Type")) {
            try w.writeAll(req.content_type orelse "");
        } else if (headerValue(req.headers, name)) |v| {
            try w.writeAll(v);
        }
        try w.writeByte('\n');
    }
}

/// Every `x-ms-*` header, its name lowercased, sorted, `name:value\n`.
fn writeCanonicalHeaders(w: *Writer, arena: Allocator, headers: []const transport.Header) (Writer.Error || Allocator.Error)!void {
    var names: std.ArrayList(transport.Header) = .empty;
    for (headers) |h| if (std.ascii.startsWithIgnoreCase(h.name, "x-ms-")) {
        try names.append(arena, .{ .name = try std.ascii.allocLowerString(arena, h.name), .value = h.value });
    };
    std.mem.sort(transport.Header, names.items, {}, headerLess);
    for (names.items) |h| try w.print("{s}:{s}\n", .{ h.name, std.mem.trim(u8, h.value, " ") });
}

/// `/account/path`, then each query parameter as `\nname:value`.
fn writeResource(w: *Writer, arena: Allocator, account: []const u8, req: Request) (Writer.Error || Allocator.Error)!void {
    try w.print("/{s}{s}", .{ account, req.path });
    const params = try arena.alloc(Param, req.query.len);
    for (req.query, params) |p, *lower| lower.* = .{ .name = try std.ascii.allocLowerString(arena, p.name), .value = p.value };
    std.mem.sort(Param, params, {}, paramLess);
    var i: usize = 0;
    while (i < params.len) {
        // A name given more than once signs once, its values sorted and
        // joined with commas.
        var j = i + 1;
        while (j < params.len and std.mem.eql(u8, params[j].name, params[i].name)) j += 1;
        try w.print("\n{s}:", .{params[i].name});
        for (params[i..j], 0..) |p, k| {
            if (k > 0) try w.writeByte(',');
            try w.writeAll(p.value);
        }
        i = j;
    }
}

fn headerValue(headers: []const transport.Header, name: []const u8) ?[]const u8 {
    for (headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

fn headerLess(_: void, a: transport.Header, b: transport.Header) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn paramLess(_: void, a: Param, b: Param) bool {
    return switch (std.mem.order(u8, a.name, b.name)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.order(u8, a.value, b.value) == .lt,
    };
}

/// The signature's length in base64: 32 bytes of HMAC-SHA256.
pub const signature_len = base64.Encoder.calcSize(HmacSha256.mac_length);

/// Base64 of HMAC-SHA256 over `string_to_sign`, keyed with `key`.
pub fn signature(key: *const Key, string_to_sign: []const u8) [signature_len]u8 {
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, string_to_sign, key.slice());
    var out: [signature_len]u8 = undefined;
    _ = base64.Encoder.encode(&out, &mac);
    std.crypto.secureZero(u8, &mac);
    return out;
}

/// `SharedKey {account}:{signature}`, the Authorization header's value.
pub fn authorization(arena: Allocator, account: []const u8, key: *const Key, req: Request) Allocator.Error![]u8 {
    const sts = try stringToSign(arena, account, req);
    const sig = signature(key, sts);
    return std.fmt.allocPrint(arena, "SharedKey {s}:{s}", .{ account, &sig });
}

const testing = std.testing;

/// Azurite's account key, which its documentation publishes.
const azurite_key = "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==";

test "the key: base64 of up to 128 bytes" {
    const key = try Key.decode(azurite_key);
    try testing.expectEqual(64, key.len);
    for ([_][]const u8{ "", "not base64!", "QQ", "QUJD=" }) |bad| try testing.expectError(error.InvalidKey, Key.decode(bad));
}

test "the string to sign: standard lines, x-ms-* headers sorted, the resource and its query" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sts = try stringToSign(arena.allocator(), "myaccount", .{
        .method = .GET,
        .path = "/mycontainer",
        .query = &.{ .{ .name = "restype", .value = "container" }, .{ .name = "comp", .value = "metadata" }, .{ .name = "timeout", .value = "20" } },
        .headers = &.{ .{ .name = "x-ms-version", .value = "2015-02-21" }, .{ .name = "x-ms-date", .value = "Fri, 26 Jun 2015 23:39:12 GMT" } },
    });
    // Microsoft's own example, which is all its page gives: its signature
    // is a placeholder no key makes.
    try testing.expectEqualStrings("GET\n\n\n\n\n\n\n\n\n\n\n\nx-ms-date:Fri, 26 Jun 2015 23:39:12 GMT\nx-ms-version:2015-02-21\n/myaccount/mycontainer\ncomp:metadata\nrestype:container\ntimeout:20", sts);

    // Content-Length, Content-Type and the conditions on their lines; a
    // query name lowercased and given twice signs once.
    const put = try stringToSign(arena.allocator(), "a", .{
        .method = .PUT,
        .path = "/c/k",
        .query = &.{ .{ .name = "startFrom", .value = "k 2" }, .{ .name = "include", .value = "snapshots" }, .{ .name = "include", .value = "metadata" } },
        .headers = &.{ .{ .name = "If-Match", .value = "\"0x8D\"" }, .{ .name = "X-MS-Meta-B", .value = " 2 " }, .{ .name = "x-ms-date", .value = "d" }, .{ .name = "x-ms-range", .value = "bytes=0-0" } },
        .content_type = "text/plain",
        .content_length = 5,
    });
    try testing.expectEqualStrings("PUT\n\n\n5\n\ntext/plain\n\n\n\"0x8D\"\n\n\n\nx-ms-date:d\nx-ms-meta-b:2\nx-ms-range:bytes=0-0\n/a/c/k\ninclude:metadata,snapshots\nstartfrom:k 2", put);
}

// Signatures made by the Python signer that Azurite 3.37.0 and production
// both accepted in t14's m0 (`_tmp/storage-m0/probe.py`), over these same
// requests, with Azurite's published key: Microsoft publishes no vector
// that any key reproduces. tests/storage_azurite_integration.zig then
// holds this signer to Azurite itself, and the live suite to production.
const Vector = struct { account: []const u8, req: Request, expected: []const u8 };
const date = "Sat, 07 Nov 2026 13:00:00 GMT";
const request_id = "00000000-0000-4000-8000-000000000000";
const vectors = [_]Vector{
    .{
        .account = "devstoreaccount1",
        .req = .{
            .method = .PUT,
            .path = "/devstoreaccount1/c1/a%20b/k.txt",
            .headers = &.{
                .{ .name = "x-ms-blob-type", .value = "BlockBlob" },
                .{ .name = "If-None-Match", .value = "*" },
                .{ .name = "x-ms-meta-ab", .value = "3" },
                .{ .name = "x-ms-meta-a1", .value = "2" },
                .{ .name = "x-ms-content-crc64", .value = "DtjZpL9/o8c=" },
                .{ .name = "x-ms-client-request-id", .value = request_id },
                .{ .name = "x-ms-date", .value = date },
                .{ .name = "x-ms-version", .value = "2026-04-06" },
            },
            .content_type = "text/plain",
            .content_length = 12,
        },
        .expected = "SharedKey devstoreaccount1:TTDDKoz7z2U0i7WG40hkEjcZ6Bm5R+j5En2cmSeTtw0=",
    },
    .{
        .account = "devstoreaccount1",
        .req = .{
            .method = .GET,
            .path = "/devstoreaccount1/c1",
            .query = &.{
                .{ .name = "restype", .value = "container" },
                .{ .name = "comp", .value = "list" },
                .{ .name = "prefix", .value = "a b/" },
                .{ .name = "startFrom", .value = "a b/k2" },
                .{ .name = "maxresults", .value = "2" },
            },
            .headers = &.{
                .{ .name = "x-ms-client-request-id", .value = request_id },
                .{ .name = "x-ms-date", .value = date },
                .{ .name = "x-ms-version", .value = "2026-04-06" },
            },
        },
        .expected = "SharedKey devstoreaccount1:TtDgFospxXfY/WhAdG8uH3oweq/a0GnqaO6F4nJqZwY=",
    },
    .{
        .account = "devstoreaccount1",
        .req = .{
            .method = .PUT,
            .path = "/devstoreaccount1/c1",
            .query = &.{.{ .name = "restype", .value = "container" }},
            .headers = &.{
                .{ .name = "x-ms-client-request-id", .value = request_id },
                .{ .name = "x-ms-date", .value = date },
                .{ .name = "x-ms-version", .value = "2026-04-06" },
            },
        },
        .expected = "SharedKey devstoreaccount1:P4+vHQb5iCR4U85Q0+Ldji8eDNEs7ah9iqgvVKQMupA=",
    },
    .{
        .account = "azzigexample1",
        .req = .{
            .method = .GET,
            .path = "/c1/k1",
            .headers = &.{
                .{ .name = "If-Match", .value = "\"0x8DF3CCF278836DE\"" },
                .{ .name = "If-Modified-Since", .value = "Fri, 06 Nov 2026 00:00:00 GMT" },
                .{ .name = "x-ms-range", .value = "bytes=0-0" },
                .{ .name = "x-ms-client-request-id", .value = request_id },
                .{ .name = "x-ms-date", .value = date },
                .{ .name = "x-ms-version", .value = "2026-04-06" },
            },
        },
        .expected = "SharedKey azzigexample1:ClyYWjTpjo5gAwDsLpypQ77Lsgs2aYfzlSN3QDwz3Zo=",
    },
};

test "signatures: the same as the signer Azurite and production accepted" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const key = try Key.decode(azurite_key);
    for (vectors) |v| {
        const got = try authorization(arena.allocator(), v.account, &key, v.req);
        try testing.expectEqualStrings(v.expected, got);
    }
}

/// Go azblob's order for header names (1.5.0 and later, and the service's
/// as m0 measured it): `-` ignored at first, then `_` before digits before
/// letters, the whole name breaking ties.
fn goCollationLess(_: void, a: []const u8, b: []const u8) bool {
    const Weight = struct {
        fn of(c: u8) u16 {
            if (c == '_') return 0;
            if (c >= '0' and c <= '9') return 0x100 + @as(u16, c);
            return 0x200 + @as(u16, c);
        }
    };
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and a[i] == '-') i += 1;
        while (j < b.len and b[j] == '-') j += 1;
        if (i == a.len or j == b.len) break;
        const wa = Weight.of(a[i]);
        const wb = Weight.of(b[j]);
        if (wa != wb) return wa < wb;
        i += 1;
        j += 1;
    }
    if ((i == a.len) != (j == b.len)) return i == a.len;
    return std.mem.order(u8, a, b) == .lt;
}

fn byteLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Every `x-ms-*` name the client sends but metadata's.
const sent_names = [_][]const u8{
    "x-ms-blob-type", "x-ms-client-request-id", "x-ms-content-crc64",
    "x-ms-date",      "x-ms-delete-snapshots",  "x-ms-range",
    "x-ms-version",   "x-ms-blob-content-type",
};

fn sameOrder(_: void, input: []const u8) !void {
    var g: core.testing.ByteGen = .init(input);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    try names.appendSlice(a, &sent_names);
    // Metadata names as validate takes them: a letter, then letters and digits.
    for (0..g.intRange(usize, 0, 12)) |_| {
        const len = g.intRange(usize, 1, 6);
        const name = try a.alloc(u8, len);
        for (name, 0..) |*c, i| c.* = if (i == 0) g.intRange(u8, 'a', 'z') else g.pick(u8, "abcz0129");
        try names.append(a, try std.fmt.allocPrint(a, "x-ms-meta-{s}", .{name}));
    }
    const by_bytes = try a.dupe([]const u8, names.items);
    std.mem.sort([]const u8, by_bytes, {}, byteLess);
    const by_go = try a.dupe([]const u8, names.items);
    std.mem.sort([]const u8, by_go, {}, goCollationLess);
    for (by_bytes, by_go) |x, y| try testing.expectEqualStrings(x, y);
}

test "fuzz signing order: the client's names sort the same in bytes as in the service's collation" {
    try core.testing.fuzzBytes({}, sameOrder, .{ .corpus = &.{ "", "\x0c\x03a1ab" } });
    // And where they would not: '_', which validate refuses in a name.
    var names = [_][]const u8{ "x-ms-meta-a1", "x-ms-meta-a_b", "x-ms-meta-ab" };
    std.mem.sort([]const u8, &names, {}, goCollationLess);
    try testing.expectEqualStrings("x-ms-meta-a_b", names[0]);
}
