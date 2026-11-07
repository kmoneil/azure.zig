//! The resources client: subscriptions, resource groups and resource
//! providers, on Azure Resource Manager. Made with `init`, freed with
//! `deinit`; one task uses it at a time.

const Client = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const transport = core.transport;
const types = @import("types.zig");
const validate = @import("validate.zig");

const Engine = core.arm.Engine(.azure_resources);
const Operation = core.operation.Operation;

/// The api-version of `Microsoft.Resources/subscriptions`.
pub const subscriptions_api_version = "2022-12-01";
/// The api-version of resource groups and providers.
pub const api_version = "2021-04-01";

/// Pages read at most for one list, a guard against a server whose
/// `nextLink` never ends.
pub const max_pages = 10_000;

gpa: Allocator,
io: std.Io,
engine: Engine,
/// The transport the client made, when its options named none.
http: ?*transport.HttpTransport,

pub const Options = struct {
    /// Where tokens for Resource Manager come from: one of `auth`'s
    /// credentials, or a `core.StaticToken`.
    token_provider: core.TokenProvider,
    cloud: core.Cloud = .public,
    /// In place of the cloud's ARM endpoint, as `https://host[:port]` with
    /// no trailing slash. It must outlive the client.
    endpoint: ?[]const u8 = null,
    /// Null: a `std.http.Client` transport of the client's own.
    transport: ?transport.Transport = null,
    /// Details of the latest failed call.
    diagnostics: ?*core.Diagnostics = null,
    retry: core.RetryPolicy = core.arm.retry_policy,
    /// How long one attempt may take; 0 removes the limit.
    request_timeout_ms: u32 = 60_000,
    user_agent: []const u8 = "azure.zig",
};

pub const Error = core.arm.Hook.RefusalError || transport.Error || core.TokenProvider.Error || error{
    /// An argument refused before anything is sent: a subscription that is
    /// not a GUID, or a name ARM would refuse. `Diagnostics` says which.
    InvalidArgument,
    /// An answer that is not the JSON ARM sends. `Diagnostics` says which.
    InvalidResponse,
    /// A delete whose answer cannot be followed.
    InvalidOperation,
};

pub fn init(gpa: Allocator, io: std.Io, options: Options) Allocator.Error!Client {
    var http: ?*transport.HttpTransport = null;
    const t = options.transport orelse t: {
        const h = try gpa.create(transport.HttpTransport);
        h.* = .init(gpa, io, options.user_agent);
        http = h;
        break :t h.transport();
    };
    return .{
        .gpa = gpa,
        .io = io,
        .http = http,
        .engine = .{
            .gpa = gpa,
            .io = io,
            .transport = t,
            .base_url = options.endpoint orelse options.cloud.arm_endpoint,
            .auth_scope = options.cloud.arm_scope,
            .token_provider = options.token_provider,
            .diagnostics = options.diagnostics,
            .headers = &core.arm.engine_headers,
            .retry = options.retry,
            .request_timeout_ms = options.request_timeout_ms,
        },
    };
}

pub fn deinit(self: *Client) void {
    if (self.http) |h| {
        h.deinit();
        self.gpa.destroy(h);
    }
    self.* = undefined;
}

// Subscriptions.

/// Every subscription the credential can see, every page read.
pub fn listSubscriptions(self: *Client) Error!types.Owned([]types.Subscription) {
    self.engine.begin();
    var out: types.Owned([]types.Subscription) = try .init(self.gpa);
    errdefer out.deinit();
    const a = out.arena.allocator();
    const Raw = struct {
        subscriptionId: []const u8 = "",
        displayName: []const u8 = "",
        tenantId: []const u8 = "",
        state: []const u8 = "",
    };
    var raw: std.ArrayList(Raw) = .empty;
    try self.allPages(Raw, a, "/subscriptions?api-version=" ++ subscriptions_api_version, &raw);
    const subscriptions = try a.alloc(types.Subscription, raw.items.len);
    for (raw.items, subscriptions) |r, *s| s.* = .{
        .id = r.subscriptionId,
        .display_name = r.displayName,
        .tenant_id = r.tenantId,
        .state = .parse(r.state),
    };
    out.value = subscriptions;
    return out;
}

// Resource groups.

