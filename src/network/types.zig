//! What the network module reads and writes.

const std = @import("std");
const core = @import("core");

pub const Owned = core.Owned;
/// A name and value ARM keeps on a resource: core's, as the resources
/// module's are.
pub const Tag = core.arm.Tag;

/// A subnet to make, on its own (`beginCreateSubnet`) or in its network's
/// spec. A create makes the subnet exactly this: what it leaves out, it
/// takes away.
pub const SubnetSpec = struct {
    /// The subnet's range, a CIDR inside one of its network's, such as
    /// `10.0.1.0/24`. Azure keeps five addresses of each subnet.
    address_prefix: []const u8,
    /// Whether the subnet's VMs reach the internet with nothing else
    /// arranged: Azure's default outbound access. Always sent, since its
    /// default changes with the api-version (private on those after
    /// 2026-03-31). False makes a private subnet, whose VMs still reach
    /// Storage in their own region and the instance metadata service; the
    /// rest of the internet needs a NAT gateway (`nat_gateway`), a public
    /// IP or a firewall. A change reaches a running VM only after it is
    /// stopped and deallocated.
    default_outbound_access: bool = false,
    /// Service endpoints, such as `Microsoft.Storage`: the subnet's traffic
    /// to the service stays on Azure's network, and the service's firewall
    /// can admit the subnet by name.
    service_endpoints: []const []const u8 = &.{},
    /// The ARM id of the network security group applied to the subnet, as
    /// `ids.securityGroup` writes it; null for none.
    security_group: ?[]const u8 = null,
    /// The ARM id of a NAT gateway for the subnet's outbound traffic; null
    /// for none.
    nat_gateway: ?[]const u8 = null,
};

/// A subnet in a network's spec.
pub const NamedSubnet = struct {
    name: []const u8,
    spec: SubnetSpec,
};

/// A virtual network to make. A create makes the network exactly this.
pub const VirtualNetworkSpec = struct {
    location: []const u8,
    /// The network's ranges, CIDRs such as `10.0.0.0/16`.
    address_prefixes: []const []const u8,
    /// The network's subnets, always sent: once the create ends the network
    /// has these and no others. A subnet there already and not named here
    /// is deleted, and while anything uses it the create fails
    /// (`InUseSubnetCannotBeDeleted`).
    subnets: []const NamedSubnet = &.{},
    tags: []const Tag = &.{},
};

/// A service endpoint on a subnet, as Azure set it up.
pub const ServiceEndpoint = struct {
    service: []const u8,
    /// The regions it reaches the service in, as Azure chose them.
    locations: []const []const u8,
    provisioning_state: []const u8,
};

pub const Subnet = struct {
    name: []const u8,
    /// The full ARM id, what a VM's network interface names
    /// (`/subscriptions/{s}/resourceGroups/{g}/providers/Microsoft.Network/virtualNetworks/{v}/subnets/{name}`).
    id: []const u8,
    /// Its ranges: ARM's `addressPrefix` and `addressPrefixes` together.
    address_prefixes: []const []const u8,
    /// `Succeeded` when usable, `Updating` while a write runs.
    provisioning_state: []const u8,
    /// As ARM says it; null when it says nothing, as on networks made with
    /// older api-versions, where default outbound access is on.
    default_outbound_access: ?bool,
    service_endpoints: []const ServiceEndpoint,
    /// The ARM id of its network security group, if it has one.
    security_group: ?[]const u8,
    /// The ARM id of its NAT gateway, if it has one.
    nat_gateway: ?[]const u8,
    /// How many network interfaces' IP configurations are in it. A subnet
    /// in use cannot be deleted.
    ip_configurations: usize,

    /// Whether its VMs have default outbound access: true when ARM says so,
    /// or says nothing.
    pub fn defaultOutbound(subnet: Subnet) bool {
        return subnet.default_outbound_access orelse true;
    }

    /// Whether it has a service endpoint for `service`, such as
    /// `Microsoft.Storage`, matched without regard to case.
    pub fn hasEndpoint(subnet: Subnet, service: []const u8) bool {
        for (subnet.service_endpoints) |e| if (std.ascii.eqlIgnoreCase(e.service, service)) return true;
        return false;
    }
};

pub const VirtualNetwork = struct {
    name: []const u8,
    /// The full ARM id.
    id: []const u8,
    location: []const u8,
    /// `Succeeded` when usable, `Updating` while a write runs.
    provisioning_state: []const u8,
    address_prefixes: []const []const u8,
    subnets: []const Subnet,
    tags: []const Tag,

    /// The value of the tag named `name`, matched without regard to case.
    pub fn tag(network: VirtualNetwork, name: []const u8) ?[]const u8 {
        return core.arm.findTag(network.tags, name);
    }

    /// The subnet named `name`, matched without regard to case, as ARM
    /// matches names; null when there is none.
    pub fn subnet(network: VirtualNetwork, name: []const u8) ?Subnet {
        for (network.subnets) |s| if (std.ascii.eqlIgnoreCase(s.name, name)) return s;
        return null;
    }
};

