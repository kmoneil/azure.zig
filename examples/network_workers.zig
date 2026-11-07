const std = @import("std");
const network = @import("network");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const env = init.environ_map;
    // A token from tools/azure-token.sh, or from the Azure CLI:
    // az account get-access-token --query accessToken -o tsv
    // and a resource group of yours, which must exist.
    const text = env.get("AZURE_TOKEN");
    const sub = env.get("AZURE_SUBSCRIPTION");
    const group = env.get("AZURE_GROUP");
    if (text == null or sub == null or group == null) {
        std.debug.print("set AZURE_TOKEN, AZURE_SUBSCRIPTION and AZURE_GROUP\n", .{});
        return;
    }
    var token: network.StaticToken = .{ .token = std.mem.trim(u8, text.?, &std.ascii.whitespace) };
    var diag: network.Diagnostics = .{};
    var client: network.Client = try .init(gpa, init.io, .{
        .token_provider = token.provider(),
        .diagnostics = &diag,
    });
    defer client.deinit();

    // A network with one private subnet, which reaches Storage in its
    // region over a service endpoint.
    var op = client.beginCreateVirtualNetwork(sub.?, group.?, "workers-vnet", .{
        .location = env.get("AZURE_LOCATION") orelse "eastus2",
        .address_prefixes = &.{"10.20.0.0/16"},
        .subnets = &.{.{ .name = "workers", .spec = .{
            .address_prefix = "10.20.1.0/24",
            .service_endpoints = &.{"Microsoft.Storage"},
        } }},
    }) catch |err| {
        std.debug.print("{t}: {f}\n", .{ err, diag });
        return err;
    };
    defer op.deinit();
    client.waitOperation(&op, 5 * 60 * 1000) catch |err| {
        std.debug.print("{t}: {f}\n", .{ err, diag });
        return err;
    };
    if (op.value.state != .succeeded) {
        std.debug.print("{t}: {s}: {s}\n", .{ op.value.state, op.value.failure_code, op.value.failure_message });
        return;
    }

    var subnet = try client.getSubnet(sub.?, group.?, "workers-vnet", "workers");
    defer subnet.deinit();
    // What a VM's network interface names.
    std.debug.print("{s}\n", .{subnet.value.id});
}
