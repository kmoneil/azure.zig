//! Whether a URL a server gave is on the client's own origin, compared as
//! origins rather than bytes: the scheme and host without regard to case,
//! and the port as a number, the scheme's default whether written or not.
//! Azure's Retail Prices API writes every next page as
//! `https://prices.azure.com:443/...`, which a byte compare against
//! `https://prices.azure.com` refuses (rest-core t39); until rest-core's
//! `loop.pathOnOrigin` compares origins, core's links go through this.

const std = @import("std");

/// The path and query of `url` when it names `base_url`'s origin, ready for
/// the request loop, which sends a path only to its own base URL; null for
/// another scheme, host or port, for userinfo, and for anything that is not
/// an absolute http or https URL.
pub fn pathOnOrigin(base_url: []const u8, url: []const u8) ?[]const u8 {
    const base = split(base_url) orelse return null;
    const other = split(url) orelse return null;
    if (!std.ascii.eqlIgnoreCase(base.scheme, other.scheme)) return null;
    if (!std.ascii.eqlIgnoreCase(base.host, other.host)) return null;
    if (base.port != other.port) return null;
    if (other.rest.len == 0 or other.rest[0] != '/') return null;
    return other.rest;
}

const Origin = struct {
    scheme: []const u8,
    host: []const u8,
    port: u16,
    /// What follows the authority: the path and query.
    rest: []const u8,
};

fn split(url: []const u8) ?Origin {
    const colon = std.mem.indexOf(u8, url, "://") orelse return null;
    const scheme = url[0..colon];
    const default_port = defaultPort(scheme) orelse return null;
    const after = url[colon + 3 ..];
    const end = std.mem.indexOfAny(u8, after, "/?#") orelse after.len;
    const authority = after[0..end];
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) return null;
    const host_end = hostEnd(authority) orelse return null;
    if (host_end == 0) return null;
    return .{
        .scheme = scheme,
        .host = authority[0..host_end],
        .port = port(authority[host_end..], default_port) orelse return null,
        .rest = after[end..],
    };
}

fn defaultPort(scheme: []const u8) ?u16 {
    if (std.ascii.eqlIgnoreCase(scheme, "https")) return 443;
    if (std.ascii.eqlIgnoreCase(scheme, "http")) return 80;
    return null;
}

/// Where the host ends in an authority; an IPv6 literal keeps its colons
/// inside brackets.
fn hostEnd(authority: []const u8) ?usize {
    if (authority[0] != '[') return std.mem.indexOfScalar(u8, authority, ':') orelse authority.len;
    return (std.mem.indexOfScalar(u8, authority, ']') orelse return null) + 1;
}

/// The port after the host: nothing, or `:` and digits, none meaning the
/// scheme's default.
fn port(after_host: []const u8, default_port: u16) ?u16 {
    if (after_host.len == 0) return default_port;
    if (after_host[0] != ':') return null;
    const digits = after_host[1..];
    if (digits.len == 0) return default_port;
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u16, digits, 10) catch null;
}

const testing = std.testing;

test "pathOnOrigin: the same origin, the default port written out or not, in any case" {
    const base = "https://prices.azure.com";
    const want = "/api/retail/prices?$skip=1000";
    try testing.expectEqualStrings(want, pathOnOrigin(base, "https://prices.azure.com" ++ want).?);
    try testing.expectEqualStrings(want, pathOnOrigin(base, "https://prices.azure.com:443" ++ want).?);
    try testing.expectEqualStrings(want, pathOnOrigin(base, "HTTPS://Prices.Azure.COM" ++ want).?);
    try testing.expectEqualStrings(want, pathOnOrigin("https://prices.azure.com:443", "https://prices.azure.com" ++ want).?);
    try testing.expectEqualStrings("/x", pathOnOrigin("http://127.0.0.1:10000", "http://127.0.0.1:10000/x").?);
    try testing.expectEqualStrings("/x", pathOnOrigin("http://[::1]:8085", "http://[::1]:8085/x").?);
}

test "pathOnOrigin: another scheme, host, port or userinfo is refused" {
    const base = "https://management.azure.com";
    for ([_][]const u8{
        "https://evil.example/subscriptions",
        "https://management.azure.com.evil.example/subscriptions",
        "https://management.azure.com@evil.example/subscriptions",
        "https://user@management.azure.com/subscriptions",
        "https://management.azure.com:8443/subscriptions",
        "https://management.azure.com:80/subscriptions",
        "http://management.azure.com/subscriptions",
        "https://management.azure.com:443x/subscriptions",
        "https://management.azure.com:99999/subscriptions",
        "https://management.azure.com",
        "https://management.azure.com?x=1",
        "ftp://management.azure.com/x",
        "/subscriptions",
        "",
        "https:///subscriptions",
        "http://[::1/x",
    }) |url| {
        if (pathOnOrigin(base, url)) |p| {
            std.debug.print("taken: {s} -> {s}\n", .{ url, p });
            return error.TestUnexpectedResult;
        }
    }
}

fn property(_: void, input: []const u8) !void {
    // Whatever it takes, it returns a tail of the URL starting with '/', and
    // only when the URL's authority is exactly the base's, case aside.
    const base = "https://management.azure.com";
    const path = pathOnOrigin(base, input) orelse return;
    try testing.expect(path.len > 0 and path[0] == '/');
    try testing.expect(std.mem.endsWith(u8, input, path));
    const authority = input[std.mem.indexOf(u8, input, "://").? + 3 .. input.len - path.len];
    const colon = std.mem.indexOfScalar(u8, authority, ':') orelse authority.len;
    try testing.expect(std.ascii.eqlIgnoreCase(authority[0..colon], "management.azure.com"));
    if (colon + 1 < authority.len) try testing.expectEqual(443, try std.fmt.parseInt(u16, authority[colon + 1 ..], 10));
}

test "fuzz pathOnOrigin: a path only for ARM's own authority" {
    const core_testing = @import("testing.zig");
    try core_testing.fuzzBytes({}, property, .{ .corpus = &.{
        "https://management.azure.com/x",
        "https://management.azure.com:443/x",
        "https://management.azure.com:0443/x",
        "https://management.azure.com.evil.example/x",
        "https://a@management.azure.com/x",
    } });
}