/// One rule of a network security group: which traffic it allows or
/// denies. Of the rules a packet matches, the one with the lowest priority
/// number decides.
pub const SecurityRule = struct {
    name: []const u8,
    /// 100 to 4096, unique among the group's rules of one direction.
    /// Azure's default rules sit below, at 65000 and over.
    priority: u16,
    direction: Direction,
    access: Access,
    protocol: Protocol = .any,
    /// Each `*`, an address or CIDR, or a service tag such as `Internet`,
    /// `VirtualNetwork` or `Storage.EastUS2`. At least one.
    source_address_prefixes: []const []const u8 = &.{"*"},
    /// Each `*`, a port, or a range `low-high`. At least one.
    source_port_ranges: []const []const u8 = &.{"*"},
    destination_address_prefixes: []const []const u8 = &.{"*"},
    destination_port_ranges: []const []const u8 = &.{"*"},
    /// Up to 140 bytes.
    description: []const u8 = "",

    pub const Direction = enum {
        inbound,
        outbound,
        /// A direction this client does not know; a spec may not hold it.
        unknown,

        pub fn wire(d: Direction) []const u8 {
            return switch (d) {
                .inbound => "Inbound",
                .outbound => "Outbound",
                .unknown => unreachable,
            };
        }

        pub fn parse(text: []const u8) Direction {
            if (std.ascii.eqlIgnoreCase(text, "Inbound")) return .inbound;
            if (std.ascii.eqlIgnoreCase(text, "Outbound")) return .outbound;
            return .unknown;
        }
    };

    pub const Access = enum {
        allow,
        deny,
        /// An access this client does not know; a spec may not hold it.
        unknown,

        pub fn wire(a: Access) []const u8 {
            return switch (a) {
                .allow => "Allow",
                .deny => "Deny",
                .unknown => unreachable,
            };
        }

        pub fn parse(text: []const u8) Access {
            if (std.ascii.eqlIgnoreCase(text, "Allow")) return .allow;
            if (std.ascii.eqlIgnoreCase(text, "Deny")) return .deny;
            return .unknown;
        }
    };

    pub const Protocol = enum {
        /// `*`: every protocol.
        any,
        tcp,
        udp,
        icmp,
        esp,
        ah,
        /// A protocol this client does not know; a spec may not hold it.
        unknown,

        const names = [_]struct { []const u8, Protocol }{
            .{ "*", .any },     .{ "Tcp", .tcp }, .{ "Udp", .udp },
            .{ "Icmp", .icmp }, .{ "Esp", .esp }, .{ "Ah", .ah },
        };

        pub fn wire(p: Protocol) []const u8 {
            for (names) |n| if (n[1] == p) return n[0];
            unreachable;
        }

        pub fn parse(text: []const u8) Protocol {
            for (names) |n| if (std.ascii.eqlIgnoreCase(text, n[0])) return n[1];
            return .unknown;
        }
    };
};

/// A network security group to make. A create makes the group exactly
/// this: its rules become the spec's.
pub const SecurityGroupSpec = struct {
    location: []const u8,
    /// Applied above Azure's default rules, which allow traffic within the
    /// virtual network and from Azure's load balancer, deny all other
    /// inbound traffic, and allow outbound traffic to the network and the
    /// internet.
    rules: []const SecurityRule = &.{},
    tags: []const Tag = &.{},
};

pub const SecurityGroup = struct {
    name: []const u8,
    /// The full ARM id, what `SubnetSpec.security_group` takes.
    id: []const u8,
    location: []const u8,
    provisioning_state: []const u8,
    rules: []const SecurityRule,
    /// Azure's own rules, below every one of `rules`.
    default_rules: []const SecurityRule,
    /// The ARM ids of the subnets it applies to. A group that applies to
    /// any cannot be deleted.
    subnets: []const []const u8,
    tags: []const Tag,

    /// The value of the tag named `name`, matched without regard to case.
    pub fn tag(group: SecurityGroup, name: []const u8) ?[]const u8 {
        return core.arm.findTag(group.tags, name);
    }

    /// The rule named `name`, matched without regard to case; null when
    /// there is none.
    pub fn rule(group: SecurityGroup, name: []const u8) ?SecurityRule {
        for (group.rules) |r| if (std.ascii.eqlIgnoreCase(r.name, name)) return r;
        return null;
    }
};