/// Makes the group, or finds it there already and gives it the spec's tags
/// (replacing its own); either way, the group as it now is. A group being
/// deleted is `Conflict`, and so is one already in another location.
pub fn createResourceGroup(self: *Client, subscription: []const u8, name: []const u8, spec: types.GroupSpec) Error!types.Owned(types.CreatedGroup) {
    self.engine.begin();
    try self.checkGroup(subscription, name);
    try self.checkSpec(spec);
    var out: types.Owned(types.CreatedGroup) = try .init(self.gpa);
    errdefer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const body = try groupBody(scratch.allocator(), spec);
    var response: std.heap.ArenaAllocator = .init(self.gpa);
    defer response.deinit();
    const id = core.arm.clientRequestId(self.io);
    const res = self.engine.executeStream(&response, .{
        .method = .PUT,
        .path = try groupPath(scratch.allocator(), subscription, name, ""),
        .content_type = "application/json",
        .headers = &.{.{ .name = "x-ms-client-request-id", .value = &id }},
        .body = .{ .segments = &.{body} },
    }) catch |err| return streamError(err);
    out.value = .{ .group = try self.decodeGroup(out.arena.allocator(), res.body), .created = res.status == 201 };
    return out;
}

/// One resource group; `NotFound` when there is none of that name.
pub fn getResourceGroup(self: *Client, subscription: []const u8, name: []const u8) Error!types.Owned(types.ResourceGroup) {
    self.engine.begin();
    try self.checkGroup(subscription, name);
    var out: types.Owned(types.ResourceGroup) = try .init(self.gpa);
    errdefer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const body = try self.get(scratch.allocator(), try groupPath(scratch.allocator(), subscription, name, ""));
    out.value = try self.decodeGroup(out.arena.allocator(), body);
    return out;
}

/// The subscription's resource groups, every page read; with `filter`,
/// only those with that tag, as ARM filters them.
pub fn listResourceGroups(self: *Client, subscription: []const u8, filter: ?types.TagFilter) Error!types.Owned([]types.ResourceGroup) {
    self.engine.begin();
    if (!validate.isSubscription(subscription)) return self.refuse("a subscription id is a GUID", .{});
    if (filter) |f| {
        if (!validate.isTagName(f.name)) return self.refuse("a tag name is 1 to 512 bytes, none of <>%&\\?/", .{});
        if (f.value) |v| if (!validate.isTagValue(v)) return self.refuse("a tag value is up to 256 bytes, no control bytes", .{});
    }
    var out: types.Owned([]types.ResourceGroup) = try .init(self.gpa);
    errdefer out.deinit();
    const a = out.arena.allocator();
    var raw: std.ArrayList(RawGroup) = .empty;
    try self.allPages(RawGroup, a, try listPath(a, subscription, filter), &raw);
    const groups = try a.alloc(types.ResourceGroup, raw.items.len);
    for (raw.items, groups) |r, *g| g.* = try r.group(a);
    out.value = groups;
    return out;
}

/// Begins deleting the group and everything in it, and returns the
/// operation to wait on (`waitOperation`). A group that is not there is
/// `NotFound`.
pub fn beginDeleteResourceGroup(self: *Client, subscription: []const u8, name: []const u8, options: types.DeleteOptions) Error!types.Owned(Operation) {
    self.engine.begin();
    try self.checkGroup(subscription, name);
    var out: types.Owned(Operation) = try .init(self.gpa);
    errdefer out.deinit();
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const force = if (options.force_vms) "Microsoft.Compute/virtualMachines,Microsoft.Compute/virtualMachineScaleSets" else "";
    const id = core.arm.clientRequestId(self.io);
    out.value = core.operation.begin(self.engine, out.arena.allocator(), .{
        .method = .DELETE,
        .path = try groupPath(scratch.allocator(), subscription, name, force),
        .headers = &.{.{ .name = "x-ms-client-request-id", .value = &id }},
    }, .{}) catch |err| return operationError(err);
    return out;
}

/// Polls `operation` until it ends or `timeout_ms` passes, and leaves it as
/// it then stands; a failed one is an answer, in its `state`.
pub fn waitOperation(self: *Client, operation: *types.Owned(Operation), timeout_ms: u32) Error!void {
    self.engine.begin();
    core.operation.wait(self.engine, operation.arena.allocator(), &operation.value, timeout_ms) catch |err| return operationError(err);
}

// Providers.

/// How the subscription stands with a resource provider, such as
/// `Microsoft.Compute`.
pub fn getProvider(self: *Client, subscription: []const u8, namespace: []const u8) Error!types.Owned(types.Provider) {
    return self.provider(subscription, namespace, .GET, "");
}

