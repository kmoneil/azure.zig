//! The compute client, on Resource Manager: virtual machines made, read,
//! deallocated, started, restarted, evicted and deleted; the sizes a region
//! offers this subscription, its zones, and its quotas. Made with `init`,
//! freed with `deinit`; one task uses it at a time.

const Client = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const transport = core.transport;
const types = @import("types.zig");
const spec_ = @import("spec.zig");

const Engine = core.arm.Engine(.azure_compute);
const Operation = core.operation.Operation;

/// Microsoft.Compute's virtual machines and usages.
pub const api_version = "2026-04-01";
/// Resource SKUs.
pub const skus_api_version = "2021-07-01";
/// Microsoft.Resources' locations, which carry zone mappings.
pub const locations_api_version = "2022-12-01";

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
    /// An argument refused before anything is sent. `Diagnostics` says
    /// which.
    InvalidArgument,
    /// An answer that is not the JSON ARM sends. `Diagnostics` says which.
    InvalidResponse,
    /// A write whose answer cannot be followed.
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

// Virtual machines.

/// One VM, with its instance view read into `state`; `NotFound` when
/// there is none.
pub fn getVirtualMachine(self: *Client, subscription: []const u8, group: []const u8, name: []const u8) Error!types.Owned(types.VirtualMachine) {
    self.engine.begin();
    try self.checkGroup(subscription, group);
    if (!isVmName(name)) return self.refuse(spec_.vm_name_rule, .{});
    var out: types.Owned(types.VirtualMachine) = try .init(self.gpa);
    errdefer out.deinit();
    const a = out.arena.allocator();
    const path = try std.fmt.allocPrint(a, "/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.Compute/virtualMachines/{s}?api-version=" ++ api_version ++ "&$expand=instanceView", .{ subscription, group, name });
    const body = try self.get(a, path);
    const raw = std.json.parseFromSliceLeaky(RawVm, a, body, json_options) catch |err| return self.decodeFailed(err, "a VM");
    out.value = try vmOf(a, raw);
    return out;
}

/// The VMs of a group, a subscription or a region, every page read; with
/// `options.tag`, only those with that tag and value. A list carries no
/// instance view, so each VM's `state.power` is null: get one for it.
pub fn listVirtualMachines(self: *Client, subscription: []const u8, scope: types.ListScope, options: types.ListOptions) Error!types.Owned([]types.VirtualMachine) {
    self.engine.begin();
    if (!core.names.isSubscription(subscription)) return self.refuse("a subscription id is a GUID", .{});
    switch (scope) {
        .subscription => {},
        .group => |g| try self.checkGroup(subscription, g),
        .location => |l| if (!core.names.isLocation(l)) return self.refuse("a location is letters and digits, as eastus2", .{}),
    }
    var out: types.Owned([]types.VirtualMachine) = try .init(self.gpa);
    errdefer out.deinit();
    const a = out.arena.allocator();
    const path = switch (scope) {
        .subscription => try std.fmt.allocPrint(a, "/subscriptions/{s}/providers/Microsoft.Compute/virtualMachines?api-version=" ++ api_version, .{subscription}),
        .group => |g| try std.fmt.allocPrint(a, "/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.Compute/virtualMachines?api-version=" ++ api_version, .{ subscription, g }),
        .location => |l| try std.fmt.allocPrint(a, "/subscriptions/{s}/providers/Microsoft.Compute/locations/{s}/virtualMachines?api-version=" ++ api_version, .{ subscription, l }),
    };
    var raw: std.ArrayList(RawVm) = .empty;
    try self.allPages(RawVm, a, path, &raw);
    var vms: std.ArrayList(types.VirtualMachine) = .empty;
    for (raw.items) |r| {
        const vm = try vmOf(a, r);
        if (options.tag) |t| {
            const value = vm.tag(t.name) orelse continue;
            if (!std.mem.eql(u8, value, t.value)) continue;
        }
        try vms.append(a, vm);
    }
    out.value = vms.items;
    return out;
}

// Writes.

/// A write to one VM: what `preview` shows, and what the `begin` calls
/// send.
pub const Write = union(enum) {
    create: spec_.VmSpec,
    /// A body of the caller's own, a JSON object as Compute's create takes
    /// it, for what `VmSpec` has no field for. Sent as given.
    create_raw: []const u8,
    delete: DeleteOptions,
    deallocate,
    start,
    restart,
    simulate_eviction,
};

