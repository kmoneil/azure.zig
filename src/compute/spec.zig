//! What a VM is made from. A `VmSpec` is checked before anything is sent
//! and written as the body Compute's create takes, in the shape t19's m0
//! made spot VMs with on 2026-11-07: Spot, evicted by deletion, an
//! ephemeral OS disk, Trusted Launch, SSH keys and no password, and a NIC
//! made with the VM and deleted with it.

const std = @import("std");
const core = @import("core");
const types = @import("types.zig");

const Stringify = std.json.Stringify;

pub const VmSpec = struct {
    location: []const u8,
    /// A size's name, as `Size.name` gives it: `Standard_D2ds_v5`.
    size: []const u8,
    /// A logical zone, as `Size.zones` gives them; null: a VM in no zone.
    zone: ?[]const u8 = null,
    priority: Priority = .{ .spot = .{} },
    image: Image = .ubuntu_24_04,
    /// Ephemeral on the resource disk by default, as v5's `ds` sizes take
    /// it; `Size.ephemeralPlacement` says where one goes on another size.
    os_disk: OsDisk = .{ .ephemeral = .resource_disk },
    /// Null: the size's default. `Size.diskController` says what to name:
    /// NVMe for a size that takes it alone, as v6's and v7's do.
    disk_controller: ?types.DiskController = null,
    /// Trusted Launch by default, named outright (the plan's decision 4).
    security: Security = .trusted_launch,
    /// The admin account: up to 64 of letters, digits and `_.-`, beginning
    /// with a letter or `_`, and none of the names Azure refuses (`root`,
    /// `admin`, `test`...).
    admin_username: []const u8,
    /// OpenSSH public keys, one at least: password sign-in is off.
    ssh_public_keys: []const []const u8,
    /// The host name: 1 to 64 letters, digits and hyphens. Null: the VM's
    /// name, which must then be one.
    computer_name: ?[]const u8 = null,
    /// What cloud-init reads on first boot, up to 65535 bytes, sent as
    /// base64. Fixed once the VM is made, and readable on it: Azure
    /// advises against secrets in it, and a preview carries it.
    custom_data: []const u8 = "",
    /// What the VM reads from IMDS, up to 65535 bytes, sent as base64.
    user_data: []const u8 = "",
    nic: Nic,
    /// User-assigned managed identities, by ARM id.
    identities: []const []const u8 = &.{},
    /// The VM's tags, which its NIC carries too, so a sweep finds either.
    tags: []const types.Tag = &.{},
    /// A tag only this attempt at the VM carries, such as puffball's
    /// attempt key (the plan's decision 2). A create that meets a VM of
    /// the name already takes it for its own when it carries this tag. It
    /// goes on the VM and its NIC beside `tags`.
    attempt_tag: ?types.Tag = null,
    /// Boot diagnostics in managed storage: the serial log, at no charge.
    boot_diagnostics: bool = true,
};

pub const Priority = union(enum) {
    regular,
    spot: Spot,
};

pub const Spot = struct {
    /// Delete by default: an ephemeral OS disk needs it, and a deallocated
    /// spot VM's cores stay counted against the spot quota.
    eviction_policy: types.EvictionPolicy = .delete,
    /// The most to pay, in US dollars an hour; -1, the default, is the
    /// on-demand price, and no eviction for price.
    max_price: f64 = -1,
};

pub const Image = union(enum) {
    marketplace: Marketplace,
    /// A gallery image version or a managed image, by ARM id.
    id: []const u8,

    /// Canonical's Ubuntu 24.04 LTS, Gen2, amd64. v6's and v7's sizes take
    /// Gen2 images alone.
    pub const ubuntu_24_04: Image = .{ .marketplace = .{ .publisher = "Canonical", .offer = "ubuntu-24_04-lts", .sku = "server" } };
};

pub const Marketplace = struct {
    publisher: []const u8,
    offer: []const u8,
    sku: []const u8,
    version: []const u8 = "latest",
};

pub const OsDisk = union(enum) {
    /// On the host's local storage: no charge, fast, and gone with the
    /// VM. A spot VM with one is evicted by deletion.
    ephemeral: types.EphemeralPlacement,
    managed: Managed,
};

