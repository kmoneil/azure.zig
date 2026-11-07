const std = @import("std");
const auth = @import("auth");
const resources = @import("resources");

pub fn main(init: std.process.Init) !void {
    const env = init.environ_map;
    var diag: auth.Diagnostics = .{};

    // An app's own sign-in when AZURE_TENANT_ID, AZURE_CLIENT_ID and
    // AZURE_CLIENT_SECRET are set; else the Azure CLI's (az login).
    var cli: auth.AzureCli = try .init(init.gpa, .{ .diagnostics = &diag });
    defer cli.deinit();
    var secret: ?auth.ClientSecret = null;
    defer if (secret) |*s| s.deinit();
    if (env.get("AZURE_CLIENT_SECRET")) |value| {
        secret = auth.ClientSecret.init(init.gpa, init.io, .{
            .tenant_id = env.get("AZURE_TENANT_ID") orelse "",
            .client_id = env.get("AZURE_CLIENT_ID") orelse "",
            .secret = value,
            .diagnostics = &diag,
        }) catch |err| {
            std.debug.print("{t}: {f}\n", .{ err, diag });
            return err;
        };
    }
    const provider = if (secret) |*s| s.provider() else cli.provider();

    // One credential serves every client; each asks its own scope.
    var client: resources.Client = try .init(init.gpa, init.io, .{
        .token_provider = provider,
        .diagnostics = &diag,
    });
    defer client.deinit();
    var subscriptions = client.listSubscriptions() catch |err| {
        std.debug.print("{t}: {f}\n", .{ err, diag });
        return err;
    };
    defer subscriptions.deinit();
    for (subscriptions.value) |s| std.debug.print("{s}  {s}\n", .{ s.id, s.display_name });
}
