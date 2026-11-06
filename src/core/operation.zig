//! Long-running ARM operations. A write that ARM cannot finish within its
//! answer says 201 or 202 and carries on; `begin` sends the write and says
//! how to follow it, `poll` asks once how it stands, `wait` polls until it
//! ends or a time limit passes, and `result` reads what it made.
//!
//! How an answer is followed, by ARM's rules as azcore applies them:
//!
//! - `Azure-AsyncOperation`, else `Operation-Location`: GET it until its
//!   body's `status` is terminal; a failed or canceled one carries `error`.
//! - Else `Location`: GET it; 202 is still running, any other 2xx is done,
//!   its body the result, and a new `Location` is followed.
//! - Else, for a PUT or PATCH: GET the resource until its
//!   `properties.provisioningState` is terminal; a 204 is done.
//! - A DELETE or POST answered 202 with none of them cannot be followed.
//!
//! Each poll waits what the previous answer's `Retry-After` asked, or
//! `Options.default_delay_ms`. Every URL ARM gives is followed only on the
//! engine's own origin, so the bearer token never goes elsewhere.
//!
//! Each function takes an `arm.Engine` (any log scope) and an arena that
//! holds the `Operation`'s strings for as long as it is used.

const std = @import("std");
const Allocator = std.mem.Allocator;
const rest_core = @import("rest_core");
const transport = rest_core.transport;
const arm = @import("arm.zig");

pub const State = arm.OperationState;

/// Where a POST's result is read once it succeeds, as its API's
/// `final-state-via` says.
pub const FinalStateVia = enum { location, original_uri, azure_async_operation };

pub const Options = struct {
    /// The wait before the next poll when an answer asks for none: ARM's
    /// 30 seconds.
    default_delay_ms: u32 = 30_000,
    /// The least wait between polls, whatever an answer asks.
    min_delay_ms: u32 = 1_000,
    final_state_via: FinalStateVia = .location,
};

pub const Operation = struct {
    /// The call that began it.
    method: transport.Method,
    /// The path the call named: what a PUT or PATCH reads again when done.
    resource_path: []const u8,
    follow: Follow,
    /// What is polled, a path on the engine's origin.
    poll_path: []const u8,
    /// The first answer's `Location`, where a POST's result is read.
    location_path: ?[]const u8 = null,
    options: Options,
    state: State = .running,
    /// How long to wait before the next poll, as the latest answer asked.
    delay_ms: u32,
    /// The body of the answer that ended it: the operation's own, the
    /// `Location`'s, or the resource's.
    final_body: []const u8 = "",
    /// A failed or canceled operation's `error`, as its body gave it.
    failure_code: []const u8 = "",
    failure_message: []const u8 = "",

    pub const Follow = enum {
        /// `Azure-AsyncOperation` or `Operation-Location`: the body's `status`.
        async_operation,
        /// `Location`: the answer's status.
        location,
        /// The resource itself: `properties.provisioningState`.
        provisioning_state,
    };
};

/// What these functions return: the engine's own errors, and
/// `InvalidOperation` for an answer that cannot be followed or read, with
/// `Diagnostics` saying which.
pub fn Error(comptime Engine: type) type {
    return Engine.StreamCallError || error{InvalidOperation};
}

/// Sends `call`, a PUT, PATCH, DELETE or POST, and returns how it stands:
/// running and how to follow it, or already ended.
pub fn begin(engine: anytype, arena: Allocator, call: rest_core.loop.StreamCall, options: Options) Error(@TypeOf(engine))!Operation {
    var response: std.heap.ArenaAllocator = .init(engine.gpa);
    defer response.deinit();
    const res = try engine.executeStream(&response, call);
    var op: Operation = .{
        .method = call.method,
        .resource_path = try arena.dupe(u8, call.path),
        .follow = .provisioning_state,
        .poll_path = "",
        .options = options,
        .delay_ms = delayMs(engine.io, res.headers, options),
    };
    if (res.header("location")) |url| op.location_path = try originPath(engine, arena, url);
    if (arm.pollOf(res.headers)) |poll_at| {
        op.follow = switch (poll_at.kind) {
            .async_operation, .operation_location => .async_operation,
            .location => .location,
        };
        op.poll_path = try originPath(engine, arena, poll_at.url);
        return op;
    }
    switch (call.method) {
        .PUT, .PATCH => {
            op.poll_path = op.resource_path;
            if (res.status != 201 and res.status != 202) try readProvisioning(engine, arena, &op, res);
        },
        else => {
            if (res.status == 202) return invalid(engine, "the answer was 202 with no URL to poll");
            op.state = .succeeded;
            op.final_body = try arena.dupe(u8, res.body);
        },
    }
    return op;
}

/// Asks once how a running operation stands, and records it in `op`.
pub fn poll(engine: anytype, arena: Allocator, op: *Operation) Error(@TypeOf(engine))!void {
    std.debug.assert(op.state == .running);
    var response: std.heap.ArenaAllocator = .init(engine.gpa);
    defer response.deinit();
    const res = try engine.executeStream(&response, .{ .method = .GET, .path = op.poll_path });
    op.delay_ms = delayMs(engine.io, res.headers, op.options);
    switch (op.follow) {
        .async_operation => try readStatus(engine, arena, op, res.body),
        .location => try readLocation(engine, arena, op, res),
        .provisioning_state => try readProvisioning(engine, arena, op, res),
    }
}

