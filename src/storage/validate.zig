//! What the client checks before anything is sent, since each of these goes
//! into a request's path, query or signed headers: container names, blob
//! names, metadata, and the shared key.

const std = @import("std");
const core = @import("core");

/// The longest blob name, in characters.
pub const max_blob_name = 1024;
/// The most metadata a blob or container holds: names and values together.
pub const max_metadata_bytes = 8 * 1024;
/// The metadata name the client keeps for itself: a conditional write's
/// token, which settles a write whose answer was lost.
pub const write_token_name = "azzigwrite";

/// 3 to 63 of `[a-z0-9-]`, beginning and ending with a letter or digit, and
/// no `--`: Blob Storage's container names.
pub fn isContainerName(name: []const u8) bool {
    if (name.len < 3 or name.len > 63) return false;
    if (!isLowerAlnum(name[0]) or !isLowerAlnum(name[name.len - 1])) return false;
    for (name, 0..) |c, i| {
        if (c == '-') {
            if (name[i - 1] == '-') return false;
        } else if (!isLowerAlnum(c)) return false;
    }
    return true;
}

fn isLowerAlnum(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
}

/// What is wrong with a blob name, or null. Blob Storage takes 1 to 1024
/// characters of valid UTF-8 and no control characters; the client also
/// refuses what the service or a proxy would change on the way: a `\`,
/// which some tools and Azurite take for `/`, a `.` or `..` segment, which a
/// proxy may resolve away, and a name or segment ending in `.`, whose dot
/// the service may drop.
pub fn blobNameProblem(name: []const u8) ?[]const u8 {
    if (name.len == 0) return "a blob name is 1 to 1024 characters";
    if (!std.unicode.utf8ValidateSlice(name)) return "a blob name is valid UTF-8";
    const chars = std.unicode.utf8CountCodepoints(name) catch unreachable;
    if (chars > max_blob_name) return "a blob name is 1 to 1024 characters";
    for (name) |c| {
        if (c < 0x20 or c == 0x7f) return "a blob name holds no control characters";
        if (c == '\\') return "a blob name holds no backslash, which some tools take for '/'";
    }
    var segments = std.mem.splitScalar(u8, name, '/');
    while (segments.next()) |segment| {
        if (std.mem.endsWith(u8, segment, ".")) return "no segment of a blob name ends with '.', which the service may drop";
    }
    if (name[0] == '/') return "a blob name does not begin with '/', which a proxy may merge with the one before it";
    if (std.mem.endsWith(u8, name, "/")) return "a blob name does not end with '/'";
    return null;
}

/// What is wrong with one metadata entry, or null. A name is a lowercase
/// letter, then lowercase letters and digits: within those, the order the
/// client signs headers in is the service's (see `shared_key`). A value is
/// printable ASCII with no space at either end and none doubled, so it
/// reads back as it was sent.
pub fn metadataProblem(name: []const u8, value: []const u8) ?[]const u8 {
    if (name.len == 0 or name.len > 128) return "a metadata name is 1 to 128 characters";
    if (name[0] < 'a' or name[0] > 'z') return "a metadata name begins with a lowercase letter";
    for (name) |c| if (!isLowerAlnum(c)) return "a metadata name is lowercase letters and digits";
    if (std.mem.eql(u8, name, write_token_name)) return "metadata 'azzigwrite' is the client's own";
    for (value, 0..) |c, i| {
        if (c < 0x20 or c > 0x7e) return "a metadata value is printable ASCII";
        if (c == ' ' and (i == 0 or i == value.len - 1 or value[i - 1] == ' ')) return "a metadata value has no space at either end and none doubled";
    }
    return null;
}

/// What is wrong with a set of metadata entries, or null: each entry, no
/// name twice, and `max_metadata_bytes` in all.
pub fn metadataSetProblem(names: []const []const u8, values: []const []const u8) ?[]const u8 {
    var total: usize = 0;
    for (names, values, 0..) |name, value, i| {
        if (metadataProblem(name, value)) |why| return why;
        for (names[0..i]) |earlier| if (std.mem.eql(u8, earlier, name)) return "a metadata name appears once";
        total += name.len + value.len;
    }
    if (total > max_metadata_bytes) return "metadata is at most 8 KiB, names and values together";
    return null;
}

/// A content type, sent as a header and signed as it is: visible ASCII and
/// single spaces, none at either end.
pub fn isContentType(text: []const u8) bool {
    if (text.len == 0 or text.len > 256) return false;
    return core.transport.isValidHeaderValue(text) and std.mem.indexOfScalar(u8, text, '\t') == null;
}

