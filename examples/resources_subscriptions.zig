//! The subscriptions a Resource Manager token can see. Until auth lands,
//! the token comes from the environment. docs/resources/README.md shows
//! this file.
//!
//!     AZURE_TOKEN=$(tools/azure-token.sh) zig build example-resources_subscriptions

const std = @import("std");
const resources = @import("resources");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    // A token from tools/azure-token.sh, or from the Azure CLI:
    // az account get-access-token --query accessToken -o tsv
    const text = init.environ_map.get("AZURE_TOKEN") orelse {
        std.debug.print("set AZURE_TOKEN to a Resource Manager token\n", .{});
        return;
    };
    var token: resources.StaticToken = .{ .token = std.mem.trim(u8, text, &std.ascii.whitespace) };
    var diag: resources.Diagnostics = .{};
    var client: resources.Client = try .init(gpa, init.io, .{
        .token_provider = token.provider(),
        .diagnostics = &diag,
    });
    defer client.deinit();

    var subs = client.listSubscriptions() catch |err| {
        std.debug.print("{t}: {f}\n", .{ err, diag });
        return err;
    };
    defer subs.deinit();
    for (subs.value) |s| std.debug.print("{s}  {s}  {t}\n", .{ s.id, s.display_name, s.state });
}
