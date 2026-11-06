//! What every live suite shares: the names and tags of what a run makes,
//! and the sweep that deletes what a crashed run left.
//!
//! A run makes resource groups named `azzig-<suite>-<run>`, tagged
//! `azzig-run` with its run and `azzig-created` with the Unix time it made
//! them, and deletes them as it ends. A run that crashed leaves its groups;
//! the next run of any suite deletes each one over a day old, which no run
//! still going can own.

const std = @import("std");
const resources = @import("resources");

pub const run_tag = "azzig-run";
pub const created_tag = "azzig-created";
pub const prefix = "azzig-";
pub const max_age_s = 24 * 60 * 60;

/// A run's id: eight hex digits, random.
pub fn runId(io: std.Io) [8]u8 {
    var bytes: [4]u8 = undefined;
    io.random(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

/// Begins deleting every `azzig-` group with an `azzig-created` tag more
/// than a day old, waiting for none of them, and returns how many.
pub fn sweep(client: *resources.Client, subscription: []const u8, now_s: i64) !usize {
    var groups = try client.listResourceGroups(subscription, .{ .name = created_tag });
    defer groups.deinit();
    var begun: usize = 0;
    for (groups.value) |g| {
        if (!std.mem.startsWith(u8, g.name, prefix)) continue;
        if (std.ascii.eqlIgnoreCase(g.provisioning_state, "Deleting")) continue;
        const created = std.fmt.parseInt(i64, g.tag(created_tag) orelse continue, 10) catch continue;
        if (now_s - created < max_age_s) continue;
        var op = client.beginDeleteResourceGroup(subscription, g.name, .{ .force_vms = true }) catch |err| switch (err) {
            error.NotFound => continue,
            else => |e| return e,
        };
        op.deinit();
        begun += 1;
    }
    return begun;
}
