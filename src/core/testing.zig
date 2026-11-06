//! Fakes and helpers for tests: rest-core's, and ARM's answers, scripted.

const rest_core = @import("rest_core");
const rc = rest_core.testing;
const Header = rest_core.transport.Header;

pub const FakeTransport = rc.FakeTransport;
pub const FakeClock = rc.FakeClock;
pub const FakeTokenProvider = rc.FakeTokenProvider;
pub const FaultTransport = rc.FaultTransport;
pub const ScriptedServer = rc.ScriptedServer;
pub const WipeChecker = rc.WipeChecker;
pub const ByteGen = rc.ByteGen;
pub const FuzzOptions = rc.FuzzOptions;
pub const fuzzBytes = rc.fuzzBytes;
pub const repeat = rc.repeat;

const Reply = FakeTransport.Reply;

/// ARM's error body, `{"error":{"code","message"}}`. Neither may hold a
/// quote or a backslash.
pub fn armError(comptime code: []const u8, comptime message: []const u8) []const u8 {
    return "{\"error\":{\"code\":\"" ++ code ++ "\",\"message\":\"" ++ message ++ "\"}}";
}

/// A refusal as ARM sends one: `status`, ARM's error body, and the two ids
/// ARM's answers carry.
pub fn armRefusal(comptime status: u16, comptime code: []const u8, comptime message: []const u8) Reply {
    return .{ .respond = .{
        .status = status,
        .headers = &.{
            .{ .name = "x-ms-request-id", .value = "11111111-1111-4111-8111-111111111111" },
            .{ .name = "x-ms-correlation-request-id", .value = "22222222-2222-4222-8222-222222222222" },
        },
        .body = armError(code, message),
    } };
}

/// A long-running write as ARM answers one through `Azure-AsyncOperation`:
/// the first answer, `first` (201 or 202) naming `operation_url`, then one
/// poll answer per entry of `statuses`, each `{"status":...}`; every answer
/// asks `Retry-After: retry_after_s`. Call it at compile time.
pub fn asyncOperation(
    comptime first: u16,
    comptime operation_url: []const u8,
    comptime retry_after_s: []const u8,
    comptime statuses: []const []const u8,
) [statuses.len + 1]Reply {
    const retry_after: Header = .{ .name = "Retry-After", .value = retry_after_s };
    var script: [statuses.len + 1]Reply = undefined;
    script[0] = .{ .respond = .{
        .status = first,
        .headers = &.{ .{ .name = "Azure-AsyncOperation", .value = operation_url }, retry_after },
        .body = "",
    } };
    inline for (statuses, 1..) |status, i| {
        script[i] = .{ .respond = .{ .headers = &.{retry_after}, .body = "{\"status\":\"" ++ status ++ "\"}" } };
    }
    return script;
}

test "asyncOperation: the first answer names the operation, then one answer per status" {
    const std = @import("std");
    const script = comptime asyncOperation(202, "https://management.azure.com/op", "3", &.{ "InProgress", "Succeeded" });
    try std.testing.expectEqual(3, script.len);
    try std.testing.expectEqual(202, script[0].respond.status);
    try std.testing.expectEqualStrings("https://management.azure.com/op", script[0].respond.headers[0].value);
    try std.testing.expectEqualStrings("{\"status\":\"Succeeded\"}", script[2].respond.body);
    try std.testing.expectEqualStrings("3", script[2].respond.headers[0].value);
    try std.testing.expectEqualStrings("{\"error\":{\"code\":\"X\",\"message\":\"y\"}}", armError("X", "y"));
}