/// Registers the subscription with a resource provider. It needs the
/// right to at subscription scope, and takes a while: the answer is
/// usually `registering`, and `getProvider` says when it is done. This
/// client never registers on its own.
pub fn registerProvider(self: *Client, subscription: []const u8, namespace: []const u8) Error!types.Owned(types.Provider) {
    return self.provider(subscription, namespace, .POST, "/register");
}

fn provider(self: *Client, subscription: []const u8, namespace: []const u8, method: transport.Method, suffix: []const u8) Error!types.Owned(types.Provider) {
    self.engine.begin();
    if (!validate.isSubscription(subscription)) return self.refuse("a subscription id is a GUID", .{});
    if (!validate.isNamespace(namespace)) return self.refuse("a provider namespace is letters, digits and dots", .{});
    var out: types.Owned(types.Provider) = try .init(self.gpa);
    errdefer out.deinit();
    const a = out.arena.allocator();
    var response: std.heap.ArenaAllocator = .init(self.gpa);
    defer response.deinit();
    const id = core.arm.clientRequestId(self.io);
    const body = try self.engine.execute(&response, .{
        .method = method,
        .path = try std.fmt.allocPrint(a, "/subscriptions/{s}/providers/{s}{s}?api-version=" ++ api_version, .{ subscription, namespace, suffix }),
        .headers = &.{.{ .name = "x-ms-client-request-id", .value = &id }},
        .body = if (method == .POST) "" else null,
    });
    const Raw = struct { namespace: []const u8 = "", registrationState: []const u8 = "" };
    const raw = std.json.parseFromSliceLeaky(Raw, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err|
        return self.decodeFailed(err, "a provider");
    out.value = .{ .namespace = raw.namespace, .registration_state = .parse(raw.registrationState) };
    return out;
}

// What the calls share.

/// A resource group as ARM sends one.
const RawGroup = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    location: []const u8 = "",
    tags: ?std.json.ArrayHashMap([]const u8) = null,
    properties: ?struct { provisioningState: []const u8 = "" } = null,
    managedBy: ?[]const u8 = null,

    fn group(raw: RawGroup, arena: Allocator) Allocator.Error!types.ResourceGroup {
        var tags: []types.Tag = &.{};
        if (raw.tags) |m| {
            tags = try arena.alloc(types.Tag, m.map.count());
            for (m.map.keys(), m.map.values(), tags) |k, v, *t| t.* = .{ .name = k, .value = v };
        }
        return .{
            .name = raw.name,
            .id = raw.id,
            .location = raw.location,
            .provisioning_state = if (raw.properties) |p| p.provisioningState else "",
            .tags = tags,
            .managed_by = raw.managedBy,
        };
    }
};