/// Writes `name` as a blob's path: every byte but the unreserved ones and
/// `/` percent-encoded, as the Go SDK sends it, and as it is signed.
pub fn writeBlobPath(w: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    return std.Uri.Component.percentEncode(w, name, isUnreservedOrSlash);
}

fn isUnreservedOrSlash(c: u8) bool {
    return c == '/' or core.query.isUnreserved(c);
}

/// Percent-decodes a listing's `Encoded="true"` name. Null for text that
/// is not percent-encoding.
pub fn percentDecode(arena: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '%') {
            try out.append(arena, text[i]);
            continue;
        }
        if (i + 2 >= text.len) return null;
        const byte = std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16) catch return null;
        try out.append(arena, byte);
        i += 2;
    }
    return try out.toOwnedSlice(arena);
}

const testing = std.testing;
const repeat = core.testing.repeat;

test "container names" {
    for ([_][]const u8{ "abc", "a-b", "0aa", "azzig-test-1a2b3c4d", repeat("a", 63) }) |ok| try testing.expect(isContainerName(ok));
    for ([_][]const u8{ "", "ab", repeat("a", 64), "-ab", "ab-", "a--b", "Abc", "a_b", "a.b", "a b", "$root" }) |bad| {
        errdefer std.debug.print("accepted {s}\n", .{bad});
        try testing.expect(!isContainerName(bad));
    }
}

test "blob names: what the service takes, less what it or a proxy would change" {
    for ([_][]const u8{ "k", "jobs/j_x/events/000000000001.json", "a b", "caf\xc3\xa9", "a..b", "...x", "a/b/c", "a+b=c&d", "a//b", repeat("a", 1024) }) |ok| {
        errdefer std.debug.print("refused {s}\n", .{ok});
        try testing.expectEqual(null, blobNameProblem(ok));
    }
    // 1024 two-byte characters are 1024 characters.
    try testing.expectEqual(null, blobNameProblem(repeat("\xc3\xa9", 1024)));
    for ([_][]const u8{ "", repeat("a", 1025), "\xff", "a\x00b", "a\nb", "a\x7f", "a\\b", "a.", "a/b./c", "./a", "a/..", "a/", "/", "/a" }) |bad| {
        errdefer std.debug.print("accepted {s}\n", .{bad});
        try testing.expect(blobNameProblem(bad) != null);
    }
}

test "metadata: names, values and the whole set" {
    try testing.expectEqual(null, metadataProblem("pbwid", "a1b2"));
    try testing.expectEqual(null, metadataProblem("a1", "a b c"));
    try testing.expectEqual(null, metadataProblem("x", ""));
    for ([_][2][]const u8{
        .{ "", "v" },            .{ "1a", "v" }, .{ "a_b", "v" }, .{ "a-b", "v" },  .{ "Ab", "v" },
        .{ "azzigwrite", "v" },  .{ "a", " v" }, .{ "a", "v " },  .{ "a", "v  w" }, .{ "a", "v\tw" },
        .{ "a", "caf\xc3\xa9" }, .{ "a", "\n" },
    }) |bad| {
        errdefer std.debug.print("accepted {s}={s}\n", .{ bad[0], bad[1] });
        try testing.expect(metadataProblem(bad[0], bad[1]) != null);
    }
    try testing.expectEqual(null, metadataSetProblem(&.{ "a", "b" }, &.{ "1", "2" }));
    try testing.expect(metadataSetProblem(&.{ "a", "a" }, &.{ "1", "2" }) != null);
    const big = repeat("v", 5000);
    try testing.expect(metadataSetProblem(&.{ "a", "b" }, &.{ big, big }) != null);
}

test "a blob's path: everything but unreserved and '/' encoded, and decoded back" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeBlobPath(&w, "a b/c+d%e/caf\xc3\xa9~_.-");
    try testing.expectEqualStrings("a%20b/c%2Bd%25e/caf%C3%A9~_.-", w.buffered());
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("a b/c+d%e/caf\xc3\xa9~_.-", (try percentDecode(arena.allocator(), w.buffered())).?);
    try testing.expectEqualStrings("k\xef\xbf\xbe", (try percentDecode(arena.allocator(), "k%EF%BF%BE")).?);
    for ([_][]const u8{ "%", "%4", "%zz", "a%2" }) |bad| try testing.expectEqual(null, try percentDecode(arena.allocator(), bad));
}

test "content types" {
    try testing.expect(isContentType("application/octet-stream"));
    try testing.expect(isContentType("text/plain; charset=utf-8"));
    for ([_][]const u8{ "", " a", "a ", "a\tb", "a\nb", "caf\xc3\xa9" }) |bad| try testing.expect(!isContentType(bad));
}
