//! What the client checks before it sends: Microsoft.Network's own naming
//! rules, address ranges and ports, beside ARM's common ones in
//! `core.names`. A name goes into an ARM path, so its check is what keeps
//! a caller's string from naming another resource; the rest go into a
//! request's JSON, and are checked so a mistake is refused here, with what
//! was wrong, rather than by Azure after a round trip.

const std = @import("std");
const core = @import("core");

pub const isSubscription = core.names.isSubscription;
pub const isGroupName = core.names.isGroupName;
pub const isLocation = core.names.isLocation;

/// A Microsoft.Network name: `min` to `max` of letters, digits, `.`, `-`
/// and `_`, beginning with a letter or digit and ending with one or `_`.
fn isName(text: []const u8, min: usize, max: usize) bool {
    if (text.len < min or text.len > max) return false;
    if (!std.ascii.isAlphanumeric(text[0])) return false;
    const last = text[text.len - 1];
    if (!std.ascii.isAlphanumeric(last) and last != '_') return false;
    for (text) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, ".-_", c) == null) return false;
    return true;
}

/// A virtual network's name: 2 to 64, by the rule above.
pub fn isNetworkName(text: []const u8) bool {
    return isName(text, 2, 64);
}

/// A subnet's, a network security group's or a rule's name: 1 to 80, by
/// the rule above.
pub fn isChildName(text: []const u8) bool {
    return isName(text, 1, 80);
}

/// An IPv4 range in CIDR notation, parsed.
pub const Cidr4 = struct {
    base: u32,
    bits: u6,

    pub fn mask(bits: u6) u32 {
        if (bits == 0) return 0;
        return @as(u32, std.math.maxInt(u32)) << @intCast(32 - @as(u7, bits));
    }

    /// Whether `inner` lies wholly inside `self`.
    pub fn contains(self: Cidr4, inner: Cidr4) bool {
        return inner.bits >= self.bits and (inner.base & mask(self.bits)) == self.base;
    }

    pub fn overlaps(a: Cidr4, b: Cidr4) bool {
        const m = mask(@min(a.bits, b.bits));
        return (a.base & m) == (b.base & m);
    }
};

/// `a.b.c.d/n` with no host bits set, as Azure requires
/// (`InvalidCIDRNotation` otherwise); null for anything else.
pub fn parseCidr4(text: []const u8) ?Cidr4 {
    const slash = std.mem.indexOfScalar(u8, text, '/') orelse return null;
    const base = parseIpv4(text[0..slash]) orelse return null;
    const bits = parseDecimal(text[slash + 1 ..], 32) orelse return null;
    const cidr: Cidr4 = .{ .base = base, .bits = @intCast(bits) };
    if (base & ~Cidr4.mask(cidr.bits) != 0) return null;
    return cidr;
}

/// `a.b.c.d`, each part 0 to 255 without leading zeros.
pub fn parseIpv4(text: []const u8) ?u32 {
    var out: u32 = 0;
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, text, '.');
    while (it.next()) |part| : (parts += 1) {
        if (parts == 4) return null;
        const n = parseDecimal(part, 255) orelse return null;
        out = (out << 8) | n;
    }
    return if (parts == 4) out else null;
}

/// A decimal number from 0 to `max`, without a sign or leading zeros.
fn parseDecimal(text: []const u8, max: u32) ?u32 {
    if (text.len == 0 or text.len > 5 or (text.len > 1 and text[0] == '0')) return null;
    for (text) |c| if (!std.ascii.isDigit(c)) return null;
    const n = std.fmt.parseInt(u32, text, 10) catch return null;
    return if (n <= max) n else null;
}

/// An IPv6 range in CIDR notation, checked by its shape only: hex groups
/// and colons, `::` at most once, and a prefix length up to 128.
fn isCidr6(text: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, text, '/') orelse return false;
    if (parseDecimal(text[slash + 1 ..], 128) == null) return false;
    const addr = text[0..slash];
    if (addr.len < 2 or std.mem.indexOfScalar(u8, addr, ':') == null) return false;
    const double = std.mem.indexOf(u8, addr, "::");
    if (double) |i| if (std.mem.indexOfPos(u8, addr, i + 1, "::") != null) return false;
    for (addr) |c| if (!std.ascii.isHex(c) and c != ':') return false;
    return true;
}