pub const Managed = struct {
    type: StorageType = .standard_lrs,
    /// Null: the image's size, 30 GB for Ubuntu's.
    size_gb: ?u16 = null,
};

pub const StorageType = enum {
    standard_lrs,
    standardssd_lrs,
    standardssd_zrs,
    premium_lrs,
    premium_zrs,

    pub fn wireName(t: StorageType) []const u8 {
        return switch (t) {
            .standard_lrs => "Standard_LRS",
            .standardssd_lrs => "StandardSSD_LRS",
            .standardssd_zrs => "StandardSSD_ZRS",
            .premium_lrs => "Premium_LRS",
            .premium_zrs => "Premium_ZRS",
        };
    }
};

pub const Security = enum {
    /// Secure Boot and a virtual TPM, on a Gen2 image and a size that takes
    /// it (`Size.trusted_launch`).
    trusted_launch,
    standard,
};

pub const Nic = struct {
    /// The subnet's ARM id, as `network.ids.subnet` writes it.
    subnet: []const u8,
    /// Null: the VM's name and `-nic`.
    name: ?[]const u8 = null,
    /// A network security group on the NIC, by ARM id.
    security_group: ?[]const u8 = null,
    accelerated_networking: bool = false,
    /// A Standard public IP named the VM's name and `-ip`, made with the VM
    /// and deleted with it.
    public_ip: bool = false,
};

/// The most bytes `custom_data` and `user_data` each take, before base64.
pub const max_data_len = 65535;
/// The most tags a resource carries, `attempt_tag` among them.
pub const max_tags = 50;

// Checks.

const Refusal = error{InvalidArgument};

/// Refuses, with why in `diagnostics`, a spec Compute would refuse for a
/// VM named `name`, or that would name another resource than it means.
/// `write` takes only what this takes.
pub fn check(spec: VmSpec, name: []const u8, diagnostics: ?*core.Diagnostics) Refusal!void {
    const r: Refuser = .{ .diagnostics = diagnostics };
    // The name goes into the body as the NIC's and the public IP's.
    if (!isVmName(name)) return r.refuse(vm_name_rule, .{});
    if (!core.names.isLocation(spec.location)) return r.refuse("a location is letters and digits, as eastus2", .{});
    if (!isSizeName(spec.size)) return r.refuse("a size is a name of letters, digits and _, as Standard_D2ds_v5", .{});
    if (spec.zone) |z| if (!isZone(z)) return r.refuse("a zone is a logical zone's number, as \"1\"", .{});
    try checkPriority(r, spec);
    try checkDisk(r, spec);
    try checkImage(r, spec.image);
    try checkLogin(r, spec, name);
    if (spec.custom_data.len > max_data_len) return r.refuse("custom_data is {d} bytes; Compute takes {d} at most", .{ spec.custom_data.len, max_data_len });
    if (spec.user_data.len > max_data_len) return r.refuse("user_data is {d} bytes; Compute takes {d} at most", .{ spec.user_data.len, max_data_len });
    try checkNic(r, spec.nic);
    try checkIdentities(r, spec.identities);
    try checkTags(r, spec);
}

const Refuser = struct {
    diagnostics: ?*core.Diagnostics,

    fn refuse(r: Refuser, comptime fmt: []const u8, args: anytype) Refusal {
        if (r.diagnostics) |d| d.print(fmt, args);
        return error.InvalidArgument;
    }
};

fn checkPriority(r: Refuser, spec: VmSpec) Refusal!void {
    const spot = switch (spec.priority) {
        .regular => return,
        .spot => |s| s,
    };
    if (spot.eviction_policy == .unknown) return r.refuse("a spot VM's eviction policy is delete or deallocate", .{});
    if (!(spot.max_price == -1 or (std.math.isFinite(spot.max_price) and spot.max_price > 0))) {
        return r.refuse("a spot VM's max_price is -1, the on-demand price, or dollars an hour above 0", .{});
    }
    if (spec.os_disk == .ephemeral and spot.eviction_policy != .delete) {
        return r.refuse("a spot VM with an ephemeral OS disk is evicted by deletion: its disk cannot outlive it", .{});
    }
}

