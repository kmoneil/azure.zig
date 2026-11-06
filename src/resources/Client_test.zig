//! The resources client against FakeResources, and against a scripted
//! transport where the request's exact shape is the point.

const std = @import("std");
const testing = std.testing;
const core = @import("core");
const Client = @import("Client.zig");
const FakeResources = @import("fake_resources.zig").FakeResources;

const sub = "0f9e8d7c-6b5a-4c3d-8e2f-1a0b9c8d7e6f";

const Rig = struct {
    fake: FakeResources,
    clock: core.testing.FakeClock = .{},
    token: core.testing.FakeTokenProvider = .{ .token = "eyJ0.arm" },
    diag: core.Diagnostics = .{},
    client: Client = undefined,

    /// In place: the client points at the fake, the clock and the token.
    fn init(rig: *Rig) !void {
        rig.* = .{ .fake = .init(testing.allocator) };
        try rig.fake.addSubscription(sub, "azzig test");
        rig.client = try .init(testing.allocator, rig.clock.io(), .{
            .token_provider = rig.token.provider(),
            .transport = rig.fake.transport(),
            .diagnostics = &rig.diag,
        });
    }

    fn deinit(rig: *Rig) void {
        rig.client.deinit();
        rig.fake.deinit();
    }
};

test "listSubscriptions: every page read, each state parsed" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    rig.fake.page_size = 2;
    for ([_][]const u8{ "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222", "33333333-3333-4333-8333-333333333333", "44444444-4444-4444-8444-444444444444" }) |id| {
        try rig.fake.addSubscription(id, "other");
    }
    rig.fake.subscriptions.items[4].state = "PastDue";

    var subs = try rig.client.listSubscriptions();
    defer subs.deinit();
    try testing.expectEqual(5, subs.value.len);
    try testing.expectEqualStrings(sub, subs.value[0].id);
    try testing.expectEqualStrings("azzig test", subs.value[0].display_name);
    try testing.expectEqual(.enabled, subs.value[0].state);
    try testing.expectEqual(.past_due, subs.value[4].state);
    try testing.expectEqual(3, rig.fake.calls.items.len);
    try testing.expectStringEndsWith(rig.fake.calls.items[2].url, "/subscriptions?api-version=2022-12-01&%24skiptoken=4");
    // Asked of the token provider: Resource Manager's scope.
    try testing.expectEqualStrings(core.Cloud.public.arm_scope, rig.token.firstScope());
}

test "createResourceGroup: 201 when made, 200 when there already, its tags replaced" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    var made = try rig.client.createResourceGroup(sub, "azzig-resources-1", .{
        .location = "eastus2",
        .tags = &.{ .{ .name = "azzig-run", .value = "r1" }, .{ .name = "azzig-created", .value = "1762466400" } },
    });
    defer made.deinit();
    try testing.expect(made.value.created);
    try testing.expectEqualStrings("azzig-resources-1", made.value.group.name);
    try testing.expectEqualStrings("Succeeded", made.value.group.provisioning_state);
    try testing.expectEqualStrings("r1", made.value.group.tag("AZZIG-RUN").?);
    try testing.expectEqualStrings("/subscriptions/" ++ sub ++ "/resourceGroups/azzig-resources-1", made.value.group.id);

    var again = try rig.client.createResourceGroup(sub, "AZZIG-resources-1", .{ .location = "eastus2", .tags = &.{.{ .name = "other", .value = "x" }} });
    defer again.deinit();
    try testing.expect(!again.value.created);
    try testing.expectEqual(null, again.value.group.tag("azzig-run"));
    try testing.expectEqualStrings("x", again.value.group.tag("other").?);
    try testing.expectEqual(1, rig.fake.findGroup(sub, "azzig-resources-1").?.tags.len);
}

test "createResourceGroup: one already in another location is Conflict, with ARM's code" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    try rig.fake.addGroup(sub, .{ .name = "rg-1", .location = "westus2", .tags = &.{} });

    try testing.expectError(error.Conflict, rig.client.createResourceGroup(sub, "rg-1", .{ .location = "eastus2" }));
    try testing.expectEqualStrings("InvalidResourceGroupLocation", rig.diag.code());
    try testing.expectEqualStrings("fa4e0000-0000-4000-8000-000000000001", rig.diag.requestId());
}

test "getResourceGroup: a group, and NotFound for one not there" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    try rig.fake.addGroup(sub, .{ .name = "rg-1", .location = "eastus2", .tags = &.{}, .managed_by = "/subscriptions/x/managedApp" });

    var got = try rig.client.getResourceGroup(sub, "RG-1");
    defer got.deinit();
    try testing.expectEqualStrings("eastus2", got.value.location);
    try testing.expectEqualStrings("/subscriptions/x/managedApp", got.value.managed_by.?);
    try testing.expectError(error.NotFound, rig.client.getResourceGroup(sub, "rg-2"));
    try testing.expectEqualStrings("ResourceGroupNotFound", rig.diag.code());
}