/// A range for a network or a subnet: an IPv4 CIDR with no host bits set,
/// or an IPv6 one.
pub fn isCidr(text: []const u8) bool {
    return parseCidr4(text) != null or isCidr6(text);
}

/// A service endpoint's service, such as `Microsoft.Storage` or
/// `Microsoft.Storage.Global`.
pub fn isService(text: []const u8) bool {
    if (text.len == 0 or text.len > 128 or text[0] == '.' or text[text.len - 1] == '.') return false;
    for (text) |c| if (!std.ascii.isAlphanumeric(c) and c != '.') return false;
    return true;
}

/// A rule's address: `*`, an address or a CIDR, or a service tag such as
/// `Internet` or `Storage.EastUS2`.
pub fn isAddressPrefix(text: []const u8) bool {
    if (std.mem.eql(u8, text, "*")) return true;
    if (text.len == 0 or text.len > 128) return false;
    for (text) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, ".:/-_", c) == null) return false;
    return true;
}

/// A rule's ports: `*`, a port from 0 to 65535, or `low-high` with low no
/// greater than high.
pub fn isPortRange(text: []const u8) bool {
    if (std.mem.eql(u8, text, "*")) return true;
    const dash = std.mem.indexOfScalar(u8, text, '-') orelse return parseDecimal(text, 65535) != null;
    const low = parseDecimal(text[0..dash], 65535) orelse return false;
    const high = parseDecimal(text[dash + 1 ..], 65535) orelse return false;
    return low <= high;
}