fn checkDisk(r: Refuser, spec: VmSpec) Refusal!void {
    switch (spec.os_disk) {
        .ephemeral => {},
        .managed => |m| if (m.size_gb) |gb| if (gb == 0 or gb > 4095) return r.refuse("an OS disk is 1 to 4095 GB", .{}),
    }
}

fn checkImage(r: Refuser, image: Image) Refusal!void {
    switch (image) {
        .marketplace => |m| for ([_][]const u8{ m.publisher, m.offer, m.sku, m.version }) |part| {
            if (!isText(part, 256)) return r.refuse("an image's publisher, offer, sku and version are each 1 to 256 bytes, no control bytes", .{});
        },
        .id => |id| if (id.len == 0 or id[0] != '/' or !isText(id, 1024)) return r.refuse("an image id is an ARM id, beginning with /", .{}),
    }
}

fn checkLogin(r: Refuser, spec: VmSpec, name: []const u8) Refusal!void {
    if (!isAdminName(spec.admin_username)) {
        return r.refuse("an admin user is 1 to 64 of letters, digits and _.-, beginning with a letter or _, and not one Azure refuses, as root or admin", .{});
    }
    if (spec.ssh_public_keys.len == 0) return r.refuse("a VM needs one SSH public key at least: password sign-in is off", .{});
    for (spec.ssh_public_keys) |k| if (!isSshKey(k)) return r.refuse("an SSH public key is one OpenSSH line, as ssh-ed25519 AAAA...", .{});
    const host = spec.computer_name orelse name;
    if (!isHostName(host)) {
        if (spec.computer_name == null) return r.refuse("the VM's name {s} is no host name (letters, digits and hyphens): give computer_name", .{name});
        return r.refuse("computer_name is 1 to 64 letters, digits and hyphens, not all digits, with no hyphen at either end", .{});
    }
}

fn checkNic(r: Refuser, nic: Nic) Refusal!void {
    if (!isResourceId(nic.subnet, "Microsoft.Network", &.{ "virtualNetworks", "subnets" })) {
        return r.refuse("nic.subnet is a subnet's ARM id (network.ids.subnet), not its name", .{});
    }
    if (nic.name) |n| if (!isNicName(n)) {
        return r.refuse("a NIC's name is 1 to 80 of letters, digits and .-_, beginning with a letter or digit and ending with one or _", .{});
    };
    if (nic.security_group) |id| if (!isResourceId(id, "Microsoft.Network", &.{"networkSecurityGroups"})) {
        return r.refuse("nic.security_group is a network security group's ARM id, not its name", .{});
    };
}

fn checkIdentities(r: Refuser, ids: []const []const u8) Refusal!void {
    for (ids, 0..) |id, i| {
        if (!isResourceId(id, "Microsoft.ManagedIdentity", &.{"userAssignedIdentities"})) {
            return r.refuse("an identity is a user-assigned identity's ARM id", .{});
        }
        for (ids[0..i]) |earlier| if (std.ascii.eqlIgnoreCase(earlier, id)) return r.refuse("an identity named twice: ARM ids ignore case", .{});
    }
}

fn checkTags(r: Refuser, spec: VmSpec) Refusal!void {
    var all: [max_tags]types.Tag = undefined;
    const extra: usize = if (spec.attempt_tag != null) 1 else 0;
    if (spec.tags.len + extra > max_tags) return r.refuse("a VM carries {d} tags at most, attempt_tag among them", .{max_tags});
    @memcpy(all[0..spec.tags.len], spec.tags);
    if (spec.attempt_tag) |t| all[spec.tags.len] = t;
    if (core.names.tagsProblem(all[0 .. spec.tags.len + extra])) |why| return r.refuse("{s}", .{why});
}

pub const vm_name_rule = "a VM's name is 1 to 64 of letters, digits and .-_, beginning with a letter or digit and ending with one or _";

