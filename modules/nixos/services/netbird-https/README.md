# NetBird HTTPS

Import this module and enable `services.netbird-https`, supplying the peer's
stable NetBird IPv4 address, domain, contact email, loopback upstream port and
an absolute runtime `credentialsFile` for lego's Cloudflare provider.
The credentials must never be embedded in Nix or stored in the Nix store.

Only TLS port 443 is bound, on the supplied address. WebSocket upgrades are
forwarded to loopback. The firewall permits 443 on the configured interface
and drops traffic for the VPN listener arriving on other interfaces in the
raw table, before filter-table accepts. The host must use the iptables
firewall backend. Do not add another wildcard nginx listener on this port.

Name resolution and credential activation belong to the consumer. DNS-01
uses a public resolver, independently of private service-name resolution.
NixOS ACME reloads nginx when certificates change. nginx retries startup if
the peer address is not present yet. ACME's initial self-signed certificate
is not an issuance success; qualify the trusted certificate before pairing.

Loopback probes are allowed. Disable and switch before removing the module
import entirely so the firewall cleanup removes its stable raw-table chain.

The raw guard survives firewall stop and reload. Rule changes replace its
chain atomically with iptables-restore; disabling the module removes it.