pub const DeleteOptions = struct {
    /// `forceDeletion`: no graceful shutdown first, so the VM goes sooner,
    /// as a spot worker's end wants.
    force: bool = false,
};

/// Begins making the VM `name` from `spec`, and returns the operation to
/// wait on (`waitOperation`). The PUT carries `If-None-Match: *`, so it
/// never updates a VM there already: that is 412 `PreconditionFailed`, as
/// m0 measured, whether the VM is running or still being made.
///
/// When the PUT meets a VM (412), or its answer is lost (a timeout, a 5xx
/// after the loop's retries), the client reads the VM. One that carries
/// `spec.attempt_tag` is this create's own, landed by an earlier attempt,
/// and the operation follows its `provisioningState`; any other is
/// `PreconditionFailed`. Without an attempt tag a VM there is always
/// `PreconditionFailed`. So a create is made once, however often it is
/// tried (the plan's decision 2).
///
/// A refusal's kind is `RefusalClass.ofDiagnostics`. An allocation the
/// operation reports failed (`AllocationFailed`) leaves the VM there,
/// `State.isFailed`, until the caller deletes it (decision 3).
pub fn beginCreateVirtualMachine(self: *Client, subscription: []const u8, group: []const u8, name: []const u8, spec: spec_.VmSpec) Error!types.Owned(Operation) {
    return self.beginWrite(subscription, group, name, .{ .create = spec }, spec.attempt_tag);
}

/// As `beginCreateVirtualMachine`, from a body of the caller's own: a JSON
/// object, sent as given. `attempt_tag` is the tag in it, if any, that
/// marks this attempt.
pub fn beginCreateVirtualMachineRaw(self: *Client, subscription: []const u8, group: []const u8, name: []const u8, body: []const u8, attempt_tag: ?types.Tag) Error!types.Owned(Operation) {
    return self.beginWrite(subscription, group, name, .{ .create_raw = body }, attempt_tag);
}

/// Begins deleting the VM, with its OS disk and NIC where their delete
/// option says so, as `VmSpec`'s do, and returns the operation to wait on.
/// A VM that is not there has nothing to delete: the operation has
/// succeeded already.
pub fn beginDeleteVirtualMachine(self: *Client, subscription: []const u8, group: []const u8, name: []const u8, options: DeleteOptions) Error!types.Owned(Operation) {
    return self.beginWrite(subscription, group, name, .{ .delete = options }, null);
}

/// Begins stopping the VM and releasing its host: no compute charge until
/// started again. A VM with an ephemeral OS disk cannot be deallocated.
pub fn beginDeallocateVirtualMachine(self: *Client, subscription: []const u8, group: []const u8, name: []const u8) Error!types.Owned(Operation) {
    return self.beginWrite(subscription, group, name, .deallocate, null);
}

pub fn beginStartVirtualMachine(self: *Client, subscription: []const u8, group: []const u8, name: []const u8) Error!types.Owned(Operation) {
    return self.beginWrite(subscription, group, name, .start, null);
}

pub fn beginRestartVirtualMachine(self: *Client, subscription: []const u8, group: []const u8, name: []const u8) Error!types.Owned(Operation) {
    return self.beginWrite(subscription, group, name, .restart, null);
}

/// Has Azure evict the spot VM as it would for want of capacity. Compute
/// answers at once (204, measured); the VM's Scheduled Events show a
/// `Preempt`, and under eviction policy Delete the VM is gone some time
/// later, its NIC with it (87 s, measured).
pub fn simulateEviction(self: *Client, subscription: []const u8, group: []const u8, name: []const u8) Error!void {
    var op = try self.beginWrite(subscription, group, name, .simulate_eviction, null);
    op.deinit();
}

/// Polls `operation` until it ends or `timeout_ms` passes, and leaves it as
/// it then stands; a failed one is an answer, in its `state`, with ARM's
/// code and message in `failure_code` and `failure_message`
/// (`RefusalClass.ofOperation` reads them).
pub fn waitOperation(self: *Client, operation: *types.Owned(Operation), timeout_ms: u32) Error!void {
    self.engine.begin();
    core.operation.wait(self.engine, operation.arena.allocator(), &operation.value, timeout_ms) catch |err| return operationError(err);
}