fn decodeGroup(self: *Client, arena: Allocator, body: []const u8) Error!types.ResourceGroup {
    const raw = std.json.parseFromSliceLeaky(RawGroup, arena, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err|
        return self.decodeFailed(err, "a resource group");
    return raw.group(arena);
}

/// Reads every page of a list into `out`, following each `nextLink` on
/// ARM's origin only.
fn allPages(self: *Client, comptime Raw: type, arena: Allocator, first: []const u8, out: *std.ArrayList(Raw)) Error!void {
    const Page = struct { value: []const Raw = &.{}, nextLink: ?[]const u8 = null };
    var response: std.heap.ArenaAllocator = .init(self.gpa);
    defer response.deinit();
    var path: ?[]const u8 = first;
    var pages: usize = 0;
    while (path) |p| : (pages += 1) {
        if (pages == max_pages) return self.invalidResponse("a list ran past {d} pages", .{max_pages});
        const body = try self.get(response.allocator(), p);
        const page = std.json.parseFromSliceLeaky(Page, arena, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err|
            return self.decodeFailed(err, "a page of a list");
        try out.appendSlice(arena, page.value);
        path = core.arm.nextPagePath(self.engine.base_url, page.nextLink) catch {
            if (self.engine.diagnostics) |d| d.print("a list's nextLink is not on {s}", .{self.engine.base_url});
            return error.InvalidEndpoint;
        };
        if (path) |next| if (std.mem.eql(u8, next, p)) return self.invalidResponse("a page names itself as the next", .{});
        _ = response.reset(.retain_capacity);
    }
}

/// A GET's body, copied into `arena`, with a request id of its own.
fn get(self: *Client, arena: Allocator, path: []const u8) Error![]const u8 {
    var response: std.heap.ArenaAllocator = .init(self.gpa);
    defer response.deinit();
    const id = core.arm.clientRequestId(self.io);
    const body = try self.engine.execute(&response, .{
        .method = .GET,
        .path = path,
        .headers = &.{.{ .name = "x-ms-client-request-id", .value = &id }},
    });
    return arena.dupe(u8, body);
}

fn groupPath(arena: Allocator, subscription: []const u8, name: []const u8, force: []const u8) Allocator.Error![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    writeGroupPath(&w.writer, subscription, name, force) catch return error.OutOfMemory;
    return w.written();
}

fn writeGroupPath(w: *std.Io.Writer, subscription: []const u8, name: []const u8, force: []const u8) std.Io.Writer.Error!void {
    try w.print("/subscriptions/{s}/resourcegroups/{s}", .{ subscription, name });
    var params: core.query.Params = .init(w);
    try params.add("api-version", api_version);
    try params.addOptional("forceDeletionTypes", force);
}

fn listPath(arena: Allocator, subscription: []const u8, filter: ?types.TagFilter) Allocator.Error![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    writeListPath(&w.writer, arena, subscription, filter) catch return error.OutOfMemory;
    return w.written();
}

fn writeListPath(w: *std.Io.Writer, arena: Allocator, subscription: []const u8, filter: ?types.TagFilter) (std.Io.Writer.Error || Allocator.Error)!void {
    try w.print("/subscriptions/{s}/resourcegroups", .{subscription});
    var params: core.query.Params = .init(w);
    try params.add("api-version", api_version);
    const f = filter orelse return;
    var odata: std.Io.Writer.Allocating = .init(arena);
    try odata.writer.writeAll("tagName eq ");
    try writeODataString(&odata.writer, f.name);
    if (f.value) |v| {
        try odata.writer.writeAll(" and tagValue eq ");
        try writeODataString(&odata.writer, v);
    }
    try params.add("$filter", odata.written());
}

/// An OData string literal: in single quotes, each quote within doubled.
fn writeODataString(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('\'');
    for (text) |c| {
        if (c == '\'') try w.writeByte('\'');
        try w.writeByte(c);
    }
    try w.writeByte('\'');
}

/// `{"location":...,"tags":{...}}`. The tags are always sent, so a group
/// found there already ends with the spec's tags and no others.
fn groupBody(arena: Allocator, spec: types.GroupSpec) Allocator.Error![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &w.writer };
    writeGroupBody(&jw, spec) catch return error.OutOfMemory;
    return w.written();
}

fn writeGroupBody(jw: *std.json.Stringify, spec: types.GroupSpec) std.json.Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("location");
    try jw.write(spec.location);
    try jw.objectField("tags");
    try jw.beginObject();
    for (spec.tags) |t| {
        try jw.objectField(t.name);
        try jw.write(t.value);
    }
    try jw.endObject();
    try jw.endObject();
}

fn checkGroup(self: *Client, subscription: []const u8, name: []const u8) Error!void {
    if (core.names.groupProblem(subscription, name)) |why| return self.refuse("{s}", .{why});
}

fn checkSpec(self: *Client, spec: types.GroupSpec) Error!void {
    if (!validate.isLocation(spec.location)) return self.refuse("a location is letters and digits, as eastus2", .{});
    if (core.names.tagsProblem(spec.tags)) |why| return self.refuse("{s}", .{why});
}

fn refuse(self: *Client, comptime fmt: []const u8, args: anytype) error{InvalidArgument} {
    if (self.engine.diagnostics) |d| d.print(fmt, args);
    return error.InvalidArgument;
}

fn invalidResponse(self: *Client, comptime fmt: []const u8, args: anytype) error{InvalidResponse} {
    if (self.engine.diagnostics) |d| d.print(fmt, args);
    return error.InvalidResponse;
}

fn decodeFailed(self: *Client, err: anyerror, comptime what: []const u8) Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return self.invalidResponse(what ++ " is not the JSON ARM sends ({t})", .{err});
}

/// The loop's streaming errors; a buffered answer never writes to a sink.
fn streamError(err: Engine.StreamCallError) Error {
    return switch (err) {
        error.WriteFailed => unreachable,
        else => |e| e,
    };
}

fn operationError(err: core.operation.Error(Engine)) Error {
    return switch (err) {
        error.WriteFailed => unreachable,
        else => |e| e,
    };
}
