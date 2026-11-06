//! Azure Resource Manager in memory, for code that uses the resources
//! module: subscriptions, resource groups and providers, behind
//! `Client.Options.transport`. Paths and names match without regard to
//! case, as ARM's do. A delete is a long-running operation that answers 202
//! for `delete_polls` polls before the group is gone. The codes and shapes
//! are ARM's as documented; the live suite holds them to production.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const wire = core.transport;
const Header = wire.Header;

pub const FakeResources = struct {
    arena: std.heap.ArenaAllocator,
    /// The ARM endpoint the fake answers as, and writes into its links: the
    /// client's own (`Client.Options.endpoint`, or the public cloud's).
    base_url: []const u8 = core.Cloud.public.arm_endpoint,
    /// Items in one page of a list.
    page_size: usize = 100,
    /// Polls of a delete answered 202 before the group is gone.
    delete_polls: u32 = 1,
    /// What every 202 asks in `Retry-After`, in seconds.
    retry_after: []const u8 = "15",
    subscriptions: std.ArrayList(Subscription) = .empty,
    deletions: std.ArrayList(Deletion) = .empty,
    /// Every request, in order: its method and URL.
    calls: std.ArrayList(Call) = .empty,
    next_id: u32 = 1,

    pub const Call = struct { method: wire.Method, url: []const u8 };
    pub const Tag = struct { name: []const u8, value: []const u8 };

    pub const Group = struct {
        name: []const u8,
        location: []const u8,
        tags: []const Tag,
        deleting: bool = false,
        managed_by: ?[]const u8 = null,

        pub fn tag(group: Group, name: []const u8) ?[]const u8 {
            for (group.tags) |t| if (std.ascii.eqlIgnoreCase(t.name, name)) return t.value;
            return null;
        }
    };

    pub const Subscription = struct {
        id: []const u8,
        display_name: []const u8,
        tenant_id: []const u8 = "72f988bf-86f1-41af-91ab-2d7cd011db47",
        state: []const u8 = "Enabled",
        groups: std.ArrayList(Group) = .empty,
        providers: std.ArrayList(Provider) = .empty,
    };

    pub const Provider = struct { namespace: []const u8, state: []const u8 };

    const Deletion = struct { id: []const u8, subscription: []const u8, group: []const u8, polls_left: u32 };

    pub fn init(gpa: Allocator) FakeResources {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *FakeResources) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// A subscription the credential sees, with Microsoft.Resources
    /// registered and Compute, Network, Storage and ManagedIdentity not.
    pub fn addSubscription(self: *FakeResources, id: []const u8, display_name: []const u8) Allocator.Error!void {
        const a = self.arena.allocator();
        var sub: Subscription = .{ .id = try a.dupe(u8, id), .display_name = try a.dupe(u8, display_name) };
        try sub.providers.append(a, .{ .namespace = "Microsoft.Resources", .state = "Registered" });
        for ([_][]const u8{ "Microsoft.Compute", "Microsoft.Network", "Microsoft.Storage", "Microsoft.ManagedIdentity" }) |ns| {
            try sub.providers.append(a, .{ .namespace = ns, .state = "NotRegistered" });
        }
        try self.subscriptions.append(a, sub);
    }

    /// A group there before the test begins.
    pub fn addGroup(self: *FakeResources, subscription: []const u8, group: Group) Allocator.Error!void {
        const sub = self.findSubscription(subscription) orelse unreachable;
        try sub.groups.append(self.arena.allocator(), try self.copyGroup(group));
    }

    /// The group as the fake holds it now, or null.
    pub fn findGroup(self: *FakeResources, subscription: []const u8, name: []const u8) ?*Group {
        const sub = self.findSubscription(subscription) orelse return null;
        for (sub.groups.items) |*g| if (std.ascii.eqlIgnoreCase(g.name, name)) return g;
        return null;
    }

    pub fn transport(self: *FakeResources) wire.Transport {
        return .{ .ptr = self, .vtable = &.{ .send = send, .sendStream = sendStream } };
    }

    fn findSubscription(self: *FakeResources, id: []const u8) ?*Subscription {
        for (self.subscriptions.items) |*s| if (std.ascii.eqlIgnoreCase(s.id, id)) return s;
        return null;
    }

    fn copyGroup(self: *FakeResources, group: Group) Allocator.Error!Group {
        const a = self.arena.allocator();
        const tags = try a.alloc(Tag, group.tags.len);
        for (group.tags, tags) |t, *c| c.* = .{ .name = try a.dupe(u8, t.name), .value = try a.dupe(u8, t.value) };
        return .{
            .name = try a.dupe(u8, group.name),
            .location = try a.dupe(u8, group.location),
            .tags = tags,
            .deleting = group.deleting,
            .managed_by = if (group.managed_by) |m| try a.dupe(u8, m) else null,
        };
    }

    // The wire.

    const Answer = struct {
        status: u16 = 200,
        body: []const u8 = "",
        headers: []const Header = &.{},
    };

    fn send(ptr: *anyopaque, req: wire.Request, arena: Allocator) wire.Error!wire.Response {
        const self: *FakeResources = @ptrCast(@alignCast(ptr));
        const got = try self.answer(arena, req.method, req.url, req.body, req.bearer);
        return .{ .status = got.status, .body = got.body, .headers = got.headers };
    }

    fn sendStream(ptr: *anyopaque, req: wire.StreamRequest, arena: Allocator) wire.StreamError!wire.StreamResponse {
        const self: *FakeResources = @ptrCast(@alignCast(ptr));
        const body: ?[]const u8 = switch (req.body) {
            .none => null,
            .segments => |segments| try std.mem.concat(arena, u8, segments),
            // Nothing in the resources module streams a body.
            .stream => return error.HttpProtocolError,
        };
        const got = try self.answer(arena, req.method, req.url, body, req.bearer);
        if (req.head_out) |out| out.* = .{ .status = got.status, .headers = got.headers };
        if (got.status < 300 and req.sink == .writer) {
            req.sink.writer.writeAll(got.body) catch return error.WriteFailed;
            return .{ .status = got.status, .headers = got.headers, .bytes_streamed = got.body.len };
        }
        return .{ .status = got.status, .headers = got.headers, .body = got.body };
    }

    fn answer(self: *FakeResources, arena: Allocator, method: wire.Method, url: []const u8, body: ?[]const u8, bearer: ?[]const u8) Allocator.Error!Answer {
        try self.calls.append(self.arena.allocator(), .{ .method = method, .url = try self.arena.allocator().dupe(u8, url) });
        if (bearer == null) return refusal(arena, 401, "AuthenticationFailed", "Authentication failed. The 'Authorization' header is missing.");
        if (!std.mem.startsWith(u8, url, self.base_url)) return refusal(arena, 400, "InvalidRequestUri", "The request URI is not this ARM's.");
        const rest = url[self.base_url.len..];
        const q = std.mem.indexOfScalar(u8, rest, '?');
        const path = rest[0 .. q orelse rest.len];
        const query = if (q) |i| rest[i + 1 ..] else "";
        if (try param(arena, query, "api-version") == null) {
            return refusal(arena, 400, "MissingApiVersionParameter", "The api-version query parameter (?api-version=) is required for all requests.");
        }
        var segments: [8][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |s| : (count += 1) {
            if (count == segments.len) return notFound(arena);
            segments[count] = s;
        }
        return self.route(arena, method, path, query, segments[0..count], body);
    }

    fn route(self: *FakeResources, arena: Allocator, method: wire.Method, path: []const u8, query: []const u8, s: []const []const u8, body: ?[]const u8) Allocator.Error!Answer {
        if (s.len == 0 or !eql(s[0], "subscriptions")) return notFound(arena);
        if (s.len == 1) return if (method == .GET) self.listSubscriptions(arena, path, query) else notFound(arena);
        const sub = self.findSubscription(s[1]) orelse
            return refusal(arena, 404, "SubscriptionNotFound", try std.fmt.allocPrint(arena, "The subscription '{s}' could not be found.", .{s[1]}));
        if (s.len == 3 and eql(s[2], "resourcegroups") and method == .GET) return self.listGroups(arena, sub, path, query);
        if (s.len == 4 and eql(s[2], "resourcegroups")) return self.groupCall(arena, sub, method, s[3], body);
        if (s.len == 4 and eql(s[2], "operationresults") and method == .GET) return self.pollDeletion(arena, s[3]);
        if (s.len == 4 and eql(s[2], "providers") and method == .GET) return self.provider(arena, sub, s[3], false);
        if (s.len == 5 and eql(s[2], "providers") and eql(s[4], "register") and method == .POST) return self.provider(arena, sub, s[3], true);
        return notFound(arena);
    }

    fn groupCall(self: *FakeResources, arena: Allocator, sub: *Subscription, method: wire.Method, name: []const u8, body: ?[]const u8) Allocator.Error!Answer {
        return switch (method) {
            .PUT => self.putGroup(arena, sub, name, body orelse ""),
            .GET => if (self.findGroup(sub.id, name)) |g| .{ .body = try groupJson(arena, sub.id, g.*) } else groupNotFound(arena, name),
            .DELETE => self.deleteGroup(arena, sub, name),
            else => notFound(arena),
        };
    }

    fn putGroup(self: *FakeResources, arena: Allocator, sub: *Subscription, name: []const u8, body: []const u8) Allocator.Error!Answer {
        const Spec = struct { location: ?[]const u8 = null, tags: ?std.json.ArrayHashMap([]const u8) = null };
        const spec = std.json.parseFromSliceLeaky(Spec, arena, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
            return refusal(arena, 400, "InvalidRequestContent", "The request content was invalid and could not be deserialized.");
        const location = spec.location orelse return refusal(arena, 400, "LocationRequired", "The location property is required for this definition.");
        var tags: []Tag = &.{};
        if (spec.tags) |m| {
            tags = try arena.alloc(Tag, m.map.count());
            for (m.map.keys(), m.map.values(), tags) |k, v, *t| t.* = .{ .name = k, .value = v };
        }
        if (self.findGroup(sub.id, name)) |g| {
            if (g.deleting) return refusal(arena, 409, "ResourceGroupBeingDeleted", try std.fmt.allocPrint(arena, "The resource group '{s}' is in deprovisioning state and cannot perform this operation.", .{g.name}));
            if (!std.ascii.eqlIgnoreCase(g.location, location)) {
                return refusal(arena, 409, "InvalidResourceGroupLocation", try std.fmt.allocPrint(arena, "Invalid resource group location '{s}'. The Resource group already exists in location '{s}'.", .{ location, g.location }));
            }
            g.* = try self.copyGroup(.{ .name = g.name, .location = g.location, .tags = tags, .managed_by = g.managed_by });
            return .{ .body = try groupJson(arena, sub.id, g.*) };
        }
        try sub.groups.append(self.arena.allocator(), try self.copyGroup(.{ .name = name, .location = location, .tags = tags }));
        return .{ .status = 201, .body = try groupJson(arena, sub.id, sub.groups.items[sub.groups.items.len - 1]) };
    }

    fn deleteGroup(self: *FakeResources, arena: Allocator, sub: *Subscription, name: []const u8) Allocator.Error!Answer {
        const g = self.findGroup(sub.id, name) orelse return groupNotFound(arena, name);
        g.deleting = true;
        const a = self.arena.allocator();
        const id = try std.fmt.allocPrint(a, "op-{d}", .{self.next_id});
        self.next_id += 1;
        try self.deletions.append(a, .{ .id = id, .subscription = sub.id, .group = g.name, .polls_left = self.delete_polls });
        return self.accepted(arena, sub.id, id);
    }

    fn pollDeletion(self: *FakeResources, arena: Allocator, id: []const u8) Allocator.Error!Answer {
        for (self.deletions.items) |*d| {
            if (!std.mem.eql(u8, d.id, id)) continue;
            if (d.polls_left > 0) {
                d.polls_left -= 1;
                return self.accepted(arena, d.subscription, d.id);
            }
            self.removeGroup(d.subscription, d.group);
            return .{ .body = "" };
        }
        return notFound(arena);
    }

    fn removeGroup(self: *FakeResources, subscription: []const u8, name: []const u8) void {
        const sub = self.findSubscription(subscription) orelse return;
        for (sub.groups.items, 0..) |g, i| {
            if (std.ascii.eqlIgnoreCase(g.name, name)) {
                _ = sub.groups.orderedRemove(i);
                return;
            }
        }
    }

    fn accepted(self: *FakeResources, arena: Allocator, subscription: []const u8, id: []const u8) Allocator.Error!Answer {
        const location = try std.fmt.allocPrint(arena, "{s}/subscriptions/{s}/operationresults/{s}?api-version=2021-04-01", .{ self.base_url, subscription, id });
        const headers = try arena.dupe(Header, &.{ .{ .name = "Location", .value = location }, .{ .name = "Retry-After", .value = self.retry_after } });
        return .{ .status = 202, .headers = headers };
    }

    fn provider(self: *FakeResources, arena: Allocator, sub: *Subscription, namespace: []const u8, register: bool) Allocator.Error!Answer {
        _ = self;
        for (sub.providers.items) |*p| {
            if (!std.ascii.eqlIgnoreCase(p.namespace, namespace)) continue;
            // A registration asked for finishes by the next read.
            if (register and !eql(p.state, "Registered")) {
                p.state = "Registering";
            } else if (!register and eql(p.state, "Registering")) {
                p.state = "Registered";
            }
            return .{ .body = try jsonOf(arena, .{
                .id = try std.fmt.allocPrint(arena, "/subscriptions/{s}/providers/{s}", .{ sub.id, p.namespace }),
                .namespace = p.namespace,
                .registrationState = p.state,
            }) };
        }
        return refusal(arena, 404, "InvalidResourceNamespace", try std.fmt.allocPrint(arena, "The resource namespace '{s}' is invalid.", .{namespace}));
    }

    fn listSubscriptions(self: *FakeResources, arena: Allocator, path: []const u8, query: []const u8) Allocator.Error!Answer {
        const start = try skipToken(arena, query);
        const items = self.subscriptions.items;
        const end = @min(items.len, start + self.page_size);
        var w: std.Io.Writer.Allocating = .init(arena);
        w.writer.writeAll("{\"value\":") catch return error.OutOfMemory;
        var jw: std.json.Stringify = .{ .writer = &w.writer };
        writeSubscriptionPage(&jw, items[@min(start, items.len)..end]) catch return error.OutOfMemory;
        return self.page(&w, path, query, end < items.len, end);
    }

    fn listGroups(self: *FakeResources, arena: Allocator, sub: *Subscription, path: []const u8, query: []const u8) Allocator.Error!Answer {
        var filter: ?Filter = null;
        if (try param(arena, query, "$filter")) |text| {
            filter = parseFilter(arena, text) catch
                return refusal(arena, 400, "InvalidFilterInQueryString", "Invalid $filter: only tagName eq '...' [and tagValue eq '...'] is supported.");
        }
        var matching: std.ArrayList(Group) = .empty;
        for (sub.groups.items) |g| if (filter == null or filter.?.matches(g)) try matching.append(arena, g);
        const start = @min(try skipToken(arena, query), matching.items.len);
        const end = @min(matching.items.len, start + self.page_size);
        var w: std.Io.Writer.Allocating = .init(arena);
        w.writer.writeAll("{\"value\":") catch return error.OutOfMemory;
        var jw: std.json.Stringify = .{ .writer = &w.writer };
        writeGroupPage(&jw, sub.id, matching.items[start..end]) catch return error.OutOfMemory;
        return self.page(&w, path, query, end < matching.items.len, end);
    }

    /// Ends a page's JSON: the `nextLink` when more follows, which repeats
    /// the request's query with the next `$skiptoken`.
    fn page(self: *FakeResources, w: *std.Io.Writer.Allocating, path: []const u8, query: []const u8, more: bool, next: usize) Allocator.Error!Answer {
        if (more) {
            const kept = query[0 .. std.mem.indexOf(u8, query, "&%24skiptoken=") orelse query.len];
            w.writer.print(",\"nextLink\":\"{s}{s}?{s}&%24skiptoken={d}\"", .{ self.base_url, path, kept, next }) catch return error.OutOfMemory;
        }
        w.writer.writeByte('}') catch return error.OutOfMemory;
        return .{ .body = w.written() };
    }

    // Bodies.

    /// The `value` array of a page; the caller has written `{"value":`.
    fn writeSubscriptionPage(jw: *std.json.Stringify, items: []const Subscription) std.json.Stringify.Error!void {
        try jw.beginArray();
        for (items) |s| try jw.write(.{
            .id = s.id,
            .subscriptionId = s.id,
            .tenantId = s.tenant_id,
            .displayName = s.display_name,
            .state = s.state,
        });
        try jw.endArray();
    }

    /// The `value` array of a page; the caller has written `{"value":`.
    fn writeGroupPage(jw: *std.json.Stringify, subscription: []const u8, items: []const Group) std.json.Stringify.Error!void {
        try jw.beginArray();
        for (items) |g| try writeGroup(jw, subscription, g);
        try jw.endArray();
    }

    fn groupJson(arena: Allocator, subscription: []const u8, g: Group) Allocator.Error![]const u8 {
        var w: std.Io.Writer.Allocating = .init(arena);
        var jw: std.json.Stringify = .{ .writer = &w.writer };
        writeGroup(&jw, subscription, g) catch return error.OutOfMemory;
        return w.written();
    }

    fn writeGroup(jw: *std.json.Stringify, subscription: []const u8, g: Group) std.json.Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("id");
        try jw.print("\"/subscriptions/{s}/resourceGroups/{s}\"", .{ subscription, g.name });
        try jw.objectField("name");
        try jw.write(g.name);
        try jw.objectField("type");
        try jw.write("Microsoft.Resources/resourceGroups");
        try jw.objectField("location");
        try jw.write(g.location);
        if (g.managed_by) |m| {
            try jw.objectField("managedBy");
            try jw.write(m);
        }
        try jw.objectField("tags");
        try jw.beginObject();
        for (g.tags) |t| {
            try jw.objectField(t.name);
            try jw.write(t.value);
        }
        try jw.endObject();
        try jw.objectField("properties");
        try jw.write(.{ .provisioningState = if (g.deleting) "Deleting" else "Succeeded" });
        try jw.endObject();
    }

    fn jsonOf(arena: Allocator, value: anytype) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(value, .{})});
    }

    fn refusal(arena: Allocator, status: u16, code: []const u8, message: []const u8) Allocator.Error!Answer {
        const headers = try arena.dupe(Header, &.{
            .{ .name = "x-ms-request-id", .value = "fa4e0000-0000-4000-8000-000000000001" },
            .{ .name = "x-ms-correlation-request-id", .value = "fa4e0000-0000-4000-8000-000000000002" },
        });
        return .{ .status = status, .headers = headers, .body = try jsonOf(arena, .{ .@"error" = .{ .code = code, .message = message } }) };
    }

    fn notFound(arena: Allocator) Allocator.Error!Answer {
        return refusal(arena, 404, "NotFound", "The fake answers only the resources module's calls.");
    }

    fn groupNotFound(arena: Allocator, name: []const u8) Allocator.Error!Answer {
        return refusal(arena, 404, "ResourceGroupNotFound", try std.fmt.allocPrint(arena, "Resource group '{s}' could not be found.", .{name}));
    }

    // Queries.

    /// A query parameter's value, percent-decoded, matched by name without
    /// regard to case; null when the query has none.
    fn param(arena: Allocator, query: []const u8, name: []const u8) Allocator.Error!?[]const u8 {
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
            const key = std.Uri.percentDecodeInPlace(try arena.dupe(u8, pair[0..eq]));
            if (!std.ascii.eqlIgnoreCase(key, name)) continue;
            const raw = if (eq < pair.len) pair[eq + 1 ..] else "";
            return std.Uri.percentDecodeInPlace(try arena.dupe(u8, raw));
        }
        return null;
    }

    fn skipToken(arena: Allocator, query: []const u8) Allocator.Error!usize {
        const text = try param(arena, query, "$skiptoken") orelse return 0;
        return std.fmt.parseInt(usize, text, 10) catch 0;
    }

    const Filter = struct {
        name: []const u8,
        value: ?[]const u8,

        fn matches(f: Filter, g: Group) bool {
            const v = g.tag(f.name) orelse return false;
            return if (f.value) |want| std.mem.eql(u8, v, want) else true;
        }
    };

    /// `tagName eq '<name>'`, and ` and tagValue eq '<value>'` after it.
    fn parseFilter(arena: Allocator, text: []const u8) error{ OutOfMemory, InvalidFilter }!Filter {
        var rest = text;
        const name = try odataAfter(arena, &rest, "tagName eq ");
        if (rest.len == 0) return .{ .name = name, .value = null };
        const value = try odataAfter(arena, &rest, " and tagValue eq ");
        if (rest.len != 0) return error.InvalidFilter;
        return .{ .name = name, .value = value };
    }

    /// The OData string literal after `prefix`, its doubled quotes made one.
    fn odataAfter(arena: Allocator, rest: *[]const u8, prefix: []const u8) error{ OutOfMemory, InvalidFilter }![]const u8 {
        if (!std.mem.startsWith(u8, rest.*, prefix)) return error.InvalidFilter;
        var s = rest.*[prefix.len..];
        if (s.len == 0 or s[0] != '\'') return error.InvalidFilter;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 1;
        while (i < s.len) : (i += 1) {
            if (s[i] != '\'') {
                try out.append(arena, s[i]);
            } else if (i + 1 < s.len and s[i + 1] == '\'') {
                try out.append(arena, '\'');
                i += 1;
            } else {
                s = s[i + 1 ..];
                rest.* = s;
                return out.items;
            }
        }
        return error.InvalidFilter;
    }

    fn eql(a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }
};