/// The request `write` sends, built without sending it: its method, URL
/// and body, byte for byte, in `arena`. Headers are not part of it, a
/// create's `If-None-Match` among them, so neither is a token; a create's
/// body carries `custom_data` and `user_data`, as base64.
pub fn preview(self: *Client, arena: Allocator, subscription: []const u8, group: []const u8, name: []const u8, write: Write) Error!core.PreparedRequest {
    self.engine.begin();
    const call = try self.build(arena, subscription, group, name, write);
    return core.PreparedRequest.fromCall(arena, self.engine.base_url, .{ .method = call.method, .path = call.path, .body = call.body });
}

// Sizes, zones and quotas.

/// The VM sizes `location` offers this subscription, from Resource SKUs.
/// A size the subscription may not use there at all (a `Location`
/// restriction, as most sizes have on a new Pay-As-You-Go subscription) is
/// left out; each size's zones are the region's less the restricted ones.
/// Either kind of refused size is 409 `SkuNotAvailable` on create.
pub fn listSizes(self: *Client, subscription: []const u8, location: []const u8) Error!types.Owned([]types.Size) {
    self.engine.begin();
    if (!core.names.isSubscription(subscription)) return self.refuse("a subscription id is a GUID", .{});
    if (!core.names.isLocation(location)) return self.refuse("a location is letters and digits, as eastus2", .{});
    var out: types.Owned([]types.Size) = try .init(self.gpa);
    errdefer out.deinit();
    const a = out.arena.allocator();
    const path = try std.fmt.allocPrint(a, "/subscriptions/{s}/providers/Microsoft.Compute/skus?api-version=" ++ skus_api_version ++ "&$filter=location%20eq%20%27{s}%27", .{ subscription, location });
    var raw: std.ArrayList(RawSku) = .empty;
    try self.allPages(RawSku, a, path, &raw);
    var sizes: std.ArrayList(types.Size) = .empty;
    for (raw.items) |r| if (try sizeOf(a, r, location)) |s| try sizes.append(a, s);
    out.value = sizes.items;
    return out;
}

/// The regions the subscription can use, each with its zones as this
/// subscription numbers them and the physical zone each is.
pub fn listLocations(self: *Client, subscription: []const u8) Error!types.Owned([]types.Location) {
    self.engine.begin();
    if (!core.names.isSubscription(subscription)) return self.refuse("a subscription id is a GUID", .{});
    var out: types.Owned([]types.Location) = try .init(self.gpa);
    errdefer out.deinit();
    const a = out.arena.allocator();
    const path = try std.fmt.allocPrint(a, "/subscriptions/{s}/locations?api-version=" ++ locations_api_version, .{subscription});
    var raw: std.ArrayList(RawLocation) = .empty;
    try self.allPages(RawLocation, a, path, &raw);
    const locations = try a.alloc(types.Location, raw.items.len);
    for (raw.items, locations) |r, *l| {
        const mappings = r.availabilityZoneMappings orelse &.{};
        const zones = try a.alloc(types.ZoneMapping, mappings.len);
        for (mappings, zones) |m, *z| z.* = .{ .logical = m.logicalZone, .physical = m.physicalZone };
        l.* = .{ .name = r.name, .display_name = r.displayName, .zones = zones };
    }
    out.value = locations;
    return out;
}

/// The subscription's quotas in `location`: `cores`, each family's, and
/// `lowPriorityCores`, which every spot VM's vCPUs count against and
/// alone (measured: a family quota of 0 stopped no spot VM).
pub fn listUsages(self: *Client, subscription: []const u8, location: []const u8) Error!types.Owned([]types.Usage) {
    self.engine.begin();
    if (!core.names.isSubscription(subscription)) return self.refuse("a subscription id is a GUID", .{});
    if (!core.names.isLocation(location)) return self.refuse("a location is letters and digits, as eastus2", .{});
    var out: types.Owned([]types.Usage) = try .init(self.gpa);
    errdefer out.deinit();
    const a = out.arena.allocator();
    const path = try std.fmt.allocPrint(a, "/subscriptions/{s}/providers/Microsoft.Compute/locations/{s}/usages?api-version=" ++ api_version, .{ subscription, location });
    var raw: std.ArrayList(RawUsage) = .empty;
    try self.allPages(RawUsage, a, path, &raw);
    const usages = try a.alloc(types.Usage, raw.items.len);
    for (raw.items, usages) |r, *u| u.* = .{ .name = r.name.value, .display_name = r.name.localizedValue, .current = r.currentValue, .limit = r.limit };
    out.value = usages;
    return out;
}

