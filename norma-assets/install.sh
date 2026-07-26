#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
    echo "run as root" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly PROJECT_DIR
TS="$(date +%Y%m%d-%H%M%S)"
readonly TS
readonly BACKUP="/root/norma-assets-bindfix-backup-$TS"
readonly OUT="/tmp/norma-assets-bindfix-install-$TS"
readonly STATE_DIR=/var/lib/norma-assets
readonly ROLLBACK_SOURCE="$SCRIPT_DIR/rollback.sh"

mkdir -m 700 "$OUT"
exec > >(tee "$OUT/run.log") 2>&1

echo "install: output=$OUT backup=$BACKUP"

required_files=(
    "$PROJECT_DIR/nfqws"
    "$PROJECT_DIR/zapret-latest/bin/tls_clienthello_www_google_com.bin"
    "$SCRIPT_DIR/domains.txt"
    "$SCRIPT_DIR/libexec/norma-assets-dns-refresh"
    "$SCRIPT_DIR/libexec/norma-assets-update-domains"
    "$SCRIPT_DIR/libexec/norma-assets-routing"
    "$SCRIPT_DIR/libexec/norma-assets-nfqws-firewall"
    "$SCRIPT_DIR/systemd/norma-assets-domains.service"
    "$SCRIPT_DIR/systemd/norma-assets-domains.path"
    "$SCRIPT_DIR/systemd/norma-assets-domains.timer"
    "$SCRIPT_DIR/systemd/norma-assets-routing.service"
    "$SCRIPT_DIR/systemd/norma-assets-nfqws.service"
    "$SCRIPT_DIR/systemd/wstunnel-assets-client.service"
    "$SCRIPT_DIR/systemd/wg-quick@wg-assets.service.d/wstunnel.conf"
    "$ROLLBACK_SOURCE"
    /etc/dnscrypt-proxy/dnscrypt-proxy.toml
    /etc/wstunnel/assets-client.env
    /etc/wireguard/wg-assets.conf
)
for required in "${required_files[@]}"; do
    [[ -f $required ]] || {
        echo "required file not found: $required" >&2
        exit 2
    }
done

[[ $(systemctl is-active AmneziaVPN.service 2>/dev/null || true) == active ]] || {
    echo "AmneziaVPN.service must be active before cutover" >&2
    exit 2
}
[[ $(systemctl is-active wg-quick@wg-assets.service 2>/dev/null || true) != active ]] || {
    echo "wg-assets must be inactive before install" >&2
    exit 2
}
[[ $(systemctl is-active dnscrypt-proxy.service 2>/dev/null || true) == active ]] || {
    echo "dnscrypt-proxy.service must be active before install" >&2
    exit 2
}
for command_path in \
    /usr/bin/dig \
    /usr/bin/flock \
    /usr/bin/resolvectl \
    /usr/bin/runuser \
    /usr/bin/ssh \
    /usr/bin/wg; do
    [[ -x $command_path ]] || {
        echo "required command not found: $command_path" >&2
        exit 2
    }
done
[[ ! -e /etc/systemd/system/norma-assets-nfqws.service ]] || {
    echo "norma-assets-nfqws.service already exists" >&2
    exit 2
}
if ip -4 rule show | grep -q '^91:'; then
    echo "ip rule preference 91 is already occupied" >&2
    exit 2
fi

SPEED_IP=$(getent ahostsv4 speed.cloudflare.com |
    awk '$2 == "STREAM" {print $1; exit}')
