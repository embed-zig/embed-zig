pub const dns = @import("dns.zig");

pub const Ipv4Address = dns.Ipv4Address;
pub const DnsError = dns.DnsError;
pub const Protocol = dns.Protocol;
pub const Servers = dns.Servers;
pub const DohHosts = dns.DohHosts;
pub const ServerLists = dns.ServerLists;
pub const Resolver = dns.Resolver;
pub const ResolverWithTls = dns.ResolverWithTls;
pub const buildQuery = dns.buildQuery;
pub const parseResponse = dns.parseResponse;
pub const formatIpv4 = dns.formatIpv4;
pub const buildHttpRequest = dns.buildHttpRequest;

test {
    _ = dns;
}
