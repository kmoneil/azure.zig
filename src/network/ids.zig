//! The ARM ids of Microsoft.Network resources, written from their names:
//! what one resource's spec names another by (`SubnetSpec.security_group`,
//! `SubnetSpec.nat_gateway`), and what a VM's network interface names its
//! subnet by, known before the resource is read. Each is allocated with
//! `gpa` and the caller's to free. The names are written as given: the
//! client checks them where it sends them.

const std = @import("std");
const Allocator = std.mem.Allocator;

const prefix = "/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.Network/";

pub fn virtualNetwork(gpa: Allocator, subscription: []const u8, group: []const u8, name: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, prefix ++ "virtualNetworks/{s}", .{ subscription, group, name });
}

pub fn subnet(gpa: Allocator, subscription: []const u8, group: []const u8, network: []const u8, name: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, prefix ++ "virtualNetworks/{s}/subnets/{s}", .{ subscription, group, network, name });
}

pub fn securityGroup(gpa: Allocator, subscription: []const u8, group: []const u8, name: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, prefix ++ "networkSecurityGroups/{s}", .{ subscription, group, name });
}

pub fn natGateway(gpa: Allocator, subscription: []const u8, group: []const u8, name: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, prefix ++ "natGateways/{s}", .{ subscription, group, name });
}

test "ids: the shapes ARM writes" {
    const gpa = std.testing.allocator;
    const sub = "0f9e8d7c-6b5a-4c3d-8e2f-1a0b9c8d7e6f";
    const s = try subnet(gpa, sub, "rg", "pb-vnet", "workers");
    defer gpa.free(s);
    try std.testing.expectEqualStrings("/subscriptions/" ++ sub ++ "/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/pb-vnet/subnets/workers", s);
    const n = try securityGroup(gpa, sub, "rg", "pb-nsg");
    defer gpa.free(n);
    try std.testing.expectEqualStrings("/subscriptions/" ++ sub ++ "/resourceGroups/rg/providers/Microsoft.Network/networkSecurityGroups/pb-nsg", n);
    const v = try virtualNetwork(gpa, sub, "rg", "pb-vnet");
    defer gpa.free(v);
    try std.testing.expectStringEndsWith(v, "/virtualNetworks/pb-vnet");
    const g = try natGateway(gpa, sub, "rg", "pb-nat");
    defer gpa.free(g);
    try std.testing.expectStringEndsWith(g, "/natGateways/pb-nat");
}
