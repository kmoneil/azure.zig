//! operation's tests: every way ARM says to follow a write, through the
//! loop, against a fake ARM and a fake clock.

const std = @import("std");
const testing = std.testing;
const rest_core = @import("rest_core");
const core_testing = @import("testing.zig");
const FakeTransport = core_testing.FakeTransport;
const Reply = FakeTransport.Reply;
const arm = @import("arm.zig");
const operation = @import("operation.zig");
const Cloud = @import("Cloud.zig");

const Engine = arm.Engine(.azure_core_test);

const vm_path = "/subscriptions/s-1/resourceGroups/rg-1/providers/Microsoft.Compute/virtualMachines/vm-1?api-version=2024-07-01";
const op_path = "/subscriptions/s-1/providers/Microsoft.Compute/locations/eastus2/operations/op-1?api-version=2024-07-01";
const op_url = "https://management.azure.com" ++ op_path;
const rg_path = "/subscriptions/s-1/resourcegroups/rg-1?api-version=2021-04-01";
const result_url = "https://management.azure.com/subscriptions/s-1/operationresults/r-1?api-version=2021-04-01";

const Rig = struct {
    fake: FakeTransport,
    clock: core_testing.FakeClock = .{},
    token: core_testing.FakeTokenProvider = .{},
    diag: rest_core.Diagnostics = .{},
    arena: std.heap.ArenaAllocator,

    fn init(script: []const Reply) Rig {
        return .{ .fake = .init(testing.allocator, script), .arena = .init(testing.allocator) };
    }

    fn deinit(rig: *Rig) void {
        rig.fake.deinit();
        rig.arena.deinit();
    }

    fn engine(rig: *Rig) Engine {
        return .{
            .gpa = testing.allocator,
            .io = rig.clock.io(),
            .transport = rig.fake.transport(),
            .base_url = Cloud.public.arm_endpoint,
            .auth_scope = Cloud.public.arm_scope,
            .token_provider = rig.token.provider(),
            .diagnostics = &rig.diag,
            .headers = &arm.engine_headers,
            .retry = arm.retry_policy,
        };
    }

    fn begin(rig: *Rig, call: rest_core.loop.StreamCall, options: operation.Options) !operation.Operation {
        return operation.begin(rig.engine(), rig.arena.allocator(), call, options);
    }
};

const create_vm: rest_core.loop.StreamCall = .{
    .method = .PUT,
    .path = vm_path,
    .content_type = "application/json",
    .body = .{ .segments = &.{"{\"location\":\"eastus2\"}"} },
};

const vm_body = "{\"name\":\"vm-1\",\"properties\":{\"provisioningState\":\"Succeeded\"}}";

test "operation: a PUT followed through Azure-AsyncOperation to its end, then read again" {
    const script = comptime core_testing.asyncOperation(201, op_url, "5", &.{ "InProgress", "Succeeded" }) ++
        [_]Reply{.{ .respond = .{ .body = vm_body } }};
    var rig: Rig = .init(&script);
    defer rig.deinit();
    const a = rig.arena.allocator();

    var op = try rig.begin(create_vm, .{});
    try testing.expectEqual(.async_operation, op.follow);
    try testing.expectEqual(.running, op.state);
    try testing.expectEqualStrings(op_path, op.poll_path);
    try testing.expectEqual(5_000, op.delay_ms);

    try operation.wait(rig.engine(), a, &op, 600_000);
    try testing.expectEqual(.succeeded, op.state);
    try testing.expectEqual(2, rig.clock.sleep_count);
    try testing.expectEqual(5_000, rig.clock.sleepMs(1));
    try testing.expectEqualStrings(vm_body, (try operation.result(rig.engine(), a, &op)).?);
    try testing.expectEqualStrings("https://management.azure.com" ++ vm_path, (try rig.fake.request(0)).url);
}

test "operation: a failed operation is an answer, with the error its body carried" {
    const script = comptime core_testing.asyncOperation(201, op_url, "1", &.{"InProgress"}) ++ [_]Reply{.{ .respond = .{
        .body = "{\"status\":\"Failed\",\"error\":{\"code\":\"AllocationFailed\",\"message\":\"Allocation failed. We do not have sufficient capacity.\"}}",
    } }};
    var rig: Rig = .init(&script);
    defer rig.deinit();

    var op = try rig.begin(create_vm, .{});
    try operation.wait(rig.engine(), rig.arena.allocator(), &op, 600_000);
    try testing.expectEqual(.failed, op.state);
    try testing.expectEqualStrings("AllocationFailed", op.failure_code);
    try testing.expectStringStartsWith(op.failure_message, "Allocation failed.");
}