/// A rule's description: up to 140 bytes of valid UTF-8, no control
/// bytes.
pub fn isDescription(text: []const u8) bool {
    if (text.len > 140 or !std.unicode.utf8ValidateSlice(text)) return false;
    for (text) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

/// The ARM id of a Microsoft.Network resource of `kind`, such as
/// `networkSecurityGroups`: `/subscriptions/.../providers/Microsoft.Network/{kind}/{name}`,
/// in any case, valid UTF-8, and no spaces or control bytes. It catches a
/// bare name given where the id belongs, or another kind's id.
pub fn isNetworkId(text: []const u8, comptime kind: []const u8) bool {
    if (text.len > 1024 or !std.ascii.startsWithIgnoreCase(text, "/subscriptions/")) return false;
    if (!std.unicode.utf8ValidateSlice(text)) return false;
    for (text) |c| if (c <= 0x20 or c == 0x7f) return false;
    const marker = "/providers/microsoft.network/" ++ kind ++ "/";
    if (text.len <= marker.len) return false;
    for (0..text.len - marker.len) |at| {
        if (std.ascii.eqlIgnoreCase(text[at..][0..marker.len], marker)) return true;
    }
    return false;
}

const testing = std.testing;

test "isNetworkName and isChildName: Network's characters, ends and lengths" {
    for ([_][]const u8{ "pb-vnet", "a1", "vnet_", "v.1-x_", &@as([64]u8, @splat('v')) }) |s| try testing.expect(isNetworkName(s));
    for ([_][]const u8{ "", "a", "-vnet", "vnet-", "vnet.", "a/b", "a b", "..", &@as([65]u8, @splat('v')) }) |s| try testing.expect(!isNetworkName(s));
    for ([_][]const u8{ "w", "workers", "AllowSsh_", &@as([80]u8, @splat('s')) }) |s| try testing.expect(isChildName(s));
    for ([_][]const u8{ "", "_a", "a.", "a?b", &@as([81]u8, @splat('s')) }) |s| try testing.expect(!isChildName(s));
}

test "parseCidr4: a range with no host bits, and contains and overlaps" {
    const vnet = parseCidr4("10.0.0.0/16").?;
    try testing.expectEqual(0x0a000000, vnet.base);
    try testing.expectEqual(16, vnet.bits);
    const sub = parseCidr4("10.0.1.0/24").?;
    try testing.expect(vnet.contains(sub));
    try testing.expect(!sub.contains(vnet));
    try testing.expect(!vnet.contains(parseCidr4("10.1.0.0/24").?));
    try testing.expect(sub.overlaps(vnet));
    try testing.expect(!sub.overlaps(parseCidr4("10.0.2.0/24").?));
    try testing.expect(parseCidr4("0.0.0.0/0").?.contains(sub));
    try testing.expect(parseCidr4("10.0.0.7/32") != null);
    for ([_][]const u8{ "10.0.1.5/24", "10.0.0.0", "10.0.0/16", "10.0.0.0.0/8", "256.0.0.0/8", "10.0.0.0/33", "010.0.0.0/8", "10.0.0.0/016", "10.0.0.0/", "/8", "a.b.c.d/8" }) |s| {
        try testing.expectEqual(null, parseCidr4(s));
    }
}

test "isCidr: IPv4 and IPv6 ranges" {
    for ([_][]const u8{ "10.0.0.0/16", "fd00:db8::/48", "ace:cab:deca::/48", "::/0" }) |s| try testing.expect(isCidr(s));
    for ([_][]const u8{ "", "10.0.0.1/16", "fd00::db8::/48", "fd00:db8::/129", "fd00:gb8::/48", "fd00:db8::", "10.0.0.0/16\"" }) |s| try testing.expect(!isCidr(s));
}

test "isService, isAddressPrefix, isPortRange, isDescription" {
    try testing.expect(isService("Microsoft.Storage"));
    try testing.expect(isService("Microsoft.Storage.Global"));
    for ([_][]const u8{ "", ".Microsoft", "Microsoft.", "Micro soft", "a\"b" }) |s| try testing.expect(!isService(s));
    for ([_][]const u8{ "*", "Internet", "VirtualNetwork", "Storage.EastUS2", "10.0.0.0/16", "203.0.113.7", "fd00::/8" }) |s| try testing.expect(isAddressPrefix(s));
    for ([_][]const u8{ "", "a b", "**", "a,b", "a\"b" }) |s| try testing.expect(!isAddressPrefix(s));
    for ([_][]const u8{ "*", "0", "22", "65535", "1000-2000", "80-80" }) |s| try testing.expect(isPortRange(s));
    for ([_][]const u8{ "", "65536", "-1", "2000-1000", "80-", "-80", "1-2-3", "08", "ssh" }) |s| try testing.expect(!isPortRange(s));
    try testing.expect(isDescription(""));
    try testing.expect(isDescription(&@as([140]u8, @splat('d'))));
    try testing.expect(!isDescription(&@as([141]u8, @splat('d'))));
    try testing.expect(!isDescription("a\tb"));
    try testing.expect(isDescription("SSH f\xc3\xbcr Ops"));
    try testing.expect(!isDescription("SSH \xff"));
}

test "isNetworkId: the kind's id, in any case, and nothing else" {
    const nsg = "/subscriptions/0f9e8d7c-6b5a-4c3d-8e2f-1a0b9c8d7e6f/resourceGroups/rg/providers/Microsoft.Network/networkSecurityGroups/pb-nsg";
    try testing.expect(isNetworkId(nsg, "networkSecurityGroups"));
    try testing.expect(isNetworkId("/SUBSCRIPTIONS/x/resourcegroups/rg/providers/microsoft.network/networksecuritygroups/n", "networkSecurityGroups"));
    try testing.expect(!isNetworkId(nsg, "natGateways"));
    try testing.expect(!isNetworkId("/subscriptions/x/resourceGroups/rg\xff/providers/Microsoft.Network/networkSecurityGroups/n", "networkSecurityGroups"));
    for ([_][]const u8{ "pb-nsg", "", "/subscriptions/x/resourceGroups/rg/providers/Microsoft.Network/networkSecurityGroups/", "/subscriptions/x/resourceGroups/rg/providers/Microsoft.Network/networkSecurityGroups/a b" }) |s| {
        try testing.expect(!isNetworkId(s, "networkSecurityGroups"));
    }
}
