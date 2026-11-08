//! Resource Manager's Compute in memory, for code that uses the compute
//! module: virtual machines with their instance views and their writes,
//! Resource SKUs, locations with zone mappings, and usages, behind
//! `Client.Options.transport`. Lists come in pages of `page_size`.
//!
//! What it holds by default is what t19's m0 measured on the test
//! subscription on 2026-11-07: eastus2 and westus2 with their zone
//! mappings (eastus2 has four), cores 10 and spot cores (lowPriorityCores)
//! 3 in each, and no sizes or VMs, which a test adds; `addMeasuredSizes`
//! adds eastus2's as they were read on 2026-11-08.
//!
//! Writes answer as m0 measured them, unless a line says otherwise:
//!
//! - A create is 201 with `Azure-AsyncOperation` and `Retry-After: 10`.
//!   The VM reads `Creating` and `starting` until its operation ends, then
//!   `Succeeded` and `running`. With `If-None-Match: *`, a VM there
//!   already is 412 `PreconditionFailed`, being made or not.
//! - A size the region does not offer the subscription, or a zone
//!   restricted for it, is 409 `SkuNotAvailable`; so is a size the fake
//!   was not given, so a test adds the sizes it makes.
//! - A create past its quota (`lowPriorityCores` for spot, `cores`
//!   otherwise) is 409 `OperationNotAllowed`, worded as Compute words it.
//!   A made VM's vCPUs count from its create until it is gone.
//! - `failNextCreate` makes the next create's operation end `Failed`, as
//!   `AllocationFailed` does: the VM stays, `Failed`, until deleted.
//!   `lose_next_create` makes the next create's VM and answers 504, as an
//!   answer lost on its way would leave it.
//! - `simulateEviction` is 204. Under eviction policy Delete the VM reads
//!   as it was once more, then `Deleting` with no power state, for
//!   `eviction_reads` reads in all, then is gone (the live suite, on
//!   2026-11-08: running at once, deleting at 11 s, gone at 21 s; m0 read
//!   it running for 73 s, gone at 87 s).
//! - Delete, deallocate, start and restart are followed through
//!   `Azure-AsyncOperation` (measured 2026-11-08); a delete of a VM not
//!   there ends at once, with nothing to follow. Deallocating a VM with an
//!   ephemeral OS disk is 409 `OperationNotAllowed`, and spot on a size
//!   that cannot run as spot 400 `AzureSpotIsNotSupportedForThisVMSize`
//!   (the codes Azure's pages name; unmeasured).
//!
//! An operation answers as running for `operation_polls` reads of it or
//! of its VM, then ends: each read is a step of time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const wire = core.transport;
const Header = wire.Header;

const api_version = "2026-04-01";