test "operation: a PUT with no URL to poll is followed on its provisioningState" {
    const script = [_]Reply{
        .{ .respond = .{ .status = 201, .body = "{\"name\":\"vm-1\",\"properties\":{\"provisioningState\":\"Creating\"}}" } },
        .{ .respond = .{ .body = "{\"name\":\"vm-1\",\"properties\":{\"provisioningState\":\"Creating\"}}" } },
        .{ .respond = .{ .body = vm_body } },
    };
    var rig: Rig = .init(&script);
    defer rig.deinit();
    const a = rig.arena.allocator();

    var op = try rig.begin(create_vm, .{ .default_delay_ms = 2_000 });
    try testing.expectEqual(.provisioning_state, op.follow);
    try testing.expectEqualStrings(vm_path, op.poll_path);
    try operation.wait(rig.engine(), a, &op, 600_000);
    try testing.expectEqual(.succeeded, op.state);
    try testing.expectEqual(2_000, rig.clock.sleepMs(0));
    // The last poll was the resource itself: nothing more to read.
    try testing.expectEqualStrings(vm_body, (try operation.result(rig.engine(), a, &op)).?);
    try testing.expectEqual(3, rig.fake.stream_requests.items.len);
    try testing.expectEqual(0, rig.fake.requests.items.len);
}

test "operation: a PUT that finished in its answer is done at once" {
    const script = [_]Reply{
        .{ .respond = .{ .body = vm_body } },
        .{ .respond = .{ .body = "{\"name\":\"rg-1\",\"location\":\"eastus2\"}" } },
    };
    var rig: Rig = .init(&script);
    defer rig.deinit();

    const op = try rig.begin(create_vm, .{});
    try testing.expectEqual(.succeeded, op.state);
    try testing.expectEqualStrings(vm_body, (try operation.result(rig.engine(), rig.arena.allocator(), &op)).?);
    // A resource with no provisioningState, as a resource group is, is done too.
    const group = try rig.begin(.{ .method = .PUT, .path = rg_path }, .{});
    try testing.expectEqual(.succeeded, group.state);
    try testing.expectEqual(2, rig.fake.stream_requests.items.len);
}

test "operation: a DELETE followed through Location: 202 running, 204 done, nothing to read" {
    const script = [_]Reply{
        .{ .respond = .{ .status = 202, .headers = &.{ .{ .name = "Location", .value = result_url }, .{ .name = "Retry-After", .value = "15" } }, .body = "" } },
        .{ .respond = .{ .status = 202, .headers = &.{.{ .name = "Retry-After", .value = "15" }}, .body = "" } },
        .{ .respond = .{ .status = 204, .body = "" } },
    };
    var rig: Rig = .init(&script);
    defer rig.deinit();
    const a = rig.arena.allocator();

    var op = try rig.begin(.{ .method = .DELETE, .path = rg_path }, .{});
    try testing.expectEqual(.location, op.follow);
    try operation.wait(rig.engine(), a, &op, 600_000);
    try testing.expectEqual(.succeeded, op.state);
    try testing.expectEqual(15_000, rig.clock.sleepMs(1));
    try testing.expectEqual(null, try operation.result(rig.engine(), a, &op));
}

test "operation: a Location poll that names a new Location is followed there" {
    const next_url = "https://management.azure.com/subscriptions/s-1/operationresults/r-2?api-version=2021-04-01";
    const script = [_]Reply{
        .{ .respond = .{ .status = 202, .headers = &.{.{ .name = "Location", .value = result_url }}, .body = "" } },
        .{ .respond = .{ .status = 202, .headers = &.{.{ .name = "Location", .value = next_url }}, .body = "" } },
        .{ .respond = .{ .body = "" } },
    };
    var rig: Rig = .init(&script);
    defer rig.deinit();

    var op = try rig.begin(.{ .method = .DELETE, .path = rg_path }, .{});
    try operation.wait(rig.engine(), rig.arena.allocator(), &op, 600_000);
    try testing.expectEqual(.succeeded, op.state);
    try testing.expectEqualStrings(next_url, (try rig.fake.streamRequest(2)).url);
}