/// 1 to 64 of letters, digits and `.-_`, beginning with a letter or digit
/// and ending with one or `_`: a Linux VM's name, as it goes in the path.
pub fn isVmName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (!std.ascii.isAlphanumeric(name[0])) return false;
    const last = name[name.len - 1];
    if (!std.ascii.isAlphanumeric(last) and last != '_') return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_')) return false;
    return true;
}

/// A size's name: 1 to 64 of letters, digits and `_`.
fn isSizeName(text: []const u8) bool {
    if (text.len == 0 or text.len > 64) return false;
    for (text) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

/// A logical zone: 1 to 8 letters and digits, as `1`.
fn isZone(text: []const u8) bool {
    if (text.len == 0 or text.len > 8) return false;
    for (text) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    return true;
}

/// 1 to `max` bytes of valid UTF-8, as a JSON body must be, none a
/// control byte.
fn isText(text: []const u8, max: usize) bool {
    if (text.len == 0 or text.len > max or !std.unicode.utf8ValidateSlice(text)) return false;
    for (text) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

/// The names Azure refuses for a Linux admin, as its create documents
/// them; matched without regard to case.
const refused_admins = [_][]const u8{
    "administrator", "admin",   "user",  "user1",            "test",    "user2", "test1",  "user3",
    "admin1",        "1",       "123",   "a",                "actuser", "adm",   "admin2", "aspnet",
    "backup",        "console", "david", "guest",            "john",    "owner", "root",   "server",
    "sql",           "support", "sys",   "support_388945a0", "test2",   "test3", "user4",  "user5",
};

fn isAdminName(text: []const u8) bool {
    if (text.len == 0 or text.len > 64) return false;
    if (!std.ascii.isAlphabetic(text[0]) and text[0] != '_') return false;
    if (text[text.len - 1] == '.') return false;
    for (text) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "_.-", c) == null) return false;
    for (refused_admins) |refused| if (std.ascii.eqlIgnoreCase(text, refused)) return false;
    return true;
}

/// One OpenSSH public key line: its type, a space, and more, with no
/// control byte, so it cannot break the line `authorized_keys` keeps it on.
fn isSshKey(text: []const u8) bool {
    if (!isText(text, 16 * 1024)) return false;
    if (!std.mem.startsWith(u8, text, "ssh-") and !std.mem.startsWith(u8, text, "ecdsa-sha2-")) return false;
    return std.mem.indexOfScalar(u8, text, ' ') != null;
}

/// A host name: 1 to 64 letters, digits and hyphens, not all digits, with
/// no hyphen at either end.
pub fn isHostName(text: []const u8) bool {
    if (text.len == 0 or text.len > 64) return false;
    if (text[0] == '-' or text[text.len - 1] == '-') return false;
    var digits = true;
    for (text) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
        if (!std.ascii.isDigit(c)) digits = false;
    }
    return !digits;
}

/// A NIC's name: as Network's child names, 1 to 80 of letters, digits and
/// `.-_`, beginning with a letter or digit and ending with one or `_`.
fn isNicName(text: []const u8) bool {
    if (text.len == 0 or text.len > 80) return false;
    if (!std.ascii.isAlphanumeric(text[0])) return false;
    const last = text[text.len - 1];
    if (!std.ascii.isAlphanumeric(last) and last != '_') return false;
    for (text) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, ".-_", c) == null) return false;
    return true;
}

/// `/subscriptions/{guid}/resourceGroups/{group}/providers/{namespace}/`
/// then each of `kinds` followed by a name, matched without regard to
/// case, as ARM matches them.
fn isResourceId(id: []const u8, namespace: []const u8, kinds: []const []const u8) bool {
    var it = std.mem.splitScalar(u8, id, '/');
    if (it.next().?.len != 0) return false;
    if (!keyword(it.next(), "subscriptions") or !core.names.isSubscription(it.next() orelse return false)) return false;
    if (!keyword(it.next(), "resourceGroups") or !core.names.isGroupName(it.next() orelse return false)) return false;
    if (!keyword(it.next(), "providers") or !keyword(it.next(), namespace)) return false;
    for (kinds) |kind| {
        if (!keyword(it.next(), kind)) return false;
        if (!isNicName(it.next() orelse return false)) return false;
    }
    return it.next() == null;
}

