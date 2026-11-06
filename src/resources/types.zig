//! What the resources module reads and writes.

const std = @import("std");
const core = @import("core");

pub const Owned = core.Owned;

/// A subscription the credential can see.
pub const Subscription = struct {
    /// Its GUID, as the paths take it.
    id: []const u8,
    display_name: []const u8,
    tenant_id: []const u8,
    state: State,

    pub const State = enum {
        enabled,
        /// Past due, or over a spending limit: still readable, soon disabled.
        warned,
        past_due,
        disabled,
        deleted,
        /// A state this client does not know.
        unknown,

        pub fn parse(text: []const u8) State {
            const names = [_]struct { []const u8, State }{
                .{ "Enabled", .enabled },  .{ "Warned", .warned },
                .{ "PastDue", .past_due }, .{ "Disabled", .disabled },
                .{ "Deleted", .deleted },
            };
            for (names) |n| if (std.ascii.eqlIgnoreCase(text, n[0])) return n[1];
            return .unknown;
        }
    };
};

/// A name and value ARM keeps on a resource.
pub const Tag = struct {
    name: []const u8,
    value: []const u8,
};

pub const ResourceGroup = struct {
    name: []const u8,
    /// The full ARM id, `/subscriptions/{id}/resourceGroups/{name}`.
    id: []const u8,
    location: []const u8,
    /// `Succeeded` when usable, `Deleting` while a delete runs.
    provisioning_state: []const u8,
    tags: []const Tag,
    /// The resource that manages the group, when one does (a managed
    /// application, an AKS cluster's node group); such a group is not the
    /// caller's to delete.
    managed_by: ?[]const u8,

    /// The value of the tag named `name`, matched as ARM matches tag names,
    /// without regard to case; null when the group has none.
    pub fn tag(group: ResourceGroup, name: []const u8) ?[]const u8 {
        for (group.tags) |t| if (std.ascii.eqlIgnoreCase(t.name, name)) return t.value;
        return null;
    }
};

/// A resource group to make: where, and with which tags.
pub const GroupSpec = struct {
    location: []const u8,
    tags: []const Tag = &.{},
};

/// What `createResourceGroup` answers: the group, and whether this call
/// made it (201) rather than finding it there already (200), its tags then
/// replaced by the spec's.
pub const CreatedGroup = struct {
    group: ResourceGroup,
    created: bool,
};

/// A resource provider, as a subscription sees it.
pub const Provider = struct {
    namespace: []const u8,
    registration_state: RegistrationState,

    pub const RegistrationState = enum {
        registered,
        registering,
        not_registered,
        unregistering,
        unknown,

        pub fn parse(text: []const u8) RegistrationState {
            const names = [_]struct { []const u8, RegistrationState }{
                .{ "Registered", .registered },        .{ "Registering", .registering },
                .{ "NotRegistered", .not_registered }, .{ "Unregistering", .unregistering },
            };
            for (names) |n| if (std.ascii.eqlIgnoreCase(text, n[0])) return n[1];
            return .unknown;
        }
    };
};

/// Which resource groups `listResourceGroups` returns: those with a tag of
/// this name, and when `value` is set, that value.
pub const TagFilter = struct {
    name: []const u8,
    value: ?[]const u8 = null,
};

pub const DeleteOptions = struct {
    /// Delete the group's virtual machines and scale sets without shutting
    /// them down first (`forceDeletionTypes`), as a spot worker's group is.
    force_vms: bool = false,
};