test "listResourceGroups: all, by tag name, by name and value, a quote in the value" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    rig.fake.page_size = 1;
    try rig.fake.addGroup(sub, .{ .name = "a", .location = "eastus2", .tags = &.{.{ .name = "azzig-run", .value = "o'brien" }} });
    try rig.fake.addGroup(sub, .{ .name = "b", .location = "eastus2", .tags = &.{.{ .name = "azzig-run", .value = "r2" }} });
    try rig.fake.addGroup(sub, .{ .name = "c", .location = "eastus2", .tags = &.{} });

    var all = try rig.client.listResourceGroups(sub, null);
    defer all.deinit();
    try testing.expectEqual(3, all.value.len);

    var tagged = try rig.client.listResourceGroups(sub, .{ .name = "azzig-run" });
    defer tagged.deinit();
    try testing.expectEqual(2, tagged.value.len);

    const before = rig.fake.calls.items.len;
    var quoted = try rig.client.listResourceGroups(sub, .{ .name = "azzig-run", .value = "o'brien" });
    defer quoted.deinit();
    try testing.expectEqual(1, quoted.value.len);
    try testing.expectEqualStrings("a", quoted.value[0].name);
    try testing.expectStringEndsWith(
        rig.fake.calls.items[before].url,
        "/resourcegroups?api-version=2021-04-01&%24filter=tagName%20eq%20%27azzig-run%27%20and%20tagValue%20eq%20%27o%27%27brien%27",
    );
}

test "beginDeleteResourceGroup and waitOperation: Deleting, then gone once the operation ends" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    rig.fake.delete_polls = 2;
    try rig.fake.addGroup(sub, .{ .name = "azzig-spot-1", .location = "eastus2", .tags = &.{} });

    var op = try rig.client.beginDeleteResourceGroup(sub, "azzig-spot-1", .{ .force_vms = true });
    defer op.deinit();
    try testing.expectEqual(.running, op.value.state);
    try testing.expectStringEndsWith(rig.fake.calls.items[0].url, "?api-version=2021-04-01&forceDeletionTypes=Microsoft.Compute%2FvirtualMachines%2CMicrosoft.Compute%2FvirtualMachineScaleSets");

    var deleting = try rig.client.getResourceGroup(sub, "azzig-spot-1");
    defer deleting.deinit();
    try testing.expectEqualStrings("Deleting", deleting.value.provisioning_state);
    try testing.expectError(error.Conflict, rig.client.createResourceGroup(sub, "azzig-spot-1", .{ .location = "eastus2" }));
    try testing.expectEqualStrings("ResourceGroupBeingDeleted", rig.diag.code());

    try rig.client.waitOperation(&op, 600_000);
    try testing.expectEqual(.succeeded, op.value.state);
    try testing.expectEqual(3, rig.clock.sleep_count);
    try testing.expectEqual(15_000, rig.clock.sleepMs(2));
    try testing.expectError(error.NotFound, rig.client.getResourceGroup(sub, "azzig-spot-1"));
}

test "beginDeleteResourceGroup: NotFound for a group not there" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    try testing.expectError(error.NotFound, rig.client.beginDeleteResourceGroup(sub, "gone", .{}));
}

test "providers: read, registered when asked, and never on their own" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    var before = try rig.client.getProvider(sub, "Microsoft.Compute");
    defer before.deinit();
    try testing.expectEqual(.not_registered, before.value.registration_state);
    var asked = try rig.client.registerProvider(sub, "microsoft.compute");
    defer asked.deinit();
    try testing.expectEqual(.registering, asked.value.registration_state);
    var after = try rig.client.getProvider(sub, "Microsoft.Compute");
    defer after.deinit();
    try testing.expectEqual(.registered, after.value.registration_state);
    try testing.expectEqual(.POST, rig.fake.calls.items[1].method);
    try testing.expectError(error.NotFound, rig.client.getProvider(sub, "Microsoft.Nothing"));
    try testing.expectEqualStrings("InvalidResourceNamespace", rig.diag.code());
}

test "an unknown subscription is NotFound, with ARM's code" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    try testing.expectError(error.NotFound, rig.client.listResourceGroups("99999999-9999-4999-8999-999999999999", null));
    try testing.expectEqualStrings("SubscriptionNotFound", rig.diag.code());
}