fn keyword(segment: ?[]const u8, word: []const u8) bool {
    return std.ascii.eqlIgnoreCase(segment orelse return false, word);
}

// The body.

/// The body of the create, from a spec `check` took.
pub fn write(jw: *Stringify, spec: VmSpec, name: []const u8) Stringify.Error!void {
    try jw.beginObject();
    try field(jw, "location", spec.location);
    if (spec.zone) |z| {
        try jw.objectField("zones");
        try jw.write(&[_][]const u8{z});
    }
    try writeTags(jw, spec);
    if (spec.identities.len > 0) {
        try jw.objectField("identity");
        try jw.beginObject();
        try field(jw, "type", "UserAssigned");
        try jw.objectField("userAssignedIdentities");
        try jw.beginObject();
        for (spec.identities) |id| {
            try jw.objectField(id);
            try jw.write(.{});
        }
        try jw.endObject();
        try jw.endObject();
    }
    try jw.objectField("properties");
    try writeProperties(jw, spec, name);
    try jw.endObject();
}

fn writeProperties(jw: *Stringify, spec: VmSpec, name: []const u8) Stringify.Error!void {
    try jw.beginObject();
    switch (spec.priority) {
        .regular => try field(jw, "priority", "Regular"),
        .spot => |s| {
            try field(jw, "priority", "Spot");
            try field(jw, "evictionPolicy", if (s.eviction_policy == .deallocate) "Deallocate" else "Delete");
            try jw.objectField("billingProfile");
            try jw.write(.{ .maxPrice = s.max_price });
        },
    }
    try jw.objectField("hardwareProfile");
    try jw.write(.{ .vmSize = spec.size });
    try jw.objectField("securityProfile");
    switch (spec.security) {
        .trusted_launch => try jw.write(.{ .securityType = "TrustedLaunch", .uefiSettings = .{ .secureBootEnabled = true, .vTpmEnabled = true } }),
        .standard => try jw.write(.{ .securityType = "Standard" }),
    }
    try jw.objectField("storageProfile");
    try writeStorage(jw, spec);
    try jw.objectField("osProfile");
    try writeOsProfile(jw, spec, name);
    if (spec.user_data.len > 0) {
        try jw.objectField("userData");
        try core.base64.writeJsonString(jw, spec.user_data);
    }
    try jw.objectField("networkProfile");
    try writeNetwork(jw, spec, name);
    try jw.objectField("diagnosticsProfile");
    try jw.write(.{ .bootDiagnostics = .{ .enabled = spec.boot_diagnostics } });
    try jw.endObject();
}

fn writeStorage(jw: *Stringify, spec: VmSpec) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("imageReference");
    switch (spec.image) {
        .marketplace => |m| try jw.write(.{ .publisher = m.publisher, .offer = m.offer, .sku = m.sku, .version = m.version }),
        .id => |id| try jw.write(.{ .id = id }),
    }
    try jw.objectField("osDisk");
    try jw.beginObject();
    try field(jw, "createOption", "FromImage");
    try field(jw, "deleteOption", "Delete");
    switch (spec.os_disk) {
        .ephemeral => |placement| {
            try field(jw, "caching", "ReadOnly");
            try jw.objectField("diffDiskSettings");
            try jw.write(.{ .option = "Local", .placement = placement.wireName() });
            // Compute's own example for an ephemeral disk names the type.
            try jw.objectField("managedDisk");
            try jw.write(.{ .storageAccountType = StorageType.standard_lrs.wireName() });
        },
        .managed => |m| {
            try field(jw, "caching", "ReadWrite");
            try jw.objectField("managedDisk");
            try jw.write(.{ .storageAccountType = m.type.wireName() });
            if (m.size_gb) |gb| {
                try jw.objectField("diskSizeGB");
                try jw.write(gb);
            }
        },
    }
    try jw.endObject();
    if (spec.disk_controller) |c| try field(jw, "diskControllerType", c.wireName());
    try jw.endObject();
}