/// Polls `op`, waiting what each answer asks, until it ends or
/// `timeout_ms` has passed, and leaves it as it then stands: ended or
/// still running. A failed operation is an answer, not an error.
pub fn wait(engine: anytype, arena: Allocator, op: *Operation, timeout_ms: u32) Error(@TypeOf(engine))!void {
    const clock: std.Io.Clock = .awake;
    const deadline = clock.now(engine.io).addDuration(.fromMilliseconds(timeout_ms));
    while (op.state == .running) {
        const left = clock.now(engine.io).durationTo(deadline).toMilliseconds();
        if (left <= 0) return;
        try engine.io.sleep(.fromMilliseconds(@min(op.delay_ms, @as(u64, @intCast(left)))), .awake);
        try poll(engine, arena, op);
    }
}

/// What a succeeded operation made, in `arena`: a PUT's or PATCH's
/// resource as it now is, a POST's result where `final_state_via` says,
/// and nothing for a DELETE.
pub fn result(engine: anytype, arena: Allocator, op: *const Operation) Error(@TypeOf(engine))!?[]const u8 {
    std.debug.assert(op.state == .succeeded);
    return switch (op.method) {
        .DELETE => null,
        .PUT, .PATCH => if (op.follow == .provisioning_state) op.final_body else try get(engine, arena, op.resource_path),
        .POST => switch (op.options.final_state_via) {
            .location => if (op.follow != .location and op.location_path != null) try get(engine, arena, op.location_path.?) else op.final_body,
            .original_uri => try get(engine, arena, op.resource_path),
            .azure_async_operation => op.final_body,
        },
        .GET, .HEAD => op.final_body,
    };
}

fn get(engine: anytype, arena: Allocator, path: []const u8) Error(@TypeOf(engine))![]const u8 {
    var response: std.heap.ArenaAllocator = .init(engine.gpa);
    defer response.deinit();
    return arena.dupe(u8, try engine.execute(&response, .{ .method = .GET, .path = path }));
}

/// An `Azure-AsyncOperation` or `Operation-Location` answer:
/// `{"status", "error": {"code", "message"}}`.
fn readStatus(engine: anytype, arena: Allocator, op: *Operation, body: []const u8) Error(@TypeOf(engine))!void {
    const Status = struct {
        status: ?[]const u8 = null,
        @"error": ?struct { code: ?[]const u8 = null, message: ?[]const u8 = null } = null,
    };
    const parsed = std.json.parseFromSliceLeaky(Status, arena, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return invalid(engine, "an operation's status is not JSON of the shape ARM sends"),
    };
    const status = parsed.status orelse return invalid(engine, "an operation's answer has no status");
    op.state = arm.operationState(status);
    if (op.state == .running) return;
    op.final_body = try arena.dupe(u8, body);
    if (parsed.@"error") |e| {
        op.failure_code = e.code orelse "";
        op.failure_message = e.message orelse "";
    }
}

/// A `Location` answer: 202 while running, with perhaps a new `Location`;
/// any other 2xx is done, and its body the result.
fn readLocation(engine: anytype, arena: Allocator, op: *Operation, res: transport.StreamResponse) Error(@TypeOf(engine))!void {
    if (res.status == 202) {
        if (res.header("location")) |url| op.poll_path = try originPath(engine, arena, url);
        return;
    }
    op.state = .succeeded;
    op.final_body = try arena.dupe(u8, res.body);
}

/// The resource itself: `properties.provisioningState`, where none (or a
/// 204) means done.
fn readProvisioning(engine: anytype, arena: Allocator, op: *Operation, res: transport.StreamResponse) Error(@TypeOf(engine))!void {
    const Resource = struct {
        properties: ?struct { provisioningState: ?[]const u8 = null } = null,
    };
    var state: State = .succeeded;
    if (res.status != 204) {
        const parsed = std.json.parseFromSliceLeaky(Resource, arena, res.body, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return invalid(engine, "a resource's body is not JSON of the shape ARM sends"),
        };
        if (parsed.properties) |p| if (p.provisioningState) |s| {
            state = arm.operationState(s);
        };
    }
    op.state = state;
    if (state != .running) op.final_body = try arena.dupe(u8, res.body);
}

/// `url` as a path on the engine's origin, copied into `arena`; a URL
/// elsewhere is refused, so the token never follows it.
fn originPath(engine: anytype, arena: Allocator, url: []const u8) Error(@TypeOf(engine))![]const u8 {
    const path = @import("origin.zig").pathOnOrigin(engine.base_url, url) orelse {
        if (engine.diagnostics) |d| d.print("an operation's URL is not on {s}", .{engine.base_url});
        return error.InvalidEndpoint;
    };
    return arena.dupe(u8, path);
}

/// The wait an answer asks before the next poll, within the options' bounds.
fn delayMs(io: std.Io, headers: []const transport.Header, options: Options) u32 {
    const asked = rest_core.retry_after.serverDelayMs(transport.Header, headers, std.Io.Clock.real.now(io));
    return @max(asked orelse options.default_delay_ms, options.min_delay_ms);
}

fn invalid(engine: anytype, comptime why: []const u8) error{InvalidOperation} {
    if (engine.diagnostics) |d| d.print(why, .{});
    return error.InvalidOperation;
}

test {
    _ = @import("operation_test.zig");
}
