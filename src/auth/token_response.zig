//! What token endpoints send back. Entra's v2 endpoint answers
//! `{"token_type":"Bearer","expires_in":3599,"ext_expires_in":3599,
//! "access_token":"..."}`, measured on 2026-11-07 (t9's m0); IMDS and App
//! Service send `expires_in` and `expires_on` as strings, and a long-lived
//! token may carry `refresh_in`. Numbers or strings are taken everywhere.
//!
//! A refusal is `{"error","error_description","error_codes","timestamp",
//! "trace_id","correlation_id","error_uri"}`, the description beginning
//! with its AADSTS code and ending with the ids again.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Cache = @import("Cache.zig");

pub const ParseError = error{ InvalidTokenResponse, OutOfMemory };

/// The token and its lifetimes from a success body. `now_s`, in Unix
/// seconds, turns an `expires_on` into a lifetime when there is no
/// `expires_in`. The token may point into `arena`.
pub fn parse(arena: Allocator, body: []const u8, now_s: i64) ParseError!Cache.Fetched {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidTokenResponse,
    };
    if (root != .object) return error.InvalidTokenResponse;
    const o = root.object;
    const token = switch (o.get("access_token") orelse return error.InvalidTokenResponse) {
        .string => |s| s,
        else => return error.InvalidTokenResponse,
    };
    // A token of another type would not work as a bearer token.
    if (o.get("token_type")) |t| switch (t) {
        .string => |s| if (!std.ascii.eqlIgnoreCase(s, "Bearer")) return error.InvalidTokenResponse,
        else => return error.InvalidTokenResponse,
    };
    const expires_in = if (try seconds(o.get("expires_in"))) |s|
        s
    else if (try seconds(o.get("expires_on"))) |on|
        on - now_s
    else
        return error.InvalidTokenResponse;
    return .{ .token = token, .expires_in = expires_in, .refresh_in = try seconds(o.get("refresh_in")) };
}

/// A count of seconds as a JSON number or a string of digits; null when
/// the field is absent or null.
fn seconds(value: ?std.json.Value) error{InvalidTokenResponse}!?i64 {
    const v = value orelse return null;
    return switch (v) {
        .null => null,
        .integer => |n| n,
        .float => |f| if (std.math.isFinite(f) and @abs(f) < 1e15) @intFromFloat(f) else error.InvalidTokenResponse,
        .number_string, .string => |s| std.fmt.parseInt(i64, s, 10) catch error.InvalidTokenResponse,
        else => error.InvalidTokenResponse,
    };
}

/// An Entra refusal, read leniently: any field may be missing.
pub const Refusal = struct {
    /// `invalid_client`, `unauthorized_client`, `invalid_grant`, ...
    code: []const u8 = "",
    /// The description up to the ids Entra repeats after it: it begins
    /// with the AADSTS code, as `AADSTS7000215: Invalid client secret ...`.
    message: []const u8 = "",
    /// The AADSTS numbers.
    codes: []const i64 = &.{},
    trace_id: []const u8 = "",
    correlation_id: []const u8 = "",

    pub fn hasCode(r: Refusal, code: i64) bool {
        return std.mem.indexOfScalar(i64, r.codes, code) != null;
    }
};

/// The refusal in a JSON error body, or null for a body of another shape,
/// as a gateway's page is.
pub fn parseRefusal(arena: Allocator, body: []const u8) Allocator.Error!?Refusal {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (root != .object) return null;
    const o = root.object;
    const code = text(o.get("error")) orelse return null;
    var codes: std.ArrayList(i64) = .empty;
    if (o.get("error_codes")) |list| if (list == .array) for (list.array.items) |c| {
        if (c == .integer) try codes.append(arena, c.integer);
    };
    const description = text(o.get("error_description")) orelse "";
    return .{
        .code = code,
        .message = firstPart(description),
        .codes = codes.items,
        .trace_id = text(o.get("trace_id")) orelse "",
        .correlation_id = text(o.get("correlation_id")) orelse "",
    };
}

fn text(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return if (v == .string) v.string else null;
}

/// The description before the ids Entra repeats, " Trace ID: ...", and
/// before any line break.
fn firstPart(description: []const u8) []const u8 {
    var end = description.len;
    if (std.mem.indexOf(u8, description, " Trace ID:")) |i| end = @min(end, i);
    if (std.mem.indexOfAny(u8, description, "\r\n")) |i| end = @min(end, i);
    return std.mem.trimEnd(u8, description[0..end], " ");
}

const testing = std.testing;