fn writeOsProfile(jw: *Stringify, spec: VmSpec, name: []const u8) Stringify.Error!void {
    try jw.beginObject();
    try field(jw, "computerName", spec.computer_name orelse name);
    try field(jw, "adminUsername", spec.admin_username);
    if (spec.custom_data.len > 0) {
        try jw.objectField("customData");
        try core.base64.writeJsonString(jw, spec.custom_data);
    }
    try jw.objectField("linuxConfiguration");
    try jw.beginObject();
    try jw.objectField("disablePasswordAuthentication");
    try jw.write(true);
    try jw.objectField("ssh");
    try jw.beginObject();
    try jw.objectField("publicKeys");
    try jw.beginArray();
    for (spec.ssh_public_keys) |k| {
        try jw.beginObject();
        try jw.objectField("path");
        try jw.print("\"/home/{s}/.ssh/authorized_keys\"", .{spec.admin_username});
        try field(jw, "keyData", k);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
    try jw.endObject();
    try jw.endObject();
}

/// One NIC, made with the VM and deleted with it, through Network's
/// 2022-11-01 shape, the newest Compute takes for one.
fn writeNetwork(jw: *Stringify, spec: VmSpec, name: []const u8) Stringify.Error!void {
    const nic = spec.nic;
    try jw.beginObject();
    try field(jw, "networkApiVersion", "2022-11-01");
    try jw.objectField("networkInterfaceConfigurations");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("name");
    if (nic.name) |n| try jw.write(n) else try jw.print("\"{s}-nic\"", .{name});
    try writeTags(jw, spec);
    try jw.objectField("properties");
    try jw.beginObject();
    try jw.objectField("primary");
    try jw.write(true);
    try field(jw, "deleteOption", "Delete");
    if (nic.accelerated_networking) {
        try jw.objectField("enableAcceleratedNetworking");
        try jw.write(true);
    }
    if (nic.security_group) |id| {
        try jw.objectField("networkSecurityGroup");
        try jw.write(.{ .id = id });
    }
    try jw.objectField("ipConfigurations");
    try jw.beginArray();
    try jw.beginObject();
    try field(jw, "name", "ipconfig1");
    try jw.objectField("properties");
    try jw.beginObject();
    try jw.objectField("primary");
    try jw.write(true);
    try jw.objectField("subnet");
    try jw.write(.{ .id = nic.subnet });
    if (nic.public_ip) {
        try jw.objectField("publicIPAddressConfiguration");
        try jw.beginObject();
        try jw.objectField("name");
        try jw.print("\"{s}-ip\"", .{name});
        try jw.objectField("sku");
        try jw.write(.{ .name = "Standard" });
        try jw.objectField("properties");
        try jw.write(.{ .deleteOption = "Delete", .publicIPAllocationMethod = "Static" });
        try jw.endObject();
    }
    try jw.endObject();
    try jw.endObject();
    try jw.endArray();
    try jw.endObject();
    try jw.endObject();
    try jw.endArray();
    try jw.endObject();
}

fn writeTags(jw: *Stringify, spec: VmSpec) Stringify.Error!void {
    try jw.objectField("tags");
    try jw.beginObject();
    for (spec.tags) |t| try field(jw, t.name, t.value);
    if (spec.attempt_tag) |t| try field(jw, t.name, t.value);
    try jw.endObject();
}

fn field(jw: *Stringify, name: []const u8, value: []const u8) Stringify.Error!void {
    try jw.objectField(name);
    try jw.write(value);
}

const testing = std.testing;

test "host names, admin names and resource ids" {
    for ([_][]const u8{ "pb-j1-s0", "a", "w1", "x-9" }) |ok| try testing.expect(isHostName(ok));
    for ([_][]const u8{ "", "-a", "a-", "123", "a_b", "a.b", "a b" }) |bad| try testing.expect(!isHostName(bad));
    for ([_][]const u8{ "azzig", "_svc", "pb.worker", "w-1" }) |ok| try testing.expect(isAdminName(ok));
    for ([_][]const u8{ "", "9lives", "Admin", "root", "a.", "a b", "a/b" }) |bad| try testing.expect(!isAdminName(bad));
    const sub = "00000000-0000-4000-8000-0000000000aa";
    try testing.expect(isResourceId("/subscriptions/" ++ sub ++ "/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/v/subnets/s", "Microsoft.Network", &.{ "virtualNetworks", "subnets" }));
    try testing.expect(isResourceId("/SUBSCRIPTIONS/" ++ sub ++ "/resourcegroups/rg/PROVIDERS/microsoft.network/VIRTUALNETWORKS/v/Subnets/s", "Microsoft.Network", &.{ "virtualNetworks", "subnets" }));
    for ([_][]const u8{
        "subscriptions/" ++ sub ++ "/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/v/subnets/s",
        "/subscriptions/" ++ sub ++ "/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/v",
        "/subscriptions/" ++ sub ++ "/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/v/subnets/s/extra",
        "/subscriptions/" ++ sub ++ "/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/../subnets/s",
        "/subscriptions/x/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/v/subnets/s",
        "/subscriptions/" ++ sub ++ "/resourceGroups/rg/providers/Microsoft.Compute/virtualNetworks/v/subnets/s",
    }) |bad| try testing.expect(!isResourceId(bad, "Microsoft.Network", &.{ "virtualNetworks", "subnets" }));
}

test "check: a VM name or text that would break the body out of shape" {
    const spec: VmSpec = .{
        .location = "eastus2",
        .size = "Standard_D2ds_v7",
        .admin_username = "azzig",
        .ssh_public_keys = &.{"ssh-ed25519 AAAA azzig"},
        .computer_name = "host-1",
        .nic = .{ .subnet = "/subscriptions/00000000-0000-4000-8000-0000000000aa/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/v/subnets/s" },
    };
    try check(spec, "w1", null);
    // The name goes into the NIC's name, written as it is.
    try testing.expectError(error.InvalidArgument, check(spec, "w\",\"tags\":[\"x", null));
    var bad = spec;
    bad.ssh_public_keys = &.{"ssh-ed25519 AAAA \xff"};
    try testing.expectError(error.InvalidArgument, check(bad, "w1", null));
    bad = spec;
    bad.image = .{ .marketplace = .{ .publisher = "Canonical", .offer = "ubuntu\xc3", .sku = "server" } };
    try testing.expectError(error.InvalidArgument, check(bad, "w1", null));
}

/// A value for one field: a good one, a good one with a byte of the
/// input put in it, or bytes of the input.
fn fuzzText(g: *core.testing.ByteGen, comptime good: []const []const u8, buf: []u8) []const u8 {
    const base = g.pick([]const u8, good);
    switch (g.intRange(u8, 0, 2)) {
        0 => return base,
        1 => {
            if (base.len + 1 > buf.len) return base;
            const at = g.intRange(usize, 0, base.len);
            @memcpy(buf[0..at], base[0..at]);
            buf[at] = g.byte();
            @memcpy(buf[at + 1 ..][0 .. base.len - at], base[at..]);
            return buf[0 .. base.len + 1];
        },
        else => return g.slice(buf.len),
    }
}

fn specProperty(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g: core.testing.ByteGen = .init(input);
    var bufs: [10][96]u8 = undefined;
    const sub = "00000000-0000-4000-8000-0000000000aa";
    const name = fuzzText(&g, &.{ "w1", "pb-j1-s0", "pb_worker.1" }, &bufs[0]);
    const tag: types.Tag = .{ .name = fuzzText(&g, &.{ "job", "pb-attempt" }, &bufs[1]), .value = fuzzText(&g, &.{ "j1", "", "a \"quoted\" \\ value" }, &bufs[2]) };
    const spec: VmSpec = .{
        .location = fuzzText(&g, &.{"eastus2"}, &bufs[3]),
        .size = fuzzText(&g, &.{ "Standard_D2ds_v7", "Standard_D2s_v5" }, &bufs[4]),
        .zone = if (g.boolean()) fuzzText(&g, &.{ "1", "4" }, &bufs[5]) else null,
        .os_disk = if (g.boolean()) .{ .ephemeral = .nvme_disk } else .{ .managed = .{ .size_gb = g.int(u16) } },
        .admin_username = fuzzText(&g, &.{ "azzig", "_svc" }, &bufs[6]),
        .ssh_public_keys = &.{fuzzText(&g, &.{"ssh-ed25519 AAAAC3Nza azzig@example"}, &bufs[7])},
        .computer_name = if (g.boolean()) fuzzText(&g, &.{"host-1"}, &bufs[8]) else null,
        .custom_data = g.slice(64),
        .nic = .{
            .subnet = "/subscriptions/" ++ sub ++ "/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/v/subnets/s",
            .name = if (g.boolean()) fuzzText(&g, &.{ "w-nic", "nic_0" }, &bufs[9]) else null,
        },
        .attempt_tag = tag,
    };
    check(spec, name, null) catch return;
    var w: std.Io.Writer.Allocating = .init(a);
    var jw: Stringify = .{ .writer = &w.writer };
    try write(&jw, spec, name);
    // What the checks took is JSON, and every name in it reads back as it
    // went in: none broke out of its string.
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, w.written(), .{});
    const props = v.object.get("properties").?.object;
    const os = props.get("osProfile").?.object;
    try testing.expectEqualStrings(spec.computer_name orelse name, os.get("computerName").?.string);
    try testing.expectEqualStrings(spec.admin_username, os.get("adminUsername").?.string);
    const key = os.get("linuxConfiguration").?.object.get("ssh").?.object.get("publicKeys").?.array.items[0].object;
    try testing.expectEqualStrings(spec.ssh_public_keys[0], key.get("keyData").?.string);
    const path = try std.fmt.allocPrint(a, "/home/{s}/.ssh/authorized_keys", .{spec.admin_username});
    try testing.expectEqualStrings(path, key.get("path").?.string);
    const nic = props.get("networkProfile").?.object.get("networkInterfaceConfigurations").?.array.items[0].object;
    const nic_name = spec.nic.name orelse try std.fmt.allocPrint(a, "{s}-nic", .{name});
    try testing.expectEqualStrings(nic_name, nic.get("name").?.string);
    try testing.expectEqualStrings(tag.value, v.object.get("tags").?.object.get(tag.name).?.string);
    if (os.get("customData")) |data| {
        try testing.expectEqualStrings(spec.custom_data, try core.base64.decode(a, data.string));
    } else try testing.expectEqual(0, spec.custom_data.len);
}