[[ $SPEED_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
    echo "cannot resolve speed.cloudflare.com" >&2
    exit 2
}

runuser -u matodor -- \
    ssh -F /home/matodor/.ssh/config \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    contabo-ai \
    sudo -n /usr/local/sbin/norma-assets-update-dynamic-targets \
        --restore >/dev/null || {
    echo "Contabo dynamic-target helper is unavailable; run norma-assets/server/install.sh there first" >&2
    exit 2
}

install -d -m 700 "$BACKUP/files"
touch "$BACKUP/files-present"

backup_file() {
    local source=$1
    if [[ -e $source || -L $source ]]; then
        install -d -m 700 "$BACKUP/files$(dirname "$source")"
        cp -a -- "$source" "$BACKUP/files$source"
        printf '%s\n' "$source" >>"$BACKUP/files-present"
    fi
}

managed_files=(
    /etc/systemd/system/norma-assets-routing.service
    /etc/systemd/system/norma-assets-nfqws.service
    /etc/systemd/system/norma-assets-domains.service
    /etc/systemd/system/norma-assets-domains.path
    /etc/systemd/system/norma-assets-domains.timer
    /etc/systemd/system/wstunnel-assets-client.service
    /etc/systemd/system/wg-quick@wg-assets.service.d/wstunnel.conf
    /etc/dnscrypt-proxy/dnscrypt-proxy.toml
    /usr/local/libexec/norma-assets-dns-refresh
    /usr/local/libexec/norma-assets-update-domains
    /usr/local/libexec/norma-assets-routing
    /usr/local/libexec/norma-assets-nfqws-firewall
)
for managed in "${managed_files[@]}"; do
    backup_file "$managed"
done

units=(
    AmneziaVPN.service
    norma-assets-routing.service
    norma-assets-nfqws.service
    norma-assets-domains.service
    norma-assets-domains.path
    norma-assets-domains.timer
    wstunnel-assets-client.service
    wg-quick@wg-assets.service
)
for unit in "${units[@]}"; do
    enabled=$(systemctl is-enabled "$unit" 2>/dev/null || true)
    active=$(systemctl is-active "$unit" 2>/dev/null || true)
    printf '%s\t%s\t%s\n' "$unit" "$enabled" "$active"
done >"$BACKUP/unit-state.tsv"

ip -4 rule show >"$BACKUP/ip-rule.before"
systemctl is-active zapret_discord_youtube.service \
    >"$BACKUP/zapret-active.before" 2>&1 || true
chmod 700 "$BACKUP" "$BACKUP/files"
chmod 600 \
    "$BACKUP/files-present" \
    "$BACKUP/unit-state.tsv" \
    "$BACKUP/ip-rule.before" \
    "$BACKUP/zapret-active.before"

COMMITTED=0
rollback_on_failure() {
    local rc=$?
    trap - EXIT INT TERM
    if (( ! COMMITTED )); then
        echo "install failed (rc=$rc); restoring $BACKUP" >&2
        bash "$ROLLBACK_SOURCE" "$BACKUP" || true
    fi
    exit "$rc"
}
trap rollback_on_failure EXIT
trap 'exit 130' INT TERM

systemctl stop wg-quick@wg-assets.service 2>/dev/null || true
systemctl stop norma-assets-domains.path 2>/dev/null || true
systemctl stop norma-assets-domains.timer 2>/dev/null || true
systemctl stop norma-assets-domains.service 2>/dev/null || true
systemctl stop wstunnel-assets-client.service
systemctl stop AmneziaVPN.service
if ip link show amn0 >/dev/null 2>&1; then
    echo "amn0 remained after stopping AmneziaVPN" >&2
    exit 3
fi
systemctl stop norma-assets-routing.service

install -D -m 755 \
    "$SCRIPT_DIR/libexec/norma-assets-dns-refresh" \
    /usr/local/libexec/norma-assets-dns-refresh
install -D -m 755 \
    "$SCRIPT_DIR/libexec/norma-assets-update-domains" \
    /usr/local/libexec/norma-assets-update-domains
install -D -m 755 \
    "$SCRIPT_DIR/libexec/norma-assets-routing" \
    /usr/local/libexec/norma-assets-routing
install -D -m 755 \
    "$SCRIPT_DIR/libexec/norma-assets-nfqws-firewall" \
    /usr/local/libexec/norma-assets-nfqws-firewall
install -D -m 755 "$ROLLBACK_SOURCE" \
    /usr/local/sbin/norma-assets-bindfix-rollback
install -D -m 644 \
    "$SCRIPT_DIR/systemd/norma-assets-domains.service" \
    /etc/systemd/system/norma-assets-domains.service
install -D -m 644 \
    "$SCRIPT_DIR/systemd/norma-assets-domains.path" \
    /etc/systemd/system/norma-assets-domains.path
install -D -m 644 \
    "$SCRIPT_DIR/systemd/norma-assets-domains.timer" \
    /etc/systemd/system/norma-assets-domains.timer
install -D -m 644 \
    "$SCRIPT_DIR/systemd/norma-assets-routing.service" \
    /etc/systemd/system/norma-assets-routing.service
install -D -m 644 \
    "$SCRIPT_DIR/systemd/norma-assets-nfqws.service" \
    /etc/systemd/system/norma-assets-nfqws.service
install -D -m 644 \
    "$SCRIPT_DIR/systemd/wstunnel-assets-client.service" \
    /etc/systemd/system/wstunnel-assets-client.service
install -D -m 644 \
    "$SCRIPT_DIR/systemd/wg-quick@wg-assets.service.d/wstunnel.conf" \
    /etc/systemd/system/wg-quick@wg-assets.service.d/wstunnel.conf

DNSCRYPT_TMP="$OUT/dnscrypt-proxy.toml"
awk '
    /^[[:space:]]*bootstrap_resolvers[[:space:]]*=/ {
        print "bootstrap_resolvers = ['\''1.1.1.1:53'\'', '\''9.9.9.9:53'\'']"
        replaced++
        next
    }
    { print }
    END {
        if (replaced != 1) {
            exit 3
        }
    }
' /etc/dnscrypt-proxy/dnscrypt-proxy.toml >"$DNSCRYPT_TMP"
install -m 644 -o root -g root \
    "$DNSCRYPT_TMP" /etc/dnscrypt-proxy/dnscrypt-proxy.toml

install -d -m 700 "$STATE_DIR"
printf '%s\n' "$BACKUP" >"$STATE_DIR/current-backup"

systemctl daemon-reload
if systemctl show wg-quick@wg-assets.service --property=Requires --value |
    grep -qw wstunnel-assets-client.service; then
    echo "effective wg-assets dependencies still require wstunnel" >&2
    systemctl show wg-quick@wg-assets.service \
        --property=Requires --property=Wants --property=After
    exit 3
fi
systemctl disable AmneziaVPN.service
systemctl enable \
    norma-assets-routing.service \
    norma-assets-nfqws.service \
    norma-assets-domains.path \
    norma-assets-domains.timer \
    wstunnel-assets-client.service \
    wg-quick@wg-assets.service

systemctl start norma-assets-routing.service
ip -4 route get 104.21.39.248 mark 0x20000000 |
    grep -q 'dev eno1'
ip -4 route get 104.21.39.248 mark 0x40000000 |
    grep -q 'dev eno1'

systemctl start norma-assets-nfqws.service
systemctl start wstunnel-assets-client.service
systemctl start norma-assets-domains.path norma-assets-domains.timer
HANDSHAKE_NOT_BEFORE=$(date +%s)
systemctl start wg-quick@wg-assets.service

wait_for_handshake() {
    local not_before=$1
    local deadline=$((SECONDS + 25))
    local latest
    while (( SECONDS < deadline )); do
        latest=$(wg show wg-assets latest-handshakes |
            awk 'NR == 1 {print $2}')
        if [[ ${latest:-0} =~ ^[0-9]+$ ]] &&
            (( latest >= not_before )); then
            return 0
        fi
        sleep 1
    done
    return 1
}

wait_for_handshake "$HANDSHAKE_NOT_BEFORE"
systemctl start norma-assets-domains.service

echo "test: dnscrypt-over-wg"
DNSCRYPT_ANSWER=$(dig +time=2 +tries=2 +short A chatgpt.com \
    @127.0.0.1 -p 5300)
printf '%s\n' "$DNSCRYPT_ANSWER"
CHATGPT_IP=$(printf '%s\n' "$DNSCRYPT_ANSWER" |
    awk '/^([0-9]{1,3}\.){3}[0-9]{1,3}$/ {print; exit}')
[[ -n $CHATGPT_IP ]]
ip -4 route get "$CHATGPT_IP" | grep -q 'dev wg-assets'

curl_test() {
    local name=$1
    shift
    echo "test: $name"
    curl -4 --interface wg-assets \
        --connect-timeout 10 --max-time 35 \
        --fail --silent --show-error \
        --retry 3 --retry-delay 1 --retry-max-time 60 --retry-all-errors \
        --write-out \
        'http=%{http_code} remote=%{remote_ip} bytes=%{size_download} connect=%{time_connect} start=%{time_starttransfer} total=%{time_total} speed=%{speed_download}\n' \
        "$@"
}

curl_test speed-1m \
    --resolve "speed.cloudflare.com:443:$SPEED_IP" \
    --output /dev/null \
    'https://speed.cloudflare.com/__down?bytes=1000000'
curl_test f95 \
    --resolve f95zone.to:443:188.114.97.3 \
    --http1.1 --output /dev/null \
    https://f95zone.to/
echo "test: chatgpt-system-dns"
curl -4 --interface wg-assets \
    --connect-timeout 10 --max-time 35 \
    --silent --show-error \
    --write-out \
    'http=%{http_code} remote=%{remote_ip} bytes=%{size_download} connect=%{time_connect} start=%{time_starttransfer} total=%{time_total} speed=%{speed_download}\n' \
    --output /dev/null \
    https://chatgpt.com/
curl_test speed-10m \
    --resolve "speed.cloudflare.com:443:$SPEED_IP" \
    --output /dev/null \
    'https://speed.cloudflare.com/__down?bytes=10000000'

echo "test: wg restart restores dynamic domains"
HANDSHAKE_NOT_BEFORE=$(date +%s)
systemctl restart wg-quick@wg-assets.service
wait_for_handshake "$HANDSHAKE_NOT_BEFORE"
systemctl start norma-assets-domains.service
curl -4 --interface wg-assets \
    --connect-timeout 10 --max-time 35 \
    --silent --show-error \
    --write-out \
    'http=%{http_code} remote=%{remote_ip} bytes=%{size_download} connect=%{time_connect} start=%{time_starttransfer} total=%{time_total} speed=%{speed_download}\n' \
    --output /dev/null \
    https://chatgpt.com/

echo "test: zapret restart resilience"
systemctl restart zapret_discord_youtube.service
for unit in \
    zapret_discord_youtube.service \
    norma-assets-nfqws.service \
    wstunnel-assets-client.service \
    wg-quick@wg-assets.service; do
    deadline=$((SECONDS + 15))
    until systemctl is-active --quiet "$unit"; do
        if (( SECONDS >= deadline )); then
            echo "$unit did not return to active state" >&2
            exit 3
        fi
        sleep 1
    done
done

curl_test post-zapret-restart-f95 \
    --resolve f95zone.to:443:188.114.97.3 \
    --http1.1 --output /dev/null \
    https://f95zone.to/

echo "test: wstunnel restart resilience"
systemctl restart wstunnel-assets-client.service
systemctl is-active --quiet wg-quick@wg-assets.service
curl_test post-wstunnel-restart-f95 \
    --resolve f95zone.to:443:188.114.97.3 \
    --http1.1 --output /dev/null \
    https://f95zone.to/

systemctl is-active --quiet \
    dnscrypt-proxy.service \
    norma-assets-routing.service \
    norma-assets-nfqws.service \
    norma-assets-domains.path \
    norma-assets-domains.timer \
    wstunnel-assets-client.service \
    wg-quick@wg-assets.service
[[ $(systemctl is-active AmneziaVPN.service 2>/dev/null || true) != active ]]

nft list table inet norma_assets >"$OUT/nft-final.log"
ip -4 rule show >"$OUT/ip-rule-final.log"
wg show wg-assets >"$OUT/wg-final.log"
systemctl --no-pager --full status \
    norma-assets-nfqws.service \
    wstunnel-assets-client.service \
    wg-quick@wg-assets.service >"$OUT/systemd-final.log"

COMMITTED=1
trap - EXIT INT TERM

echo "install: success"
echo "output=$OUT"
echo "backup=$BACKUP"
echo "rollback=sudo -A /usr/local/sbin/norma-assets-bindfix-rollback $BACKUP"