test "operation: a DELETE or POST answered 202 with nothing to poll cannot be followed" {
    const script = [_]Reply{.{ .respond = .{ .status = 202, .body = "" } }};
    var rig: Rig = .init(&script);
    defer rig.deinit();

    try testing.expectError(error.InvalidOperation, rig.begin(.{ .method = .DELETE, .path = rg_path }, .{}));
    try testing.expectEqualStrings("the answer was 202 with no URL to poll", rig.diag.message());
}

test "operation: a POST's result is read at its Location once its operation succeeds" {
    const restart = "/subscriptions/s-1/resourceGroups/rg-1/providers/Microsoft.Compute/virtualMachines/vm-1/restart?api-version=2024-07-01";
    const script = [_]Reply{
        .{ .respond = .{ .status = 202, .headers = &.{ .{ .name = "Azure-AsyncOperation", .value = op_url }, .{ .name = "Location", .value = result_url } }, .body = "" } },
        .{ .respond = .{ .body = "{\"status\":\"Succeeded\",\"properties\":{\"output\":\"op body\"}}" } },
        .{ .respond = .{ .body = "{\"output\":\"location body\"}" } },
    };
    var rig: Rig = .init(&script);
    defer rig.deinit();
    const a = rig.arena.allocator();

    var op = try rig.begin(.{ .method = .POST, .path = restart }, .{});
    try operation.wait(rig.engine(), a, &op, 600_000);
    try testing.expectEqualStrings("{\"output\":\"location body\"}", (try operation.result(rig.engine(), a, &op)).?);
    try testing.expectEqualStrings(result_url, (try rig.fake.request(0)).url);

    // With final-state-via azure-async-operation, the operation's own body.
    op.options.final_state_via = .azure_async_operation;
    try testing.expectStringStartsWith((try operation.result(rig.engine(), a, &op)).?, "{\"status\":\"Succeeded\"");
}

test "operation: a URL off ARM's origin is refused before anything goes to it" {
    const script = [_]Reply{.{ .respond = .{
        .status = 201,
        .headers = &.{.{ .name = "Azure-AsyncOperation", .value = "https://management.azure.com.evil.example/op" }},
        .body = "",
    } }};
    var rig: Rig = .init(&script);
    defer rig.deinit();

    try testing.expectError(error.InvalidEndpoint, rig.begin(create_vm, .{}));
    try testing.expectEqual(1, rig.fake.stream_requests.items.len);
    try testing.expectEqualStrings("an operation's URL is not on https://management.azure.com", rig.diag.message());
}

test "operation: wait stops at its time limit, the operation as it stands" {
    const script = comptime core_testing.asyncOperation(201, op_url, "20", &.{ "InProgress", "InProgress", "InProgress" });
    var rig: Rig = .init(&script);
    defer rig.deinit();

    var op = try rig.begin(create_vm, .{});
    try operation.wait(rig.engine(), rig.arena.allocator(), &op, 30_000);
    try testing.expectEqual(.running, op.state);
    // 20 s as asked, then the 10 s the limit leaves, and no more.
    try testing.expectEqual(2, rig.clock.sleep_count);
    try testing.expectEqual(20_000, rig.clock.sleepMs(0));
    try testing.expectEqual(10_000, rig.clock.sleepMs(1));
    try testing.expectEqual(3, rig.fake.stream_requests.items.len);
}

test "operation: Retry-After 0 waits the least, and none waits the default" {
    const script = [_]Reply{
        .{ .respond = .{ .status = 202, .headers = &.{ .{ .name = "Location", .value = result_url }, .{ .name = "Retry-After", .value = "0" } }, .body = "" } },
        .{ .respond = .{ .status = 202, .headers = &.{.{ .name = "Location", .value = result_url }}, .body = "" } },
    };
    var rig: Rig = .init(&script);
    defer rig.deinit();

    var op = try rig.begin(.{ .method = .DELETE, .path = rg_path }, .{});
    try testing.expectEqual(1_000, op.delay_ms);
    try operation.poll(rig.engine(), rig.arena.allocator(), &op);
    try testing.expectEqual(30_000, op.delay_ms);
}

test "operation: an answer that is not ARM's cannot be read" {
    const script = comptime core_testing.asyncOperation(201, op_url, "1", &.{}) ++ [_]Reply{
        .{ .respond = .{ .body = "<html>gateway</html>" } },
    };
    var rig: Rig = .init(&script);
    defer rig.deinit();

    var op = try rig.begin(create_vm, .{});
    try testing.expectError(error.InvalidOperation, operation.poll(rig.engine(), rig.arena.allocator(), &op));
    try testing.expectStringStartsWith(rig.diag.message(), "an operation's status is not JSON");
}