pub const FakeCompute = struct {
    arena: std.heap.ArenaAllocator,
    /// The ARM endpoint the fake answers as, and writes into next links
    /// and operation URLs.
    base_url: []const u8 = core.Cloud.public.arm_endpoint,
    /// Items in one page of a list.
    page_size: usize = 100,
    /// Reads of an operation, or of its VM, answered as running before it
    /// ends.
    operation_polls: u32 = 1,
    /// What a running operation asks in `Retry-After`, in seconds.
    retry_after: []const u8 = "10",
    /// Reads of an evicted VM, under eviction policy Delete, that still
    /// find it.
    eviction_reads: u32 = 1,
    /// Makes the next create's VM, then answers 504.
    lose_next_create: bool = false,
    vms: std.ArrayList(Vm) = .empty,
    sizes: std.ArrayList(Size) = .empty,
    locations: std.ArrayList(Location) = .empty,
    usages: std.ArrayList(Usage) = .empty,
    operations: std.ArrayList(Pending) = .empty,
    /// Every request, in order.
    calls: std.ArrayList(Call) = .empty,
    next_id: u32 = 1,
    next_failure: ?Failure = null,

    pub const Call = struct {
        method: wire.Method,
        /// The path with its query.
        path: []const u8,
        body: []const u8 = "",
        /// The request's `If-None-Match`, when it has one.
        if_none_match: ?[]const u8 = null,
    };
    pub const Tag = struct { name: []const u8, value: []const u8 };
    pub const Failure = struct { code: []const u8, message: []const u8 };

    pub const Vm = struct {
        subscription: []const u8,
        group: []const u8,
        name: []const u8,
        location: []const u8 = "eastus2",
        size: []const u8 = "Standard_D2ds_v5",
        priority: []const u8 = "Spot",
        eviction_policy: ?[]const u8 = "Delete",
        max_price: f64 = -1,
        zone: ?[]const u8 = null,
        tags: []const Tag = &.{},
        /// As `provisioningState` writes it.
        provisioning: []const u8 = "Succeeded",
        /// The instance view's `PowerState/...`; null for none yet.
        power: ?[]const u8 = "running",
        /// After `ProvisioningState/failed/`, when provisioning failed.
        failure: []const u8 = "",
        vm_id: []const u8 = "00000000-0000-4000-8000-0000000000f1",
        /// An ephemeral OS disk, which cannot be deallocated.
        ephemeral_os_disk: bool = true,
        /// Its NIC's ARM id; empty for none.
        nic: []const u8 = "",
        /// The vCPUs it counts against its quota: a create's VM's.
        cores: u32 = 0,
        /// Reads left before an evicted VM is gone; null: not evicted.
        eviction_reads_left: ?u32 = null,
    };

    pub const Size = struct {
        name: []const u8,
        location: []const u8 = "eastus2",
        vcpus: u32 = 2,
        memory_gb: f64 = 8,
        spot: bool = true,
        ephemeral_os_disk: bool = false,
        resource_disk_mb: u64 = 0,
        zones: []const []const u8 = &.{ "1", "2", "3" },
        restricted_zones: []const []const u8 = &.{},
        /// NotAvailableForSubscription across the region.
        restricted_location: bool = false,
        /// `DiskControllerTypes` as Resource SKUs write it, `NVMe` or
        /// `SCSI,NVMe`; empty for none, as v5's sizes have.
        disk_controllers: []const u8 = "",
        /// `SupportedEphemeralOSDiskPlacements`, as `ResourceDisk`; empty
        /// for none.
        ephemeral_placements: []const u8 = "",
        nvme_disk_mb: u64 = 0,
        trusted_launch_disabled: bool = false,
    };

    pub const Location = struct {
        name: []const u8,
        display_name: []const u8,
        zones: []const [2][]const u8,
    };

    pub const Usage = struct {
        location: []const u8,
        name: []const u8,
        display_name: []const u8,
        current: i64 = 0,
        limit: i64,
    };

    const Pending = struct {
        id: []const u8,
        subscription: []const u8,
        group: []const u8,
        name: []const u8,
        kind: Kind,
        polls_left: u32,
        failure: ?Failure = null,
        done: bool = false,

        const Kind = enum { create, delete, deallocate, start, restart };
    };

    pub fn init(gpa: Allocator) Allocator.Error!FakeCompute {
        var self: FakeCompute = .{ .arena = .init(gpa) };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        try self.locations.appendSlice(a, &.{
            .{ .name = "eastus2", .display_name = "East US 2", .zones = &.{ .{ "1", "eastus2-az3" }, .{ "2", "eastus2-az2" }, .{ "3", "eastus2-az1" }, .{ "4", "eastus2-az5" } } },
            .{ .name = "westus2", .display_name = "West US 2", .zones = &.{ .{ "1", "westus2-az2" }, .{ "2", "westus2-az1" }, .{ "3", "westus2-az3" } } },
        });
        for ([_][]const u8{ "eastus2", "westus2" }) |l| try self.usages.appendSlice(a, &.{
            .{ .location = l, .name = "cores", .display_name = "Total Regional vCPUs", .limit = 10 },
            .{ .location = l, .name = "lowPriorityCores", .display_name = "Total Regional Low-priority vCPUs", .limit = 3 },
        });
        return self;
    }

    pub fn deinit(self: *FakeCompute) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn transport(self: *FakeCompute) wire.Transport {
        return .{ .ptr = self, .vtable = &.{ .send = send, .sendStream = sendStream } };
    }

    pub fn addVm(self: *FakeCompute, vm: Vm) Allocator.Error!void {
        try self.vms.append(self.arena.allocator(), vm);
    }

    pub fn addSize(self: *FakeCompute, size: Size) Allocator.Error!void {
        try self.sizes.append(self.arena.allocator(), size);
    }

    /// eastus2's sizes as the test subscription was offered them on
    /// 2026-11-08: D2ds_v5 and D2s_v5 in zone 4 alone (1 to 3 restricted),
    /// D2ds_v7 and D2s_v7 in all four, D2as_v5 and B2s not at all.
    pub fn addMeasuredSizes(self: *FakeCompute) Allocator.Error!void {
        const all: []const []const u8 = &.{ "1", "2", "3", "4" };
        const zones_1_to_3: []const []const u8 = &.{ "1", "2", "3" };
        try self.sizes.appendSlice(self.arena.allocator(), &.{
            .{ .name = "Standard_D2ds_v5", .ephemeral_os_disk = true, .resource_disk_mb = 76800, .zones = all, .restricted_zones = zones_1_to_3, .ephemeral_placements = "ResourceDisk" },
            .{ .name = "Standard_D2s_v5", .zones = all, .restricted_zones = zones_1_to_3 },
            .{ .name = "Standard_D2ds_v7", .ephemeral_os_disk = true, .zones = all, .disk_controllers = "NVMe", .ephemeral_placements = "NvmeDisk", .nvme_disk_mb = 112640 },
            .{ .name = "Standard_D2s_v7", .zones = all, .disk_controllers = "NVMe" },
            .{ .name = "Standard_D2as_v5", .zones = all, .restricted_location = true, .restricted_zones = zones_1_to_3 },
            .{ .name = "Standard_B2s", .spot = false, .ephemeral_os_disk = true, .resource_disk_mb = 8192, .zones = all, .restricted_location = true, .restricted_zones = all, .ephemeral_placements = "ResourceDisk,CacheDisk" },
        });
    }

    /// Makes the next create's operation end `Failed` with ARM's `code`
    /// and `message`, as `AllocationFailed` does; its VM stays, `Failed`.
    pub fn failNextCreate(self: *FakeCompute, code: []const u8, message: []const u8) Allocator.Error!void {
        const a = self.arena.allocator();
        self.next_failure = .{ .code = try a.dupe(u8, code), .message = try a.dupe(u8, message) };
    }

    pub fn findVm(self: *FakeCompute, subscription: []const u8, group: []const u8, name: []const u8) ?*Vm {
        for (self.vms.items) |*vm| if (eql(vm.subscription, subscription) and eql(vm.group, group) and eql(vm.name, name)) return vm;
        return null;
    }

    /// The usage named `name` in `location`.
    pub fn findUsage(self: *FakeCompute, location: []const u8, name: []const u8) ?*Usage {
        for (self.usages.items) |*u| if (eql(u.location, location) and eql(u.name, name)) return u;
        return null;
    }

    // The wire.

    /// A request as the routes read it.
    const Req = struct {
        method: wire.Method,
        path: []const u8,
        query: []const u8,
        body: []const u8,
        if_none_match: ?[]const u8,
    };

    fn send(ptr: *anyopaque, req: wire.Request, arena: Allocator) wire.Error!wire.Response {
        const self: *FakeCompute = @ptrCast(@alignCast(ptr));
        return self.answer(arena, req.method, req.url, req.body, req.headers);
    }

    fn sendStream(ptr: *anyopaque, req: wire.StreamRequest, arena: Allocator) wire.StreamError!wire.StreamResponse {
        const self: *FakeCompute = @ptrCast(@alignCast(ptr));
        const body: ?[]const u8 = switch (req.body) {
            .none => null,
            .segments => |segments| try std.mem.concat(arena, u8, segments),
            // Nothing in the compute module streams a body.
            .stream => return error.HttpProtocolError,
        };
        const got = try self.answer(arena, req.method, req.url, body, req.headers);
        if (req.head_out) |out| out.* = .{ .status = got.status, .headers = got.headers };
        if (got.status < 300 and req.sink == .writer) {
            req.sink.writer.writeAll(got.body) catch return error.WriteFailed;
            return .{ .status = got.status, .headers = got.headers, .bytes_streamed = got.body.len };
        }
        return .{ .status = got.status, .headers = got.headers, .body = got.body };
    }

    fn answer(self: *FakeCompute, arena: Allocator, method: wire.Method, url: []const u8, body: ?[]const u8, headers: []const Header) Allocator.Error!wire.Response {
        if (!std.mem.startsWith(u8, url, self.base_url)) return refusal(arena, 400, "InvalidRequestUri", "The request URI is not this ARM's.");
        const rest = url[self.base_url.len..];
        const a = self.arena.allocator();
        var if_none_match: ?[]const u8 = null;
        for (headers) |h| if (std.ascii.eqlIgnoreCase(h.name, "If-None-Match")) {
            if_none_match = try a.dupe(u8, h.value);
        };
        try self.calls.append(a, .{ .method = method, .path = try a.dupe(u8, rest), .body = try a.dupe(u8, body orelse ""), .if_none_match = if_none_match });
        const q = std.mem.indexOfScalar(u8, rest, '?');
        const req: Req = .{
            .method = method,
            .path = rest[0 .. q orelse rest.len],
            .query = if (q) |i| rest[i + 1 ..] else "",
            .body = body orelse "",
            .if_none_match = if_none_match,
        };
        var s: [10][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.tokenizeScalar(u8, req.path, '/');
        while (it.next()) |seg| : (n += 1) {
            if (n == s.len) return notFound(arena);
            s[n] = seg;
        }
        if (n < 2 or !eql(s[0], "subscriptions")) return notFound(arena);
        if (n >= 8 and eql(s[2], "resourceGroups") and eql(s[4], "providers") and eql(s[5], "Microsoft.Compute") and eql(s[6], "virtualMachines")) {
            return self.vmCall(arena, req, s[1], s[3], s[7], s[8..n]);
        }
        if (req.method != .GET) return refusal(arena, 405, "MethodNotAllowed", "The fake answers this path's reads alone.");
        return self.read(arena, req, s[0..n]);
    }

    fn read(self: *FakeCompute, arena: Allocator, req: Req, s: []const []const u8) Allocator.Error!wire.Response {
        const sub = s[1];
        if (s.len == 3 and eql(s[2], "locations")) return self.page(arena, req, try self.locationItems(arena));
        if (s.len >= 5 and eql(s[2], "providers") and eql(s[3], "Microsoft.Compute")) {
            if (s.len == 5 and eql(s[4], "virtualMachines")) return self.page(arena, req, try self.vmItems(arena, sub, null, null));
            if (s.len == 5 and eql(s[4], "skus")) return self.page(arena, req, try self.skuItems(arena, try skuLocation(arena, req.query)));
            if (s.len == 7 and eql(s[4], "locations") and eql(s[6], "virtualMachines")) return self.page(arena, req, try self.vmItems(arena, sub, null, s[5]));
            if (s.len == 7 and eql(s[4], "locations") and eql(s[6], "usages")) return self.page(arena, req, try self.usageItems(arena, s[5]));
            if (s.len == 8 and eql(s[4], "locations") and eql(s[6], "operations")) return self.pollOperation(arena, s[7]);
        }
        if (s.len == 7 and eql(s[2], "resourceGroups") and eql(s[4], "providers") and eql(s[5], "Microsoft.Compute") and eql(s[6], "virtualMachines")) {
            return self.page(arena, req, try self.vmItems(arena, sub, s[3], null));
        }
        return notFound(arena);
    }

    fn eql(a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }

    // One VM.

    fn vmCall(self: *FakeCompute, arena: Allocator, req: Req, sub: []const u8, group: []const u8, name: []const u8, action: []const []const u8) Allocator.Error!wire.Response {
        if (action.len == 0) return switch (req.method) {
            .GET => self.getVm(arena, sub, group, name, std.mem.indexOf(u8, req.query, "$expand=instanceView") != null),
            .PUT => self.putVm(arena, req, sub, group, name),
            .DELETE => self.deleteVm(arena, sub, group, name),
            else => refusal(arena, 405, "MethodNotAllowed", "A VM takes GET, PUT and DELETE."),
        };
        if (action.len > 1 or req.method != .POST) return notFound(arena);
        const vm = self.findVm(sub, group, name) orelse return vmNotFound(arena, group, name);
        const verb = action[0];
        if (eql(verb, "simulateEviction")) return self.evict(arena, vm);
        if (eql(verb, "deallocate")) {
            if (vm.ephemeral_os_disk) return refusal(arena, 409, "OperationNotAllowed", "Operation 'deallocate' is not supported for VMs with an ephemeral OS disk.");
            vm.provisioning = "Updating";
            vm.power = "deallocating";
            return self.started(arena, 202, vm, .deallocate, "");
        }
        if (eql(verb, "start") or eql(verb, "restart")) {
            vm.provisioning = "Updating";
            vm.power = "starting";
            return self.started(arena, 202, vm, if (eql(verb, "start")) .start else .restart, "");
        }
        return notFound(arena);
    }

    fn vmNotFound(arena: Allocator, group: []const u8, name: []const u8) Allocator.Error!wire.Response {
        return refusal(arena, 404, "ResourceNotFound", try std.fmt.allocPrint(arena, "The Resource 'Microsoft.Compute/virtualMachines/{s}' under resource group '{s}' was not found.", .{ name, group }));
    }

    /// A read of the VM, which is a step of time for its operation, and
    /// for its eviction.
    fn getVm(self: *FakeCompute, arena: Allocator, sub: []const u8, group: []const u8, name: []const u8, expand: bool) Allocator.Error!wire.Response {
        if (self.pendingOn(sub, group, name)) |op| _ = self.step(op);
        const vm = self.findVm(sub, group, name) orelse return vmNotFound(arena, group, name);
        if (vm.eviction_reads_left) |left| {
            if (left == 0) {
                self.remove(vm);
                return vmNotFound(arena, group, name);
            }
            vm.eviction_reads_left = left - 1;
            // As it was at the first read, then being deleted.
            if (left < self.eviction_reads) {
                vm.provisioning = "Deleting";
                vm.power = null;
            }
        }
        return .{ .status = 200, .body = try self.json(arena, vm.*, expand, writeVm) };
    }

    fn putVm(self: *FakeCompute, arena: Allocator, req: Req, sub: []const u8, group: []const u8, name: []const u8) Allocator.Error!wire.Response {
        if (self.findVm(sub, group, name) != null) {
            if (req.if_none_match) |v| if (std.mem.eql(u8, v, "*")) {
                return refusal(arena, 412, "PreconditionFailed", "If-none-match header (*) was specified in the request but resource already exists.");
            };
            return refusal(arena, 409, "PropertyChangeNotAllowed", "The fake makes VMs; it does not update them.");
        }
        const a = self.arena.allocator();
        const root = std.json.parseFromSliceLeaky(std.json.Value, a, req.body, .{}) catch
            return refusal(arena, 400, "InvalidRequestContent", "The request content was invalid and could not be deserialized.");
        var vm: Vm = .{ .subscription = try a.dupe(u8, sub), .group = try a.dupe(u8, group), .name = try a.dupe(u8, name), .ephemeral_os_disk = false };
        if (try self.readSpec(arena, root, &vm)) |refused| return refused;
        if (try self.admit(arena, &vm)) |refused| return refused;
        vm.provisioning = "Creating";
        vm.power = "starting";
        vm.vm_id = try std.fmt.allocPrint(a, "00000000-0000-4000-8000-{x:0>12}", .{self.next_id});
        try self.vms.append(a, vm);
        const made = &self.vms.items[self.vms.items.len - 1];
        const body = try self.json(arena, made.*, false, writeVm);
        const failure = self.next_failure;
        self.next_failure = null;
        if (self.lose_next_create) {
            self.lose_next_create = false;
            _ = try self.startOperation(made, .create, failure);
            return refusal(arena, 504, "GatewayTimeout", "The gateway did not receive a response within the specified time.");
        }
        return self.startedWith(arena, 201, made, .create, body, failure);
    }

    /// The VM's fields from a create's body, or the refusal of one that
    /// lacks what Compute requires.
    fn readSpec(self: *FakeCompute, arena: Allocator, root: std.json.Value, vm: *Vm) Allocator.Error!?wire.Response {
        const a = self.arena.allocator();
        vm.location = text(at(root, &.{"location"})) orelse return try refusal(arena, 400, "LocationRequired", "The location property is required for this definition.");
        vm.size = text(at(root, &.{ "properties", "hardwareProfile", "vmSize" })) orelse return try refusal(arena, 400, "InvalidParameter", "The value of parameter vmSize is invalid.");
        if (at(root, &.{"zones"})) |zones| if (zones == .array and zones.array.items.len > 0) {
            vm.zone = text(zones.array.items[0]);
        };
        vm.priority = text(at(root, &.{ "properties", "priority" })) orelse "Regular";
        vm.eviction_policy = text(at(root, &.{ "properties", "evictionPolicy" }));
        if (at(root, &.{ "properties", "billingProfile", "maxPrice" })) |p| vm.max_price = switch (p) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => -1,
        };
        vm.ephemeral_os_disk = at(root, &.{ "properties", "storageProfile", "osDisk", "diffDiskSettings" }) != null;
        if (at(root, &.{"tags"})) |tags| if (tags == .object) {
            const list = try a.alloc(Tag, tags.object.count());
            var it = tags.object.iterator();
            var i: usize = 0;
            while (it.next()) |e| : (i += 1) list[i] = .{ .name = e.key_ptr.*, .value = text(e.value_ptr.*) orelse "" };
            vm.tags = list;
        };
        if (at(root, &.{ "properties", "networkProfile", "networkInterfaceConfigurations" })) |nics| if (nics == .array and nics.array.items.len > 0) {
            // Azure names the NIC after its configuration, with a suffix of
            // its own (measured: m0-vm1-nic-10e88ade).
            const nic = text(at(nics.array.items[0], &.{"name"})) orelse "nic";
            vm.nic = try std.fmt.allocPrint(a, "/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.Network/networkInterfaces/{s}-{x:0>8}", .{ vm.subscription, vm.group, nic, self.next_id });
        };
        return null;
    }

    /// Whether the region offers the VM's size and zone, and its quota has
    /// room: null when it does, and its vCPUs are counted.
    fn admit(self: *FakeCompute, arena: Allocator, vm: *Vm) Allocator.Error!?wire.Response {
        const size = self.findSize(vm.location, vm.size) orelse return try skuNotAvailable(arena, vm.size, vm.location);
        if (size.restricted_location) return try skuNotAvailable(arena, vm.size, vm.location);
        if (vm.zone) |z| if (!has(size.zones, z) or has(size.restricted_zones, z)) return try skuNotAvailable(arena, vm.size, vm.location);
        const spot = eql(vm.priority, "Spot");
        if (spot and !size.spot) return try refusal(arena, 400, "AzureSpotIsNotSupportedForThisVMSize", "Azure Spot is not supported for this VM size.");
        const quota = self.findUsage(vm.location, if (spot) "lowPriorityCores" else "cores") orelse return null;
        if (quota.current + size.vcpus > quota.limit) {
            return try refusal(arena, 409, "OperationNotAllowed", try std.fmt.allocPrint(arena, "Operation could not be completed as it results in exceeding approved {s} quota. Additional details - Deployment Model: Resource Manager, Location: {s}, Current Limit: {d}, Current Usage: {d}, Additional Required: {d}, (Minimum) New Limit Required: {d}.", .{
                if (spot) "LowPriorityCores" else "Total Regional Cores", vm.location, quota.limit, quota.current, size.vcpus, quota.current + size.vcpus,
            }));
        }
        quota.current += size.vcpus;
        vm.cores = size.vcpus;
        return null;
    }

    fn deleteVm(self: *FakeCompute, arena: Allocator, sub: []const u8, group: []const u8, name: []const u8) Allocator.Error!wire.Response {
        const vm = self.findVm(sub, group, name) orelse return .{ .status = 204, .body = "" };
        vm.provisioning = "Deleting";
        return self.started(arena, 202, vm, .delete, "");
    }

    fn evict(self: *FakeCompute, arena: Allocator, vm: *Vm) Allocator.Error!wire.Response {
        if (!eql(vm.priority, "Spot")) return refusal(arena, 409, "OperationNotAllowed", "Simulate eviction is only for Spot VMs.");
        if (vm.eviction_policy != null and eql(vm.eviction_policy.?, "Deallocate")) {
            vm.power = "deallocated";
        } else {
            vm.eviction_reads_left = self.eviction_reads;
        }
        return .{ .status = 204, .body = "" };
    }

    fn findSize(self: *FakeCompute, location: []const u8, name: []const u8) ?Size {
        for (self.sizes.items) |s| if (eql(s.location, location) and eql(s.name, name)) return s;
        return null;
    }

    fn has(list: []const []const u8, item: []const u8) bool {
        for (list) |x| if (std.mem.eql(u8, x, item)) return true;
        return false;
    }

    /// Takes the VM away, and its vCPUs off its quota.
    fn remove(self: *FakeCompute, vm: *Vm) void {
        if (vm.cores > 0) {
            if (self.findUsage(vm.location, if (eql(vm.priority, "Spot")) "lowPriorityCores" else "cores")) |u| u.current -= vm.cores;
        }
        const i = (@intFromPtr(vm) - @intFromPtr(self.vms.items.ptr)) / @sizeOf(Vm);
        _ = self.vms.orderedRemove(i);
    }

    fn at(v: std.json.Value, keys: []const []const u8) ?std.json.Value {
        var cur = v;
        for (keys) |k| {
            if (cur != .object) return null;
            cur = cur.object.get(k) orelse return null;
        }
        return cur;
    }

    fn text(v: ?std.json.Value) ?[]const u8 {
        const value = v orelse return null;
        return if (value == .string) value.string else null;
    }

    // Operations.

    fn startOperation(self: *FakeCompute, vm: *const Vm, kind: Pending.Kind, failure: ?Failure) Allocator.Error!*Pending {
        const a = self.arena.allocator();
        const id = try std.fmt.allocPrint(a, "0c0e{x:0>4}-fa4e-4000-8000-000000000000", .{self.next_id});
        self.next_id += 1;
        try self.operations.append(a, .{ .id = id, .subscription = vm.subscription, .group = vm.group, .name = vm.name, .kind = kind, .polls_left = self.operation_polls, .failure = failure });
        return &self.operations.items[self.operations.items.len - 1];
    }

    fn started(self: *FakeCompute, arena: Allocator, status: u16, vm: *const Vm, kind: Pending.Kind, body: []const u8) Allocator.Error!wire.Response {
        return self.startedWith(arena, status, vm, kind, body, null);
    }

    /// Records the write's operation and answers it, with the URL to poll.
    fn startedWith(self: *FakeCompute, arena: Allocator, status: u16, vm: *const Vm, kind: Pending.Kind, body: []const u8, failure: ?Failure) Allocator.Error!wire.Response {
        const location = vm.location;
        const sub = vm.subscription;
        const op = try self.startOperation(vm, kind, failure);
        const poll = try std.fmt.allocPrint(arena, "{s}/subscriptions/{s}/providers/Microsoft.Compute/locations/{s}/operations/{s}?p=00000000-0000-4000-8000-000000000000&api-version=" ++ api_version, .{ self.base_url, sub, location, op.id });
        return .{ .status = status, .body = body, .headers = try arena.dupe(Header, &.{
            .{ .name = "Azure-AsyncOperation", .value = poll },
            .{ .name = "Retry-After", .value = self.retry_after },
        }) };
    }

    fn pendingOn(self: *FakeCompute, sub: []const u8, group: []const u8, name: []const u8) ?*Pending {
        for (self.operations.items) |*op| if (!op.done and eql(op.subscription, sub) and eql(op.group, group) and eql(op.name, name)) return op;
        return null;
    }

    /// One step of time for `op`: whether it is still running after it.
    fn step(self: *FakeCompute, op: *Pending) bool {
        if (op.done) return false;
        if (op.polls_left > 0) {
            op.polls_left -= 1;
            return true;
        }
        self.finish(op);
        return false;
    }

    fn pollOperation(self: *FakeCompute, arena: Allocator, id: []const u8) Allocator.Error!wire.Response {
        const op = for (self.operations.items) |*op| {
            if (eql(op.id, id)) break op;
        } else return notFound(arena);
        const start = "2026-11-07T21:07:11.5116552+00:00";
        if (self.step(op)) {
            return .{ .status = 200, .body = try jsonOf(arena, .{ .startTime = start, .status = "InProgress", .name = op.id }), .headers = try arena.dupe(Header, &.{.{ .name = "Retry-After", .value = self.retry_after }}) };
        }
        const end = "2026-11-07T21:07:43.2756077+00:00";
        const f = op.failure orelse return .{ .status = 200, .body = try jsonOf(arena, .{ .startTime = start, .endTime = end, .status = "Succeeded", .name = op.id }) };
        return .{ .status = 200, .body = try jsonOf(arena, .{ .startTime = start, .endTime = end, .status = "Failed", .@"error" = .{ .code = f.code, .message = f.message }, .name = op.id }) };
    }

    /// Ends the operation: the VM made (or failed), gone, deallocated, or
    /// running again.
    fn finish(self: *FakeCompute, op: *Pending) void {
        op.done = true;
        const vm = self.findVm(op.subscription, op.group, op.name) orelse return;
        switch (op.kind) {
            .delete => return self.remove(vm),
            .create => if (op.failure) |f| {
                vm.provisioning = "Failed";
                vm.failure = f.code;
                vm.power = null;
                return;
            },
            .deallocate => {
                vm.provisioning = "Succeeded";
                vm.power = "deallocated";
                return;
            },
            .start, .restart => {},
        }
        vm.provisioning = "Succeeded";
        vm.power = "running";
    }

    // Lists.

    fn vmItems(self: *FakeCompute, arena: Allocator, sub: []const u8, group: ?[]const u8, location: ?[]const u8) Allocator.Error![]const []const u8 {
        var items: std.ArrayList([]const u8) = .empty;
        for (self.vms.items) |vm| {
            if (!eql(vm.subscription, sub)) continue;
            if (group) |g| if (!eql(vm.group, g)) continue;
            if (location) |l| if (!eql(vm.location, l)) continue;
            try items.append(arena, try self.json(arena, vm, false, writeVm));
        }
        return items.items;
    }

    fn skuItems(self: *FakeCompute, arena: Allocator, location: ?[]const u8) Allocator.Error![]const []const u8 {
        var items: std.ArrayList([]const u8) = .empty;
        for (self.sizes.items) |size| {
            if (location) |l| if (!eql(size.location, l)) continue;
            try items.append(arena, try self.json(arena, size, false, writeSku));
        }
        return items.items;
    }

    fn locationItems(self: *FakeCompute, arena: Allocator) Allocator.Error![]const []const u8 {
        var items: std.ArrayList([]const u8) = .empty;
        for (self.locations.items) |l| try items.append(arena, try self.json(arena, l, false, writeLocation));
        return items.items;
    }

    fn usageItems(self: *FakeCompute, arena: Allocator, location: []const u8) Allocator.Error![]const []const u8 {
        var items: std.ArrayList([]const u8) = .empty;
        for (self.usages.items) |u| if (eql(u.location, location)) try items.append(arena, try self.json(arena, u, false, writeUsage));
        return items.items;
    }

    /// `location` from `$filter=location eq 'x'`, URL-encoded or not.
    fn skuLocation(arena: Allocator, query: []const u8) Allocator.Error!?[]const u8 {
        const decoded = std.Uri.percentDecodeInPlace(try arena.dupe(u8, query));
        const start = (std.mem.indexOf(u8, decoded, "location eq '") orelse return null) + "location eq '".len;
        const end = std.mem.indexOfScalarPos(u8, decoded, start, '\'') orelse return null;
        return decoded[start..end];
    }

    /// One page of `items`, from `$skiptoken`, with a next link while more
    /// remain.
    fn page(self: *FakeCompute, arena: Allocator, req: Req, items: []const []const u8) Allocator.Error!wire.Response {
        const query = req.query;
        var from: usize = 0;
        if (std.mem.indexOf(u8, query, "$skiptoken=")) |i| {
            const tail = query[i + "$skiptoken=".len ..];
            from = std.fmt.parseInt(usize, tail[0 .. std.mem.indexOfScalar(u8, tail, '&') orelse tail.len], 10) catch 0;
        }
        const to = @min(items.len, from + self.page_size);
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        w.writeAll("{\"value\":[") catch return error.OutOfMemory;
        for (items[@min(from, items.len)..to], 0..) |item, i| {
            if (i > 0) w.writeByte(',') catch return error.OutOfMemory;
            w.writeAll(item) catch return error.OutOfMemory;
        }
        w.writeByte(']') catch return error.OutOfMemory;
        if (to < items.len) {
            const base_query = if (std.mem.indexOf(u8, query, "&$skiptoken=")) |i| query[0..i] else query;
            w.print(",\"nextLink\":\"{s}{s}?{s}&$skiptoken={d}\"", .{ self.base_url, req.path, base_query, to }) catch return error.OutOfMemory;
        }
        w.writeByte('}') catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    // Bodies.

    fn json(self: *FakeCompute, arena: Allocator, value: anytype, expand: bool, comptime write: anytype) Allocator.Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: std.json.Stringify = .{ .writer = &out.writer };
        write(&jw, self, value, expand) catch return error.OutOfMemory;
        return out.written();
    }

    fn writeVm(jw: *std.json.Stringify, self: *FakeCompute, vm: Vm, expand: bool) !void {
        try jw.beginObject();
        try field(jw, "id", try std.fmt.allocPrint(self.arena.allocator(), "/subscriptions/{s}/resourceGroups/{s}/providers/Microsoft.Compute/virtualMachines/{s}", .{ vm.subscription, vm.group, vm.name }));
        try field(jw, "name", vm.name);
        try field(jw, "type", "Microsoft.Compute/virtualMachines");
        try field(jw, "location", vm.location);
        try jw.objectField("tags");
        try jw.beginObject();
        for (vm.tags) |t| try field(jw, t.name, t.value);
        try jw.endObject();
        if (vm.zone) |z| {
            try jw.objectField("zones");
            try jw.write(&[_][]const u8{z});
        }
        try jw.objectField("properties");
        try jw.beginObject();
        try field(jw, "vmId", vm.vm_id);
        try field(jw, "timeCreated", "2026-11-07T21:07:11.5157622+00:00");
        try field(jw, "priority", vm.priority);
        if (vm.eviction_policy) |e| try field(jw, "evictionPolicy", e);
        try jw.objectField("billingProfile");
        try jw.write(.{ .maxPrice = vm.max_price });
        try jw.objectField("hardwareProfile");
        try jw.write(.{ .vmSize = vm.size });
        try field(jw, "provisioningState", vm.provisioning);
        if (vm.nic.len > 0) {
            try jw.objectField("networkProfile");
            try jw.write(.{ .networkInterfaces = &[_]struct { id: []const u8, properties: struct { primary: bool = true, deleteOption: []const u8 = "Delete" } = .{} }{.{ .id = vm.nic }} });
        }
        if (expand) try writeInstanceView(jw, vm);
        try jw.endObject();
        try jw.endObject();
    }

    fn writeInstanceView(jw: *std.json.Stringify, vm: Vm) !void {
        try jw.objectField("instanceView");
        try jw.beginObject();
        try jw.objectField("statuses");
        try jw.beginArray();
        var buf: [32]u8 = undefined;
        const n = @min(vm.provisioning.len, buf.len);
        const lower = std.ascii.lowerString(buf[0..n], vm.provisioning[0..n]);
        var code_buf: [160]u8 = undefined;
        const code = if (vm.failure.len > 0)
            try std.fmt.bufPrint(&code_buf, "ProvisioningState/{s}/{s}", .{ lower, vm.failure })
        else
            try std.fmt.bufPrint(&code_buf, "ProvisioningState/{s}", .{lower});
        try jw.write(.{ .code = code, .level = if (vm.failure.len > 0) "Error" else "Info" });
        if (vm.power) |p| {
            var power_buf: [64]u8 = undefined;
            try jw.write(.{ .code = try std.fmt.bufPrint(&power_buf, "PowerState/{s}", .{p}), .level = "Info" });
        }
        try jw.endArray();
        try jw.endObject();
    }

    fn writeSku(jw: *std.json.Stringify, self: *FakeCompute, s: Size, expand: bool) !void {
        _ = self;
        _ = expand;
        try jw.beginObject();
        try field(jw, "resourceType", "virtualMachines");
        try field(jw, "name", s.name);
        try jw.objectField("locations");
        try jw.write(&[_][]const u8{s.location});
        try jw.objectField("locationInfo");
        try jw.write(&[_]struct { location: []const u8, zones: []const []const u8 }{.{ .location = s.location, .zones = s.zones }});
        try jw.objectField("capabilities");
        try writeCapabilities(jw, s);
        try jw.objectField("restrictions");
        try jw.beginArray();
        if (s.restricted_location) try jw.write(.{ .type = "Location", .values = &[_][]const u8{s.location}, .restrictionInfo = .{ .locations = &[_][]const u8{s.location} }, .reasonCode = "NotAvailableForSubscription" });
        if (s.restricted_zones.len > 0) try jw.write(.{ .type = "Zone", .values = &[_][]const u8{s.location}, .restrictionInfo = .{ .locations = &[_][]const u8{s.location}, .zones = s.restricted_zones }, .reasonCode = "NotAvailableForSubscription" });
        try jw.endArray();
        try jw.endObject();
    }

    fn writeCapabilities(jw: *std.json.Stringify, s: Size) !void {
        try jw.beginArray();
        var buf: [4][32]u8 = undefined;
        try jw.write(.{ .name = "vCPUs", .value = try std.fmt.bufPrint(&buf[0], "{d}", .{s.vcpus}) });
        try jw.write(.{ .name = "MemoryGB", .value = try std.fmt.bufPrint(&buf[1], "{d}", .{s.memory_gb}) });
        try jw.write(.{ .name = "LowPriorityCapable", .value = if (s.spot) "True" else "False" });
        try jw.write(.{ .name = "EphemeralOSDiskSupported", .value = if (s.ephemeral_os_disk) "True" else "False" });
        try jw.write(.{ .name = "MaxResourceVolumeMB", .value = try std.fmt.bufPrint(&buf[2], "{d}", .{s.resource_disk_mb}) });
        if (s.disk_controllers.len > 0) try jw.write(.{ .name = "DiskControllerTypes", .value = s.disk_controllers });
        if (s.ephemeral_placements.len > 0) try jw.write(.{ .name = "SupportedEphemeralOSDiskPlacements", .value = s.ephemeral_placements });
        if (s.nvme_disk_mb > 0) try jw.write(.{ .name = "NvmeDiskSizeInMiB", .value = try std.fmt.bufPrint(&buf[3], "{d}", .{s.nvme_disk_mb}) });
        if (s.trusted_launch_disabled) try jw.write(.{ .name = "TrustedLaunchDisabled", .value = "True" });
        try jw.endArray();
    }

    fn writeLocation(jw: *std.json.Stringify, self: *FakeCompute, l: Location, expand: bool) !void {
        _ = self;
        _ = expand;
        try jw.beginObject();
        try field(jw, "name", l.name);
        try field(jw, "displayName", l.display_name);
        try jw.objectField("metadata");
        try jw.write(.{ .regionType = "Physical" });
        if (l.zones.len > 0) {
            try jw.objectField("availabilityZoneMappings");
            try jw.beginArray();
            for (l.zones) |z| try jw.write(.{ .logicalZone = z[0], .physicalZone = z[1] });
            try jw.endArray();
        }
        try jw.endObject();
    }

    fn writeUsage(jw: *std.json.Stringify, self: *FakeCompute, u: Usage, expand: bool) !void {
        _ = self;
        _ = expand;
        try jw.write(.{ .limit = u.limit, .unit = "Count", .currentValue = u.current, .name = .{ .value = u.name, .localizedValue = u.display_name } });
    }

    fn field(jw: *std.json.Stringify, name: []const u8, value: []const u8) !void {
        try jw.objectField(name);
        try jw.write(value);
    }

    fn jsonOf(arena: Allocator, value: anytype) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(value, .{})});
    }

    // Refusals.

    fn notFound(arena: Allocator) Allocator.Error!wire.Response {
        return refusal(arena, 404, "NotFound", "The fake answers only the compute module's calls.");
    }

    /// As m0 measured it, for a size refused in the region or the zone.
    fn skuNotAvailable(arena: Allocator, size: []const u8, location: []const u8) Allocator.Error!wire.Response {
        return refusal(arena, 409, "SkuNotAvailable", try std.fmt.allocPrint(arena, "The requested VM size for resource 'Following SKUs have failed for Capacity Restrictions: {s}' is currently not available in location '{s}'. Please try another size or deploy to a different location or different zone. See https://aka.ms/azureskunotavailable for details.", .{ size, location }));
    }

    fn refusal(arena: Allocator, status: u16, code: []const u8, message: []const u8) Allocator.Error!wire.Response {
        return .{
            .status = status,
            .body = try jsonOf(arena, .{ .@"error" = .{ .code = code, .message = message } }),
            .headers = try arena.dupe(Header, &.{
                .{ .name = "x-ms-request-id", .value = "11111111-1111-4111-8111-111111111111" },
                .{ .name = "x-ms-correlation-request-id", .value = "22222222-2222-4222-8222-222222222222" },
            }),
        };
    }
};
