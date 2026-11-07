//! What the storage client takes and gives back.

const std = @import("std");
const core = @import("core");

/// A value and the arena that holds it: one `deinit` frees both.
pub const Owned = core.Owned;

/// A blob's or a container's version, as Blob Storage writes it in `ETag`:
/// opaque, good only for asking whether two are the same. Headers send it
/// quoted and listings bare; this holds it bare, and quotes it to send.
/// Production's are `0x` and 15 hex digits, which nothing promises.
pub const Etag = struct {
    buf: [max_len]u8 = undefined,
    len: u8 = 0,

    pub const max_len = 64;

    /// From a header (`"0x8D..."`) or a listing (`0x8D...`). Null for one
    /// that is empty, longer than `max_len`, or holds what no ETag does:
    /// a quote inside, a space, a control character.
    pub fn parse(text: []const u8) ?Etag {
        const bare = if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') text[1 .. text.len - 1] else text;
        if (bare.len == 0 or bare.len > max_len) return null;
        for (bare) |c| if (c <= ' ' or c >= 0x7f or c == '"') return null;
        var e: Etag = .{ .len = @intCast(bare.len) };
        @memcpy(e.buf[0..bare.len], bare);
        return e;
    }

    pub fn slice(e: *const Etag) []const u8 {
        return e.buf[0..e.len];
    }

    pub fn eql(a: Etag, b: Etag) bool {
        return std.mem.eql(u8, a.slice(), b.slice());
    }

    /// As a condition sends it: quoted.
    pub fn quoted(e: *const Etag, buf: *[max_len + 2]u8) []const u8 {
        buf[0] = '"';
        @memcpy(buf[1..][0..e.len], e.slice());
        buf[e.len + 1] = '"';
        return buf[0 .. e.len + 2];
    }

    pub fn format(e: Etag, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(e.slice());
    }
};

/// What `If-None-Match` names: any version at all, or one.
pub const Match = union(enum) {
    /// `*`: there is a blob. On a write, `if_none_match = .any` is create
    /// only.
    any,
    etag: Etag,
};

/// The conditions a call holds the blob to. A read takes any of them; a
/// write takes one, or `if_match` with `if_unmodified_since`, or
/// `if_none_match` with `if_modified_since`, as Blob Storage allows.
pub const Conditions = struct {
    /// Only this version: compare and swap. Unmet, `PreconditionFailed`.
    if_match: ?Etag = null,
    /// Not this version, or with `.any` no version at all. Unmet on a
    /// write, `PreconditionFailed`; on a read, `NotModified`.
    if_none_match: ?Match = null,
    /// Changed after this instant, in Unix seconds. Unmet on a read,
    /// `NotModified`.
    if_modified_since: ?i64 = null,
    /// Not changed after this instant, in Unix seconds. Unmet,
    /// `PreconditionFailed`.
    if_unmodified_since: ?i64 = null,

    /// Create only: the write fails, `PreconditionFailed`, when the blob
    /// exists.
    pub const if_absent: Conditions = .{ .if_none_match = .any };

    /// Only the version read: compare and swap.
    pub fn ifMatch(etag: Etag) Conditions {
        return .{ .if_match = etag };
    }

    pub fn isNone(c: Conditions) bool {
        return c.if_match == null and c.if_none_match == null and c.if_modified_since == null and c.if_unmodified_since == null;
    }

    /// Whether a write may carry these: one, or one of the two pairs.
    pub fn validForWrite(c: Conditions) bool {
        const n = @as(u8, @intFromBool(c.if_match != null)) + @intFromBool(c.if_none_match != null) +
            @intFromBool(c.if_modified_since != null) + @intFromBool(c.if_unmodified_since != null);
        if (n <= 1) return true;
        if (n > 2) return false;
        return (c.if_match != null and c.if_unmodified_since != null) or
            (c.if_none_match != null and c.if_modified_since != null);
    }
};

/// Part of a blob: `length` bytes from `offset`, or all of it from there.
pub const Range = struct {
    offset: u64 = 0,
    /// Null: to the end. Never 0.
    length: ?u64 = null,
};

/// One metadata entry. Names are a lowercase letter, then lowercase
/// letters and digits (see `validate.metadataProblem`).
pub const Metadata = struct {
    name: []const u8,
    value: []const u8,
};

pub const BlobType = enum {
    block,
    append,
    page,
    unknown,

    pub fn parse(text: []const u8) BlobType {
        if (std.mem.eql(u8, text, "BlockBlob")) return .block;
        if (std.mem.eql(u8, text, "AppendBlob")) return .append;
        if (std.mem.eql(u8, text, "PageBlob")) return .page;
        return .unknown;
    }
};

/// A blob's properties, as Get Blob Properties and Get Blob answer.
pub const BlobProperties = struct {
    etag: Etag,
    /// The whole blob's size in bytes, a ranged read's included.
    size: u64,
    content_type: []const u8 = "",
    /// Unix seconds, or null when the answer named none.
    last_modified: ?i64 = null,
    created: ?i64 = null,
    /// Base64 MD5 of the whole blob, when it has one: Put Blob always
    /// keeps one.
    content_md5: []const u8 = "",
    blob_type: BlobType = .block,
    metadata: []const Metadata = &.{},

    /// The metadata value named `name`, or null.
    pub fn meta(p: BlobProperties, name: []const u8) ?[]const u8 {
        for (p.metadata) |m| if (std.ascii.eqlIgnoreCase(m.name, name)) return m.value;
        return null;
    }
};

/// A blob read: its bytes, all of them or the range asked, and its
/// properties.
pub const Blob = struct {
    data: []const u8,
    properties: BlobProperties,
};

