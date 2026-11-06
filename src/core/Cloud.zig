//! An Azure cloud: where its sign-in, Resource Manager and Storage live.
//! `public` is Azure itself; the national clouds are separate deployments
//! with hosts of their own.

const Cloud = @This();

/// Entra ID's authority host, with its trailing slash: a token comes from
/// `{authority_host}{tenant}/oauth2/v2.0/token`.
authority_host: []const u8,
/// Resource Manager's base URL, with no trailing slash.
arm_endpoint: []const u8,
/// The scope a token for Resource Manager is asked with: its audience and
/// `/.default`, the double slash intended, as azcore asks.
arm_scope: []const u8,
/// Blob endpoints are `https://{account}.blob.{storage_suffix}`.
storage_suffix: []const u8,

/// Storage's token scope, the same in every cloud.
pub const storage_scope = "https://storage.azure.com/.default";

pub const public: Cloud = .{
    .authority_host = "https://login.microsoftonline.com/",
    .arm_endpoint = "https://management.azure.com",
    .arm_scope = "https://management.core.windows.net//.default",
    .storage_suffix = "core.windows.net",
};

pub const china: Cloud = .{
    .authority_host = "https://login.chinacloudapi.cn/",
    .arm_endpoint = "https://management.chinacloudapi.cn",
    .arm_scope = "https://management.core.chinacloudapi.cn//.default",
    .storage_suffix = "core.chinacloudapi.cn",
};

pub const us_government: Cloud = .{
    .authority_host = "https://login.microsoftonline.us/",
    .arm_endpoint = "https://management.usgovcloudapi.net",
    .arm_scope = "https://management.core.usgovcloudapi.net//.default",
    .storage_suffix = "core.usgovcloudapi.net",
};

test "every cloud: an https authority host ending in a slash, an ARM endpoint with none" {
    const std = @import("std");
    for ([_]Cloud{ public, china, us_government }) |c| {
        try std.testing.expectStringStartsWith(c.authority_host, "https://");
        try std.testing.expectStringEndsWith(c.authority_host, "/");
        try std.testing.expectStringStartsWith(c.arm_endpoint, "https://");
        try std.testing.expect(!std.mem.endsWith(u8, c.arm_endpoint, "/"));
        try std.testing.expectStringEndsWith(c.arm_scope, "//.default");
    }
}