test "fuzz spec: what the checks take is JSON, every name in it as it went in" {
    try core.testing.fuzzBytes({}, specProperty, .{
        .random_runs = 2000,
        .corpus = &.{
            "",
            "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
            "\x01\x01\x00\x00\x00\x00\x00\x00\x00\x02\x22\x01\x01\x00\x00\x00\x00\x00\x00\x00\x02\x5c\x00",
            // Found 2026-11-08: a VM name that broke out of the NIC's name, and
            // text that was not UTF-8.
            "\x27\x23\xe5\xcf\x38\x1f\xe8\x93\x3a\xb2\x7e\x2d\xb6\x97\x8f\xae\xc8\x86\x62\x99\xdb\x7c\xb9\xc4\xb6\x02\x00\x36\xb1\x0c\x6a\x0f\x8c\x6d\x87\x4b\xda\xa8\xd8\xaa\x0e\xc2\xb6\x33\x2a\x34\xb0\x43\x77\x3a\x15\xea\xa8\xca\x7d\xdf\xb5\x94\xc4\x00\xdf\x56\x30\xf9\x4d\x39\xe1\x92\x22\x81\xaa\xa0\xcf\x35\x7d\x5a\x7d\x63\xe5\xe2\xc3\x54\x75\x47\xa4\x56\x3d\xf4\x33\x83\xdf\x2d\xb9\xef\x5c\xb5\xb9\xd5\xe1\x98\xd2\x96\x46\x46\xad\xaa\xbe\x62\xb3\xbb\x1d\x60\xcb\x8e\x00\x7a\xba\x8a\x29\x6d\xe1\x18\x20\xc6\x9b\x43\xe7\xd7\x56\x99\xed\x86\xbf\xc1\x90",
        },
    });
}
