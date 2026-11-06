//! What the client checks before it sends. Each name goes into an ARM path
//! or query, so a check here is what keeps a caller's string from naming
//! another resource (`..`, a `/`, a `?`) or breaking the request.

const std = @import("std");

/// A subscription id: a GUID, `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`.
pub fn isSubscription(text: []const u8) bool {
    if (text.len != 36) return false;
    for (text, 0..) |c, i| {
        const dash = i == 8 or i == 13 or i == 18 or i == 23;
        if (dash != (c == '-')) return false;
        if (!dash and !std.ascii.isHex(c)) return false;
    }
    return true;
}

/// A resource group's name: 1 to 90 of letters, digits, `-`, `_`, `.`, `(`
/// and `)`, not ending in `.`. ARM also takes letters outside ASCII; this
/// client does not.
pub fn isGroupName(text: []const u8) bool {
    if (text.len == 0 or text.len > 90 or text[text.len - 1] == '.') return false;
    for (text) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "-_.()", c) == null) return false;
    return true;
}

/// A resource provider's namespace, such as `Microsoft.Compute`.
pub fn isNamespace(text: []const u8) bool {
    if (text.len == 0 or text.len > 128 or text[0] == '.' or text[text.len - 1] == '.') return false;
    for (text) |c| if (!std.ascii.isAlphanumeric(c) and c != '.') return false;
    return true;
}

/// A location's name, such as `eastus2`.
pub fn isLocation(text: []const u8) bool {
    if (text.len == 0 or text.len > 64) return false;
    for (text) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    return true;
}

/// A tag's name: 1 to 512 bytes, none of `<>%&\?/` and no control bytes.
pub fn isTagName(text: []const u8) bool {
    if (text.len == 0 or text.len > 512) return false;
    for (text) |c| if (c < 0x20 or c == 0x7f or std.mem.indexOfScalar(u8, "<>%&\\?/", c) != null) return false;
    return true;
}

/// A tag's value: up to 256 bytes, no control bytes.
pub fn isTagValue(text: []const u8) bool {
    if (text.len > 256) return false;
    for (text) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

const testing = std.testing;

test "isSubscription: a GUID and nothing else" {
    try testing.expect(isSubscription("0f9e8d7c-6b5a-4c3d-8e2f-1a0b9c8d7e6f"));
    try testing.expect(isSubscription("0F9E8D7C-6B5A-4C3D-8E2F-1A0B9C8D7E6F"));
    for ([_][]const u8{ "", "0f9e8d7c6b5a4c3d8e2f1a0b9c8d7e6f", "0f9e8d7c-6b5a-4c3d-8e2f-1a0b9c8d7e6", "0f9e8d7c-6b5a-4c3d-8e2f-1a0b9c8d7e6g", "../../../providers/x/y/z/w/v/u/t/s/r" }) |s| {
        try testing.expect(!isSubscription(s));
    }
}

test "isGroupName: ARM's characters, no trailing dot, so no dot segment" {
    for ([_][]const u8{ "rg-1", "azzig-resources-1762466400", "My_Group.(1)", "a", &@as([90]u8, @splat('x')) }) |s| try testing.expect(isGroupName(s));
    for ([_][]const u8{ "", ".", "..", "rg.", "a/b", "a?b", "a b", "a%2fb", &@as([91]u8, @splat('x')), "gr\xc3\xbcn" }) |s| try testing.expect(!isGroupName(s));
}

test "isNamespace, isLocation, isTagName, isTagValue" {
    try testing.expect(isNamespace("Microsoft.Compute"));
    for ([_][]const u8{ "", ".Microsoft", "Microsoft.", "Micro/soft", "a b" }) |s| try testing.expect(!isNamespace(s));
    try testing.expect(isLocation("eastus2"));
    for ([_][]const u8{ "", "east us", "east/us" }) |s| try testing.expect(!isLocation(s));
    try testing.expect(isTagName("azzig-run"));
    for ([_][]const u8{ "", "a/b", "a?b", "a%b", "a\nb" }) |s| try testing.expect(!isTagName(s));
    try testing.expect(isTagValue(""));
    try testing.expect(isTagValue("2026-11-06T22:00:00Z"));
    try testing.expect(!isTagValue("a\nb"));
    try testing.expect(!isTagValue(&@as([257]u8, @splat('x'))));
}
