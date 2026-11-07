//! An app's own sign-in with a client secret: the client credentials grant
//! at Entra's v2 token endpoint. A `TokenProvider` for every module, its
//! tokens cached per scope, so one credential serves Resource Manager and
//! Storage at once. Made with `init`, freed with `deinit`, and safe to
//! share between tasks; the secret is wiped when it is freed.

const ClientSecret = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const transport = core.transport;
const TokenProvider = core.TokenProvider;
const Cache = @import("Cache.zig");
const entra = @import("entra.zig");
const form = @import("form.zig");

gpa: Allocator,
cache: Cache,
exchange: entra.Exchange,
/// Owned, as are the client id and the secret.
token_url: []u8,
client_id: []u8,
secret: []u8,
/// The transport the credential made, when its options named none.
http: ?*transport.HttpTransport,

pub const Options = struct {
    /// The app's tenant: its id, or a domain such as
    /// `contoso.onmicrosoft.com`.
    tenant_id: []const u8,
    /// The app's id (a GUID).
    client_id: []const u8,
    /// The secret's value, not its id.
    secret: []const u8,
    cloud: core.Cloud = .public,
    /// In place of the cloud's authority host, as `https://host/` with its
    /// trailing slash.
    authority_host: ?[]const u8 = null,
    /// Null: a `std.http.Client` transport of the credential's own.
    transport: ?transport.Transport = null,
    /// Details of the latest failed token request.
    diagnostics: ?*core.Diagnostics = null,
    retry: core.RetryPolicy = entra.retry_policy,
    /// How long one attempt may take; 0 removes the limit.
    request_timeout_ms: u32 = 30_000,
    user_agent: []const u8 = "azure.zig",
    cache: Cache.Options = .{},
};

pub const InitError = Allocator.Error || error{
    /// A tenant, client id, secret, authority host or cache option that
    /// cannot work. `Diagnostics` says which.
    InvalidArgument,
};

pub fn init(gpa: Allocator, io: std.Io, options: Options) InitError!ClientSecret {
    const host = options.authority_host orelse options.cloud.authority_host;
    if (try problem(options, host)) |why| return invalid(options.diagnostics, why);
    const cache = Cache.init(gpa, options.cache) catch return invalid(options.diagnostics, "the cache's options cannot work: a margin, delay or lifetime of 0, or a margin as long as the longest life");
    const token_url = try entra.tokenUrl(gpa, host, options.tenant_id);
    errdefer wipeFree(gpa, token_url);
    const client_id = try gpa.dupe(u8, options.client_id);
    errdefer wipeFree(gpa, client_id);
    const secret = try gpa.dupe(u8, options.secret);
    errdefer wipeFree(gpa, secret);
    var http: ?*transport.HttpTransport = null;
    const t = options.transport orelse t: {
        const h = try gpa.create(transport.HttpTransport);
        h.* = .init(gpa, io, options.user_agent);
        http = h;
        break :t h.transport();
    };
    return .{
        .gpa = gpa,
        .cache = cache,
        .exchange = .{
            .transport = t,
            .retry = options.retry,
            .request_timeout_ms = options.request_timeout_ms,
            .diagnostics = options.diagnostics,
        },
        .token_url = token_url,
        .client_id = client_id,
        .secret = secret,
        .http = http,
    };
}

fn problem(options: Options, host: []const u8) Allocator.Error!?[]const u8 {
    if (entra.tenantProblem(options.tenant_id)) |why| return why;
    if (!entra.isGuid(options.client_id)) return "a client id is the app's id, a GUID";
    if (options.secret.len == 0) return "the secret is empty";
    if (!isAuthorityHost(host)) return "an authority host is https://host/, with its trailing slash";
    return null;
}

/// `https://host/`: HTTPS, since the secret goes there, a host, and the
/// one trailing slash the token URL follows.
fn isAuthorityHost(host: []const u8) bool {
    if (!std.mem.startsWith(u8, host, "https://") or !std.mem.endsWith(u8, host, "/")) return false;
    const name = host["https://".len .. host.len - 1];
    if (name.len == 0) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == ':')) return false;
    return true;
}

fn invalid(diagnostics: ?*core.Diagnostics, why: []const u8) error{InvalidArgument} {
    if (diagnostics) |d| d.print("{s}", .{why});
    return error.InvalidArgument;
}

/// Wipes and frees the secret and every token. Nothing may be using the
/// credential.
pub fn deinit(self: *ClientSecret) void {
    self.cache.deinit();
    if (self.http) |h| {
        h.deinit();
        self.gpa.destroy(h);
    }
    wipeFree(self.gpa, self.token_url);
    wipeFree(self.gpa, self.client_id);
    wipeFree(self.gpa, self.secret);
    self.* = undefined;
}

/// The credential as every module takes it. It must outlive every client
/// given it.
pub fn provider(self: *ClientSecret) TokenProvider {
    return .{ .ptr = self, .vtable = &.{ .getToken = getToken, .invalidate = invalidate } };
}

fn getToken(ptr: *anyopaque, io: std.Io, arena: Allocator, scopes: []const []const u8) TokenProvider.Error![]const u8 {
    const self: *ClientSecret = @ptrCast(@alignCast(ptr));
    if (scopes.len != 1 or !entra.isAppScope(scopes[0])) {
        if (self.exchange.diagnostics) |d| d.print("an app asks for one scope at a time, a resource's /.default, such as https://storage.azure.com/.default", .{});
        return error.TokenUnavailable;
    }
    return self.cache.getToken(io, arena, scopes[0], .{ .ptr = self, .fetchFn = fetch });
}

fn invalidate(ptr: *anyopaque) void {
    const self: *ClientSecret = @ptrCast(@alignCast(ptr));
    self.cache.invalidate();
}

/// One token for `scope`. `arena` is the cache's, wiped after: the body
/// holds the secret.
fn fetch(ptr: *anyopaque, io: std.Io, arena: Allocator, scope: []const u8) TokenProvider.Error!Cache.Fetched {
    const self: *ClientSecret = @ptrCast(@alignCast(ptr));
    const body = try form.encode(arena, &.{
        .{ .name = "grant_type", .value = "client_credentials" },
        .{ .name = "client_id", .value = self.client_id },
        .{ .name = "client_secret", .value = self.secret },
        .{ .name = "scope", .value = scope },
    });
    return entra.post(self.exchange, io, arena, self.token_url, body);
}

fn wipeFree(gpa: Allocator, bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
    gpa.rawFree(bytes, .fromByteUnits(@alignOf(u8)), @returnAddress());
}

test "authority hosts" {
    const testing = std.testing;
    for ([_][]const u8{ "https://login.microsoftonline.com/", "https://login.chinacloudapi.cn/", "https://127.0.0.1:8443/" }) |ok| try testing.expect(isAuthorityHost(ok));
    for ([_][]const u8{ "http://login.microsoftonline.com/", "https://login.microsoftonline.com", "https:///", "https://a/b/", "https://u@a/" }) |bad| try testing.expect(!isAuthorityHost(bad));
}
