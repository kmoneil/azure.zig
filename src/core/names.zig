//! Resource Manager's naming rules that every ARM module checks before it
//! sends. Each name goes into an ARM path or query, so a check here is what
//! keeps a caller's string from naming another resource (`..`, a `/`, a
//! `?`) or breaking the request.

const std = @import("std");
const arm = @import("arm.zig");

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
/// library does not.
pub fn isGroupName(text: []const u8) bool {
    if (text.len == 0 or text.len > 90 or text[text.len - 1] == '.') return false;
    for (text) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "-_.()", c) == null) return false;
    return true;
}

/// A location's name, such as `eastus2`.
pub fn isLocation(text: []const u8) bool {
    if (text.len == 0 or text.len > 64) return false;
    for (text) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    return true;
}

/// A tag's name: 1 to 512 bytes of valid UTF-8, none of `<>%&\?/` and no
/// control bytes. A tag goes into a JSON body, which is UTF-8.
pub fn isTagName(text: []const u8) bool {
    if (text.len == 0 or text.len > 512 or !std.unicode.utf8ValidateSlice(text)) return false;
    for (text) |c| if (c < 0x20 or c == 0x7f or std.mem.indexOfScalar(u8, "<>%&\\?/", c) != null) return false;
    return true;
}

/// A tag's value: up to 256 bytes of valid UTF-8, no control bytes.
pub fn isTagValue(text: []const u8) bool {
    if (text.len > 256 or !std.unicode.utf8ValidateSlice(text)) return false;
    for (text) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

/// Why a subscription and group would be refused, or null when ARM would
/// take both.
pub fn groupProblem(subscription: []const u8, group: []const u8) ?[]const u8 {
    if (!isSubscription(subscription)) return "a subscription id is a GUID";
    if (!isGroupName(group)) return "a resource group's name is 1 to 90 of letters, digits and -_.(), not ending in '.'";
    return null;
}

/// Why a resource's tags would be refused, or null when ARM would take
/// them: each name and value as above, and no two names alike, since ARM's
/// tag names ignore case.
pub fn tagsProblem(tags: []const arm.Tag) ?[]const u8 {
    for (tags, 0..) |t, i| {
        if (!isTagName(t.name)) return "a tag name is 1 to 512 bytes of UTF-8, none of <>%&\\?/";
        if (!isTagValue(t.value)) return "a tag value is up to 256 bytes of UTF-8, no control bytes";
        for (tags[0..i]) |earlier| {
            if (std.ascii.eqlIgnoreCase(earlier.name, t.name)) return "two tags named alike: ARM's tag names ignore case";
        }
    }
    return null;
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

test "isLocation, isTagName, isTagValue" {
    try testing.expect(isLocation("eastus2"));
    for ([_][]const u8{ "", "east us", "east/us" }) |s| try testing.expect(!isLocation(s));
    try testing.expect(isTagName("azzig-run"));
    try testing.expect(isTagName("gr\xc3\xbcn"));
    for ([_][]const u8{ "", "a/b", "a?b", "a%b", "a\nb", "a\xff", "gr\xc3" }) |s| try testing.expect(!isTagName(s));
    try testing.expect(isTagValue(""));
    try testing.expect(isTagValue("2026-11-06T22:00:00Z"));
    try testing.expect(isTagValue("gr\xc3\xbcn"));
    try testing.expect(!isTagValue("a\nb"));
    // Not UTF-8, which a JSON body must be: a stray byte, a cut sequence.
    try testing.expect(!isTagValue("\xff"));
    try testing.expect(!isTagValue("gr\xc3"));
    try testing.expect(!isTagValue(&@as([257]u8, @splat('x'))));
}

test "groupProblem and tagsProblem: null when ARM would take them, else why" {
    try testing.expectEqual(null, groupProblem("0f9e8d7c-6b5a-4c3d-8e2f-1a0b9c8d7e6f", "rg-1"));
    try testing.expectEqualStrings("a subscription id is a GUID", groupProblem("x", "rg-1").?);
    try testing.expectStringStartsWith(groupProblem("0f9e8d7c-6b5a-4c3d-8e2f-1a0b9c8d7e6f", "..").?, "a resource group's name");
    try testing.expectEqual(null, tagsProblem(&.{ .{ .name = "a", .value = "1" }, .{ .name = "b", .value = "" } }));
    try testing.expectStringStartsWith(tagsProblem(&.{.{ .name = "a/b", .value = "1" }}).?, "a tag name");
    try testing.expectStringStartsWith(tagsProblem(&.{.{ .name = "a", .value = "1\n" }}).?, "a tag value");
    try testing.expectStringStartsWith(tagsProblem(&.{ .{ .name = "Run", .value = "1" }, .{ .name = "run", .value = "2" } }).?, "two tags named alike");
}