/// Whether `name` sorts after `after` in byte order; always, with none.
pub fn isAfter(name: []const u8, after: ?[]const u8) bool {
    const bound = after orelse return true;
    return std.mem.order(u8, name, bound) == .gt;
}

/// What a write gives back.
pub const Written = struct {
    etag: Etag,
    last_modified: ?i64 = null,
};

/// A container's properties.
pub const ContainerProperties = struct {
    etag: Etag,
    last_modified: ?i64 = null,
    /// `available`, `leased`, `expired`, `breaking` or `broken`.
    lease_state: []const u8 = "",
    metadata: []const Metadata = &.{},
};

/// One blob in a listing.
pub const ListedBlob = struct {
    name: []const u8,
    etag: Etag,
    size: u64,
    content_type: []const u8 = "",
    last_modified: ?i64 = null,
    /// With `ListOptions.include_metadata` only.
    metadata: []const Metadata = &.{},
};

/// A listing: blobs in name order, and with a delimiter the prefixes that
/// group the rest.
pub const Listing = struct {
    blobs: []const ListedBlob,
    prefixes: []const []const u8 = &.{},
};

pub const PutOptions = struct {
    conditions: Conditions = .{},
    content_type: []const u8 = "application/octet-stream",
    metadata: []const Metadata = &.{},
    /// Send the bytes' CRC-64 (`x-ms-content-crc64`), which the service
    /// checks before it keeps them.
    crc64: bool = true,
};

pub const GetOptions = struct {
    conditions: Conditions = .{},
    /// Null: the whole blob.
    range: ?Range = null,
};

pub const DeleteOptions = struct {
    conditions: Conditions = .{},
};

pub const ListOptions = struct {
    prefix: []const u8 = "",
    /// Group names past `prefix` up to this into `Listing.prefixes`.
    delimiter: ?[]const u8 = null,
    /// Only names that sort after this one, in byte order: `startFrom`, which
    /// the service may ignore and which includes the name itself, and then
    /// the client's own filter.
    after: ?[]const u8 = null,
    include_metadata: bool = false,
    /// Results a page asks for, 1 to 5000. Null: the service's default.
    page_size: ?u32 = null,
};

/// Where the account is.
pub const Endpoint = union(enum) {
    /// `https://{name}.blob.{cloud.storage_suffix}`.
    account: struct {
        name: []const u8,
        cloud: core.Cloud = .public,
    },
    /// Azurite, path style: `{url}/{account}/...`.
    azurite: struct {
        url: []const u8 = "http://127.0.0.1:10000",
        account: []const u8 = "devstoreaccount1",
    },
    /// Any other host, `scheme://host[:port]` with no trailing slash. With
    /// `path_style` the account goes in the path, as Azurite's does.
    custom: struct {
        url: []const u8,
        account: []const u8,
        path_style: bool = false,
    },

    pub fn accountName(e: Endpoint) []const u8 {
        return switch (e) {
            inline else => |x| if (@hasField(@TypeOf(x), "name")) x.name else x.account,
        };
    }
};

/// Azurite's account key, which its documentation publishes.
pub const azurite_key = "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==";

/// How calls are authorized.
pub const Credential = union(enum) {
    /// An Entra token for `core.Cloud.storage_scope`: one of `auth`'s
    /// credentials, or a `core.StaticToken`. The principal needs a data
    /// role, such as Storage Blob Data Contributor.
    token: core.TokenProvider,
    /// The account key, base64 as the portal and ARM's `listKeys` give it.
    /// The account must allow Shared Key.
    shared_key: []const u8,
};

const testing = std.testing;

test "Etag: quoted or bare, the same; refused when it could not be one" {
    const a = Etag.parse("\"0x8DF3CCF278836DE\"").?;
    const b = Etag.parse("0x8DF3CCF278836DE").?;
    try testing.expect(a.eql(b));
    try testing.expectEqualStrings("0x8DF3CCF278836DE", a.slice());
    var buf: [Etag.max_len + 2]u8 = undefined;
    try testing.expectEqualStrings("\"0x8DF3CCF278836DE\"", a.quoted(&buf));
    try testing.expect(!a.eql(Etag.parse("0x8DF3CCF278836DF").?));
    for ([_][]const u8{ "", "\"\"", "\"", "a b", "a\"b", "\x01", core.testing.repeat("a", 65) }) |bad| {
        errdefer std.debug.print("accepted {s}\n", .{bad});
        try testing.expectEqual(null, Etag.parse(bad));
    }
    _ = Etag.parse(core.testing.repeat("a", 64)).?;
}

test "Conditions: what a write may carry" {
    const e = Etag.parse("0x1").?;
    for ([_]Conditions{ .{}, .if_absent, .ifMatch(e), .{ .if_match = e, .if_unmodified_since = 1 }, .{ .if_none_match = .any, .if_modified_since = 1 }, .{ .if_modified_since = 1 } }) |ok| {
        try testing.expect(ok.validForWrite());
    }
    for ([_]Conditions{ .{ .if_match = e, .if_none_match = .any }, .{ .if_match = e, .if_modified_since = 1 }, .{ .if_none_match = .any, .if_unmodified_since = 1 }, .{ .if_match = e, .if_unmodified_since = 1, .if_modified_since = 1 } }) |bad| {
        try testing.expect(!bad.validForWrite());
    }
    try testing.expect((Conditions{}).isNone());
    try testing.expect(!Conditions.if_absent.isNone());
}

test "Endpoint: the account each names" {
    try testing.expectEqualStrings("a", (Endpoint{ .account = .{ .name = "a" } }).accountName());
    try testing.expectEqualStrings("devstoreaccount1", (Endpoint{ .azurite = .{} }).accountName());
    try testing.expectEqualStrings("b", (Endpoint{ .custom = .{ .url = "http://x", .account = "b" } }).accountName());
}