// What the writes share.

/// A write's request, before it is sent.
const Built = struct {
    method: transport.Method,
    path: []const u8,
    body: ?[]const u8 = null,
};

/// Checks a write's names and spec, and builds its request in `arena`.
fn build(self: *Client, arena: Allocator, subscription: []const u8, group: []const u8, name: []const u8, write: Write) Error!Built {
    try self.checkGroup(subscription, group);
    if (!isVmName(name)) return self.refuse(spec_.vm_name_rule, .{});
    const vm = "/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.Compute/virtualMachines/{s}";
    const query = "?api-version=" ++ api_version;
    const args = .{ subscription, group, name };
    const force = switch (write) {
        .delete => |o| if (o.force) "&forceDeletion=true" else "",
        else => "",
    };
    return switch (write) {
        .create => |spec| create: {
            try spec_.check(spec, name, self.engine.diagnostics);
            var w: std.Io.Writer.Allocating = .init(arena);
            var jw: std.json.Stringify = .{ .writer = &w.writer };
            spec_.write(&jw, spec, name) catch return error.OutOfMemory;
            break :create .{ .method = .PUT, .path = try std.fmt.allocPrint(arena, vm ++ query, args), .body = w.written() };
        },
        .create_raw => |body| raw: {
            const value = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return self.refuse("a raw create's body is a JSON object", .{}),
            };
            if (value != .object) return self.refuse("a raw create's body is a JSON object", .{});
            break :raw .{ .method = .PUT, .path = try std.fmt.allocPrint(arena, vm ++ query, args), .body = body };
        },
        .delete => .{ .method = .DELETE, .path = try std.fmt.allocPrint(arena, vm ++ query ++ "{s}", .{ subscription, group, name, force }) },
        .deallocate => .{ .method = .POST, .path = try std.fmt.allocPrint(arena, vm ++ "/deallocate" ++ query, args) },
        .start => .{ .method = .POST, .path = try std.fmt.allocPrint(arena, vm ++ "/start" ++ query, args) },
        .restart => .{ .method = .POST, .path = try std.fmt.allocPrint(arena, vm ++ "/restart" ++ query, args) },
        .simulate_eviction => .{ .method = .POST, .path = try std.fmt.allocPrint(arena, vm ++ "/simulateEviction" ++ query, args) },
    };
}

/// Sends a write and returns how its operation stands. The request is
/// built over a wiping allocator, since a create's body may carry what its
/// custom data hides.
fn beginWrite(self: *Client, subscription: []const u8, group: []const u8, name: []const u8, write: Write, attempt_tag: ?types.Tag) Error!types.Owned(Operation) {
    self.engine.begin();
    var wiping: core.WipingAllocator = .init(self.gpa);
    var scratch: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer scratch.deinit();
    const call = try self.build(scratch.allocator(), subscription, group, name, write);
    var out: types.Owned(Operation) = try .init(self.gpa);
    errdefer out.deinit();
    const id = core.arm.clientRequestId(self.io);
    const headers = [_]transport.Header{
        .{ .name = "x-ms-client-request-id", .value = &id },
        .{ .name = "If-None-Match", .value = "*" },
    };
    const create = call.method == .PUT;
    const segments = [_][]const u8{call.body orelse ""};
    if (core.operation.begin(self.engine, out.arena.allocator(), .{
        .method = call.method,
        .path = call.path,
        .content_type = if (call.body != null) "application/json" else null,
        .headers = if (create) &headers else headers[0..1],
        .body = if (call.body != null) .{ .segments = &segments } else .none,
    }, .{})) |op| {
        out.value = op;
    } else |err| {
        const e = operationError(err);
        if (!create) return e;
        try self.claim(&out, call.path, e, attempt_tag orelse return e);
    }
    return out;
}

/// How long a claimed create waits between reads of its VM: what
/// Compute's create asks in `Retry-After` (10 s, measured).
const claim_delay_ms = 10_000;

