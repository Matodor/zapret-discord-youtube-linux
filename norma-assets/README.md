# norma-assets persistent transport

This directory contains the persistent selective-routing configuration:

`application -> wg-assets -> wstunnel WSS -> Cloudflare Tunnel -> Contabo`.

The dedicated outer WSS connection uses socket mark `0x20000000` and NFQUEUE
221. Generated desynchronization packets use `0x40000000`, bypassing the stock
zapret queue 220. `--bind-fix4` is required so generated IPv4 packets leave
through the physical interface selected by policy routing.

## Static networks

The client `AllowedIPs` and the server nftables set
`norma_assets_targets_v4` must contain the same static destination networks.
The versioned server source of truth is
[`server/norma-assets.nft`](server/norma-assets.nft).

Merge the versioned static CIDR list into `/etc/wireguard/wg-assets.conf` with:

```bash
sudo bash norma-assets/add-allowed-ips.sh
```

After changing static CIDRs, update `server/norma-assets.nft`, install it on
Contabo, and then reinstall/restart the client. A client-only `AllowedIPs`
change is intentionally blocked by the server firewall.

## Dynamic domains

Edit [`domains.txt`](domains.txt) to route domain names through WireGuard:

```text
chatgpt.com
auth.openai.com
cdn.oaistatic.com
files.oaiusercontent.com
```

Use one exact hostname per line. Blank lines and `#` comments are accepted;
wildcards are not, because DNS cannot enumerate all names below a wildcard.

`norma-assets-domains.path` reacts to file changes, and
`norma-assets-domains.timer` refreshes records every five minutes. The updater
unions current A records from local DNSCrypt and the systemd-resolved
application lookup used by software such as Node.js. Each application lookup
has a five-second timeout, so one unresponsive name cannot block the complete
refresh. This covers
resolver-dependent CDN/load-balancer answers, including differences between
AF_INET and AF_UNSPEC lookups. It represents each answer as an exact `/32` CIDR
and transactionally synchronizes:

1. the WireGuard peer runtime `AllowedIPs`;
2. routes in table `51820`;
3. the Contabo nftables set `norma_assets_dynamic_v4`.

Exact `/32` routes are deliberate. Expanding a CDN hostname to a provider ASN
would route large unrelated networks through the tunnel. If DNS temporarily
fails, the updater keeps the last known addresses from
`/var/lib/norma-assets/domains-v4.tsv`. When a rotating DNS answer replaces an
address, the old `/32` is retained for 24 hours. This grace period keeps
long-lived HTTP/2 and WebSocket connections on WireGuard instead of moving
their destination back to the physical default route mid-connection. The state
file stores `domain`, IPv4 address, and its last DNS confirmation timestamp.

Run an immediate refresh and inspect it with:

```bash
sudo systemctl start norma-assets-domains.service
sudo journalctl -u norma-assets-domains.service -n 30 --no-pager
systemctl status norma-assets-domains.path norma-assets-domains.timer --no-pager
```

The service uses the `contabo-ai` entry from
`/home/matodor/.ssh/config`; the remote account must allow passwordless
`sudo -n /usr/local/sbin/norma-assets-update-dynamic-targets`.

## DNS

DNSCrypt DoH endpoints are routed through WireGuard. On every `wg-assets`
start, `dnscrypt-proxy` is restarted after the tunnel path is available and
the resolver cache is flushed. The refresh hook waits up to 90 seconds for the
local DNSCrypt listener to return an A record, preventing a transient boot race
from leaving `wg-quick@wg-assets.service` failed with only static routes
installed. During installation, the Amnezia-only bootstrap resolver
`172.29.172.254` is replaced with `1.1.1.1` and `9.9.9.9`; rollback restores the
original configuration.

## Installation

Install the server nftables template and dynamic-target helper first:

```bash
scp -F ~/.ssh/config -r norma-assets/server contabo-ai:/tmp/norma-assets-server
ssh -F ~/.ssh/config contabo-ai \
  'sudo bash /tmp/norma-assets-server/install.sh'
```

Then install the client:

```bash
SUDO_ASKPASS="$PWD/.norma-assets-askpass" \
  sudo -A bash norma-assets/install.sh
```

The client installer verifies DNS, static and dynamic routes, service restart
resilience, and representative downloads. It prints the exact rollback command
and stores its backup under `/root/norma-assets-bindfix-backup-*`. The generic
rollback helper remains installed so recovery can be repeated if necessary:

```bash
sudo /usr/local/sbin/norma-assets-bindfix-rollback \
  /root/norma-assets-bindfix-backup-YYYYMMDD-HHMMSS
```

## Useful checks

```bash
systemctl status \
  norma-assets-routing.service \
  norma-assets-nfqws.service \
  wstunnel-assets-client.service \
  wg-quick@wg-assets.service \
  norma-assets-domains.path \
  norma-assets-domains.timer \
  --no-pager
sudo wg show wg-assets
ip -4 rule show
ip -4 route show table 51820
dig +short A chatgpt.com @127.0.0.1 -p 5300
curl -4 --interface wg-assets -I https://chatgpt.com/
ssh -F ~/.ssh/config contabo-ai \
  'sudo nft list set ip norma_assets norma_assets_dynamic_v4'
```