test "what ARM would refuse, or would read as another resource, is refused before anything is sent" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const c = &rig.client;

    try testing.expectError(error.InvalidArgument, c.getResourceGroup("not-a-guid", "rg"));
    try testing.expectEqualStrings("a subscription id is a GUID", rig.diag.message());
    for ([_][]const u8{ "..", "rg.", "a/b", "a?b", "" }) |name| {
        try testing.expectError(error.InvalidArgument, c.getResourceGroup(sub, name));
    }
    try testing.expectError(error.InvalidArgument, c.createResourceGroup(sub, "rg", .{ .location = "east us" }));
    try testing.expectError(error.InvalidArgument, c.createResourceGroup(sub, "rg", .{
        .location = "eastus2",
        .tags = &.{ .{ .name = "Run", .value = "1" }, .{ .name = "run", .value = "2" } },
    }));
    try testing.expectError(error.InvalidArgument, c.listResourceGroups(sub, .{ .name = "a/b" }));
    try testing.expectError(error.InvalidArgument, c.getProvider(sub, "Micro/soft"));
    try testing.expectEqual(0, rig.fake.calls.items.len);
}

/// A client over a scripted transport, for the exact shape of what it sends.
const Scripted = struct {
    fake: core.testing.FakeTransport,
    clock: core.testing.FakeClock = .{},
    token: core.testing.FakeTokenProvider = .{},
    diag: core.Diagnostics = .{},
    client: Client = undefined,

    fn init(s: *Scripted, script: []const core.testing.FakeTransport.Reply) !void {
        s.* = .{ .fake = .init(testing.allocator, script) };
        s.client = try .init(testing.allocator, s.clock.io(), .{
            .token_provider = s.token.provider(),
            .transport = s.fake.transport(),
            .diagnostics = &s.diag,
        });
    }

    fn deinit(s: *Scripted) void {
        s.client.deinit();
        s.fake.deinit();
    }
};

test "createResourceGroup sends one PUT: JSON body, its tags always, a request id ARM echoes" {
    const script = [_]core.testing.FakeTransport.Reply{.{ .respond = .{ .status = 201, .body = "{\"name\":\"rg-1\",\"location\":\"eastus2\",\"properties\":{\"provisioningState\":\"Succeeded\"}}" } }};
    var s: Scripted = undefined;
    try s.init(&script);
    defer s.deinit();

    var made = try s.client.createResourceGroup(sub, "rg-1", .{ .location = "eastus2" });
    defer made.deinit();
    try testing.expectEqual(0, made.value.group.tags.len);
    const sent = try s.fake.streamRequest(0);
    try testing.expectEqual(.PUT, sent.method);
    try testing.expectEqualStrings("https://management.azure.com/subscriptions/" ++ sub ++ "/resourcegroups/rg-1?api-version=2021-04-01", sent.url);
    try testing.expectEqualStrings("application/json", sent.content_type.?);
    try testing.expectEqualStrings("{\"location\":\"eastus2\",\"tags\":{}}", sent.body_prefix);
    try testing.expectEqual(36, sent.header("x-ms-client-request-id").?.len);
    try testing.expectEqualStrings("true", sent.header("x-ms-return-client-request-id").?);
}

test "a list's nextLink off ARM's origin is refused, and a page naming itself ends as InvalidResponse" {
    const off = [_]core.testing.FakeTransport.Reply{.{ .respond = .{ .body = "{\"value\":[],\"nextLink\":\"https://evil.example/subscriptions\"}" } }};
    var s: Scripted = undefined;
    try s.init(&off);
    defer s.deinit();
    try testing.expectError(error.InvalidEndpoint, s.client.listSubscriptions());
    try testing.expectEqual(1, s.fake.requests.items.len);

    const loop = [_]core.testing.FakeTransport.Reply{.{ .respond = .{ .body = "{\"value\":[],\"nextLink\":\"https://management.azure.com/subscriptions?api-version=2022-12-01\"}" } }};
    var l: Scripted = undefined;
    try l.init(&loop);
    defer l.deinit();
    try testing.expectError(error.InvalidResponse, l.client.listSubscriptions());
    try testing.expectEqualStrings("a page names itself as the next", l.diag.message());
}

test "an answer that is not ARM's JSON is InvalidResponse, with what it was" {
    const script = [_]core.testing.FakeTransport.Reply{.{ .respond = .{ .body = "<html>proxy</html>" } }};
    var s: Scripted = undefined;
    try s.init(&script);
    defer s.deinit();
    try testing.expectError(error.InvalidResponse, s.client.getResourceGroup(sub, "rg-1"));
    try testing.expectStringStartsWith(s.diag.message(), "a resource group is not the JSON ARM sends");
}