/// After a create's PUT met a VM of the name, or lost its answer: when the
/// VM is there with `attempt_tag`, it is this create's own, and `out` is
/// set to follow its `provisioningState`. Otherwise returns `err`, or
/// `PreconditionFailed` for a VM that is another's.
fn claim(self: *Client, out: *types.Owned(Operation), path: []const u8, err: Error, attempt_tag: types.Tag) Error!void {
    if (!self.mayBeThere(err)) return err;
    const saved: ?core.Diagnostics = if (self.engine.diagnostics) |d| d.* else null;
    const a = out.arena.allocator();
    const body = self.get(a, path) catch |get_err| {
        if (get_err == error.OutOfMemory) return error.OutOfMemory;
        // The VM cannot be read, or is not there: the PUT's failure stands.
        if (saved) |s| self.engine.diagnostics.?.* = s;
        return err;
    };
    const raw = std.json.parseFromSliceLeaky(RawVm, a, body, json_options) catch |decode_err| return self.decodeFailed(decode_err, "a VM");
    const vm = try vmOf(a, raw);
    const value = vm.tag(attempt_tag.name) orelse "";
    if (!std.mem.eql(u8, value, attempt_tag.value)) {
        if (err == error.PreconditionFailed) {
            if (saved) |s| self.engine.diagnostics.?.* = s;
        } else if (self.engine.diagnostics) |d| {
            d.print("a VM named {s} is there already, and not this create's: its tag {s} is not {s}", .{ vm.name, attempt_tag.name, attempt_tag.value });
        }
        return error.PreconditionFailed;
    }
    const state = core.arm.operationState(raw.properties.provisioningState);
    out.value = .{
        .method = .PUT,
        .resource_path = try a.dupe(u8, path),
        .follow = .provisioning_state,
        .poll_path = try a.dupe(u8, path),
        .options = .{},
        .state = state,
        .delay_ms = claim_delay_ms,
        .final_body = if (state == .running) "" else body,
    };
    if (self.engine.diagnostics) |d| d.clear();
}

/// Whether a create's PUT that failed with `err` may have met, or made, a
/// VM: a 412, an answer lost, or a 409 that is no refusal of a kind
/// `RefusalClass` knows (a quota's or capacity's comes before any VM).
fn mayBeThere(self: *Client, err: Error) bool {
    return switch (err) {
        error.PreconditionFailed, error.ServerError, error.RequestTimeout => true,
        error.TimedOut, error.ConnectionResetByPeer, error.ConnectionTimedOut, error.HttpProtocolError, error.NetworkFailure => true,
        error.Conflict => if (self.engine.diagnostics) |d| types.RefusalClass.ofDiagnostics(d) == .other else true,
        else => false,
    };
}

fn operationError(err: core.operation.Error(Engine)) Error {
    return switch (err) {
        error.WriteFailed => unreachable,
        else => |e| e,
    };
}

// The wire.

const json_options: std.json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };

const RawStatus = struct { code: []const u8 = "" };

const RawVm = struct {
    name: []const u8 = "",
    id: []const u8 = "",
    location: []const u8 = "",
    zones: ?[]const []const u8 = null,
    tags: ?std.json.ArrayHashMap([]const u8) = null,
    properties: Properties = .{},

    const Properties = struct {
        vmId: []const u8 = "",
        timeCreated: []const u8 = "",
        priority: ?[]const u8 = null,
        evictionPolicy: ?[]const u8 = null,
        billingProfile: ?struct { maxPrice: ?f64 = null } = null,
        provisioningState: []const u8 = "",
        hardwareProfile: struct { vmSize: []const u8 = "" } = .{},
        instanceView: ?struct { statuses: []const RawStatus = &.{} } = null,
        networkProfile: ?struct { networkInterfaces: []const struct { id: []const u8 = "" } = &.{} } = null,
    };
};

fn vmOf(a: Allocator, r: RawVm) Allocator.Error!types.VirtualMachine {
    const p = r.properties;
    return .{
        .name = r.name,
        .id = r.id,
        .location = r.location,
        .vm_id = p.vmId,
        .size = p.hardwareProfile.vmSize,
        .zone = if (r.zones) |z| (if (z.len > 0) z[0] else null) else null,
        .priority = if (p.priority) |s| .parse(s) else .regular,
        .eviction_policy = if (p.evictionPolicy) |s| types.EvictionPolicy.parse(s) else null,
        .max_price = if (p.billingProfile) |b| b.maxPrice else null,
        .state = stateOf(p.provisioningState, if (p.instanceView) |v| v.statuses else null),
        .time_created = p.timeCreated,
        .tags = try tagsOf(a, r.tags),
        .nics = try nicsOf(a, p.networkProfile),
    };
}