/// Bodies as Entra sent them on 2026-11-07 (t9's m0), the app id replaced.
pub const recorded = struct {
    pub const token = "{\"token_type\":\"Bearer\",\"expires_in\":3599,\"ext_expires_in\":3599,\"access_token\":\"eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiJ9.e30.c2ln\"}";
    pub const bad_secret = "{\"error\":\"invalid_client\",\"error_description\":\"AADSTS7000215: Invalid client secret provided. Ensure the secret being sent in the request is the client secret value, not the client secret ID, for a secret added to app '00000000-0000-4000-8000-00000000a99a'. Trace ID: 519f89dc-fb52-4a06-83f2-a0aa73094200 Correlation ID: 66aa9c7a-670c-4c8b-8672-2619acdc74ca Timestamp: 2026-11-07 15:46:22Z\",\"error_codes\":[7000215],\"timestamp\":\"2026-11-07 15:46:22Z\",\"trace_id\":\"519f89dc-fb52-4a06-83f2-a0aa73094200\",\"correlation_id\":\"66aa9c7a-670c-4c8b-8672-2619acdc74ca\",\"error_uri\":\"https://login.microsoftonline.com/error?code=7000215\"}";
    pub const unknown_app = "{\"error\":\"unauthorized_client\",\"error_description\":\"AADSTS700016: Application with identifier '00000000-0000-4000-8000-0000000000bb' was not found in the directory '00000000-0000-4000-8000-00000000aaaa'. This can happen if the application has not been installed by the administrator of the tenant or consented to by any user in the tenant. You may have sent your authentication request to the wrong tenant. Trace ID: 0b8e7e0b-3c5f-4a2e-8f1d-1f2e3d4c5b6a Correlation ID: 7c6b5a49-3827-4161-9504-a3b2c1d0e9f8 Timestamp: 2026-11-07 15:46:23Z\",\"error_codes\":[700016],\"timestamp\":\"2026-11-07 15:46:23Z\",\"trace_id\":\"0b8e7e0b-3c5f-4a2e-8f1d-1f2e3d4c5b6a\",\"correlation_id\":\"7c6b5a49-3827-4161-9504-a3b2c1d0e9f8\",\"error_uri\":\"https://login.microsoftonline.com/error?code=700016\"}";
    pub const bad_scope = "{\"error\":\"invalid_scope\",\"error_description\":\"AADSTS1002012: The provided value for scope https://management.azure.com/user_impersonation is not valid. Client credential flows must have a scope value with /.default suffixed to the resource identifier (application ID URI). Trace ID: 1d2c3b4a-5968-4776-8594-a3b2c1d0e9f8 Correlation ID: 2e3d4c5b-6a79-4887-9605-b4c3d2e1f0a9 Timestamp: 2026-11-07 15:46:24Z\",\"error_codes\":[1002012],\"timestamp\":\"2026-11-07 15:46:24Z\",\"trace_id\":\"1d2c3b4a-5968-4776-8594-a3b2c1d0e9f8\",\"correlation_id\":\"2e3d4c5b-6a79-4887-9605-b4c3d2e1f0a9\"}";
};

test "a token from Entra's v2 endpoint, as m0 recorded it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try parse(arena.allocator(), recorded.token, 1_794_000_000);
    try testing.expectEqualStrings("eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiJ9.e30.c2ln", got.token);
    try testing.expectEqual(3599, got.expires_in);
    try testing.expectEqual(null, got.refresh_in);
}

test "numbers or strings; expires_on when there is no expires_in; refresh_in when sent" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // IMDS's shape: every number a string.
    const imds = try parse(a, "{\"access_token\":\"t\",\"refresh_token\":\"\",\"expires_in\":\"3599\",\"expires_on\":\"1794003599\",\"not_before\":\"1794000000\",\"resource\":\"https://management.azure.com/\",\"token_type\":\"Bearer\"}", 1_794_000_000);
    try testing.expectEqual(3599, imds.expires_in);
    // App Service's: expires_on alone.
    const app = try parse(a, "{\"access_token\":\"t\",\"expires_on\":\"1794000600\",\"resource\":\"r\",\"token_type\":\"Bearer\",\"client_id\":\"c\"}", 1_794_000_000);
    try testing.expectEqual(600, app.expires_in);
    const long = try parse(a, "{\"access_token\":\"t\",\"expires_in\":86399,\"refresh_in\":\"43199\"}", 0);
    try testing.expectEqual(43199, long.refresh_in.?);
    for ([_][]const u8{
        "",
        "[]",
        "{}",
        "{\"access_token\":\"t\"}",
        "{\"access_token\":5,\"expires_in\":3599}",
        "{\"access_token\":\"t\",\"expires_in\":\"soon\"}",
        "{\"access_token\":\"t\",\"expires_in\":3599,\"token_type\":\"pop\"}",
        "{\"access_token\":\"t\",\"expires_in\":true}",
    }) |bad| {
        errdefer std.debug.print("accepted {s}\n", .{bad});
        try testing.expectError(error.InvalidTokenResponse, parse(a, bad, 0));
    }
}

test "a refusal: its code, the message before the ids, the AADSTS number, both ids" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = (try parseRefusal(arena.allocator(), recorded.bad_secret)).?;
    try testing.expectEqualStrings("invalid_client", r.code);
    try testing.expectStringStartsWith(r.message, "AADSTS7000215: Invalid client secret provided.");
    try testing.expectStringEndsWith(r.message, "for a secret added to app '00000000-0000-4000-8000-00000000a99a'.");
    try testing.expect(r.hasCode(7000215));
    try testing.expectEqualStrings("519f89dc-fb52-4a06-83f2-a0aa73094200", r.trace_id);
    try testing.expectEqualStrings("66aa9c7a-670c-4c8b-8672-2619acdc74ca", r.correlation_id);
    try testing.expectEqual(null, try parseRefusal(arena.allocator(), "<html>502 Bad Gateway</html>"));
    try testing.expectEqual(null, try parseRefusal(arena.allocator(), "{\"no\":\"error\"}"));
    const lines = (try parseRefusal(arena.allocator(), "{\"error\":\"x\",\"error_description\":\"AADSTS1: a\\r\\nTrace ID: b\"}")).?;
    try testing.expectEqualStrings("AADSTS1: a", lines.message);
}
