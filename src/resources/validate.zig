//! What the client checks before it sends. Each name goes into an ARM path
//! or query, so a check here is what keeps a caller's string from naming
//! another resource (`..`, a `/`, a `?`) or breaking the request. ARM's
//! common rules are core's (`core.names`), which every ARM module shares;
//! the provider namespace is this module's own.

const std = @import("std");
const names = @import("core").names;

/// A subscription id: a GUID, `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`.
pub const isSubscription = names.isSubscription;
/// A resource group's name: 1 to 90 of letters, digits, `-`, `_`, `.`, `(`
/// and `)`, not ending in `.`.
pub const isGroupName = names.isGroupName;
/// A location's name, such as `eastus2`.
pub const isLocation = names.isLocation;
/// A tag's name: 1 to 512 bytes, none of `<>%&\?/` and no control bytes.
pub const isTagName = names.isTagName;
/// A tag's value: up to 256 bytes, no control bytes.
pub const isTagValue = names.isTagValue;

/// A resource provider's namespace, such as `Microsoft.Compute`.
pub fn isNamespace(text: []const u8) bool {
    if (text.len == 0 or text.len > 128 or text[0] == '.' or text[text.len - 1] == '.') return false;
    for (text) |c| if (!std.ascii.isAlphanumeric(c) and c != '.') return false;
    return true;
}

test "isNamespace" {
    const testing = std.testing;
    try testing.expect(isNamespace("Microsoft.Compute"));
    for ([_][]const u8{ "", ".Microsoft", "Microsoft.", "Micro/soft", "a b" }) |s| try testing.expect(!isNamespace(s));
}