fn nicsOf(a: Allocator, profile: anytype) Allocator.Error![]const []const u8 {
    const p = profile orelse return &.{};
    const ids = try a.alloc([]const u8, p.networkInterfaces.len);
    for (p.networkInterfaces, ids) |n, *id| id.* = n.id;
    return ids;
}

/// The state, from the instance view's statuses when there are some
/// (`ProvisioningState/succeeded`, `ProvisioningState/failed/AllocationFailed`,
/// `PowerState/running`), else from `provisioningState` alone.
fn stateOf(provisioning: []const u8, statuses: ?[]const RawStatus) types.State {
    var state: types.State = .{ .provisioning = .parse(provisioning) };
    const list = statuses orelse return state;
    for (list) |s| {
        if (std.mem.startsWith(u8, s.code, "ProvisioningState/")) {
            var parts = std.mem.splitScalar(u8, s.code["ProvisioningState/".len..], '/');
            state.provisioning = .parse(parts.first());
            state.failure = parts.rest();
        } else if (std.mem.startsWith(u8, s.code, "PowerState/")) {
            state.power = .parse(s.code["PowerState/".len..]);
        }
    }
    return state;
}

fn tagsOf(a: Allocator, raw: ?std.json.ArrayHashMap([]const u8)) Allocator.Error![]const types.Tag {
    const map = raw orelse return &.{};
    const tags = try a.alloc(types.Tag, map.map.count());
    var it = map.map.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) tags[i] = .{ .name = e.key_ptr.*, .value = e.value_ptr.* };
    return tags;
}

const RawSku = struct {
    resourceType: []const u8 = "",
    name: []const u8 = "",
    locationInfo: []const struct { location: []const u8 = "", zones: []const []const u8 = &.{} } = &.{},
    capabilities: []const struct { name: []const u8 = "", value: []const u8 = "" } = &.{},
    restrictions: []const struct {
        type: []const u8 = "",
        reasonCode: []const u8 = "",
        restrictionInfo: struct { zones: ?[]const []const u8 = null } = .{},
    } = &.{},

    fn capability(r: RawSku, name: []const u8) ?[]const u8 {
        for (r.capabilities) |c| if (std.mem.eql(u8, c.name, name)) return c.value;
        return null;
    }
};

/// A size from its SKU entry, or null for no VM size, or one this
/// subscription may not make in `location` at all.
fn sizeOf(a: Allocator, r: RawSku, location: []const u8) Allocator.Error!?types.Size {
    if (!std.mem.eql(u8, r.resourceType, "virtualMachines")) return null;
    const restricted = try restrictedZones(a, r) orelse return null;
    const zones = try usableZones(a, r, location, restricted);
    return .{
        .name = r.name,
        .vcpus = std.fmt.parseInt(u32, r.capability("vCPUs") orelse "0", 10) catch 0,
        .memory_gb = std.fmt.parseFloat(f64, r.capability("MemoryGB") orelse "0") catch 0,
        .spot = isTrue(r.capability("LowPriorityCapable")),
        .ephemeral_os_disk = isTrue(r.capability("EphemeralOSDiskSupported")),
        .resource_disk_mb = std.fmt.parseInt(u64, r.capability("MaxResourceVolumeMB") orelse "0", 10) catch 0,
        .zones = zones,
        .disk_controllers = controllersOf(r.capability("DiskControllerTypes")),
        .ephemeral_placements = placementsOf(r.capability("SupportedEphemeralOSDiskPlacements")),
        .nvme_disk_mb = std.fmt.parseInt(u64, r.capability("NvmeDiskSizeInMiB") orelse "0", 10) catch 0,
        .trusted_launch = !isTrue(r.capability("TrustedLaunchDisabled")),
    };
}

/// `DiskControllerTypes`, a list as `SCSI,NVMe`: SCSI alone where there
/// is none, as for v5's sizes.
fn controllersOf(value: ?[]const u8) types.DiskControllers {
    const list = value orelse return .{};
    var out: types.DiskControllers = .{ .scsi = false };
    var it = std.mem.tokenizeAny(u8, list, ", ");
    while (it.next()) |item| {
        if (std.ascii.eqlIgnoreCase(item, "SCSI")) out.scsi = true;
        if (std.ascii.eqlIgnoreCase(item, "NVMe")) out.nvme = true;
    }
    return out;
}

/// `SupportedEphemeralOSDiskPlacements`, a list as `ResourceDisk,CacheDisk`.
fn placementsOf(value: ?[]const u8) types.EphemeralPlacements {
    var out: types.EphemeralPlacements = .{};
    var it = std.mem.tokenizeAny(u8, value orelse "", ", ");
    while (it.next()) |item| {
        if (std.ascii.eqlIgnoreCase(item, "ResourceDisk")) out.resource_disk = true;
        if (std.ascii.eqlIgnoreCase(item, "CacheDisk")) out.cache_disk = true;
        if (std.ascii.eqlIgnoreCase(item, "NvmeDisk")) out.nvme_disk = true;
    }
    return out;
}

/// The zones a size's restrictions take away, or null when one takes the
/// whole region.
fn restrictedZones(a: Allocator, r: RawSku) Allocator.Error!?[]const []const u8 {
    var zones: std.ArrayList([]const u8) = .empty;
    for (r.restrictions) |x| {
        if (std.mem.eql(u8, x.type, "Location")) return null;
        if (!std.mem.eql(u8, x.type, "Zone")) continue;
        if (x.restrictionInfo.zones) |zs| try zones.appendSlice(a, zs);
    }
    return zones.items;
}

/// The region's zones for the size, less `restricted`, in order.
fn usableZones(a: Allocator, r: RawSku, location: []const u8, restricted: []const []const u8) Allocator.Error![]const []const u8 {
    var zones: std.ArrayList([]const u8) = .empty;
    for (r.locationInfo) |info| {
        if (!std.ascii.eqlIgnoreCase(info.location, location)) continue;
        for (info.zones) |z| if (!contains(restricted, z)) try zones.append(a, z);
    }
    std.mem.sort([]const u8, zones.items, {}, zoneLess);
    return zones.items;
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, item)) return true;
    return false;
}

fn isTrue(value: ?[]const u8) bool {
    return if (value) |v| std.ascii.eqlIgnoreCase(v, "True") else false;
}

fn zoneLess(_: void, a: []const u8, b: []const u8) bool {
    return if (a.len != b.len) a.len < b.len else std.mem.order(u8, a, b) == .lt;
}

const RawLocation = struct {
    name: []const u8 = "",
    displayName: []const u8 = "",
    availabilityZoneMappings: ?[]const struct { logicalZone: []const u8 = "", physicalZone: []const u8 = "" } = null,
};

const RawUsage = struct {
    currentValue: i64 = 0,
    limit: i64 = 0,
    name: struct { value: []const u8 = "", localizedValue: []const u8 = "" } = .{},
};

/// Every page of a list, its items appended to `out`.
fn allPages(self: *Client, comptime Raw: type, arena: Allocator, first: []const u8, out: *std.ArrayList(Raw)) Error!void {
    const Page = struct { value: []const Raw = &.{}, nextLink: ?[]const u8 = null };
    var path: ?[]const u8 = first;
    var pages: usize = 0;
    while (path) |p| : (pages += 1) {
        if (pages == max_pages) return self.invalidResponse("a list ran past {d} pages", .{max_pages});
        const body = try self.get(arena, p);
        const page = std.json.parseFromSliceLeaky(Page, arena, body, json_options) catch |err| return self.decodeFailed(err, "a page of a list");
        try out.appendSlice(arena, page.value);
        path = core.arm.nextPagePath(self.engine.base_url, page.nextLink) catch {
            if (self.engine.diagnostics) |d| d.print("a list's nextLink is not on {s}", .{self.engine.base_url});
            return error.InvalidEndpoint;
        };
        if (path) |next| if (std.mem.eql(u8, next, p)) return self.invalidResponse("a page names itself as the next", .{});
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

// Checks.

/// 1 to 64 of letters, digits and `.-_`, beginning with a letter or digit
/// and ending with one or `_`: a Linux VM's name, as it goes in the path.
pub const isVmName = spec_.isVmName;

fn checkGroup(self: *Client, subscription: []const u8, group: []const u8) Error!void {
    if (core.names.groupProblem(subscription, group)) |why| return self.refuse("{s}", .{why});
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

test {
    std.testing.refAllDecls(@This());
}

test "VM names" {
    const testing = std.testing;
    for ([_][]const u8{ "m0-vm1", "a", "pb_worker.1", "w_" }) |ok| try testing.expect(isVmName(ok));
    for ([_][]const u8{ "", "-a", "a-", "a.", "a b", "a/b", core.testing.repeat("a", 65) }) |bad| try testing.expect(!isVmName(bad));
}
