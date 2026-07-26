#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
    echo "run as root" >&2
    exit 2
fi

readonly STATE_DIR=/var/lib/norma-assets
readonly BACKUP="${1:-$(
    command cat "$STATE_DIR/current-backup" 2>/dev/null || true
)}"

if [[ -z $BACKUP || ! -d $BACKUP ]]; then
    echo "backup not found; pass /root/norma-assets-bindfix-backup-*" >&2
    exit 2
fi

readonly FILES_MANIFEST="$BACKUP/files-present"
readonly UNIT_STATE="$BACKUP/unit-state.tsv"
ROLLBACK_SELF=$(mktemp /tmp/norma-assets-bindfix-rollback.XXXXXX)
readonly ROLLBACK_SELF
cp -- "${BASH_SOURCE[0]}" "$ROLLBACK_SELF"
chmod 700 "$ROLLBACK_SELF"
trap 'rm -f -- "$ROLLBACK_SELF"' EXIT

echo "rollback: backup=$BACKUP"

systemctl stop wg-quick@wg-assets.service 2>/dev/null || true
systemctl stop norma-assets-domains.path 2>/dev/null || true
systemctl stop norma-assets-domains.timer 2>/dev/null || true
systemctl stop norma-assets-domains.service 2>/dev/null || true
systemctl stop wstunnel-assets-client.service 2>/dev/null || true
systemctl stop norma-assets-nfqws.service 2>/dev/null || true
systemctl stop norma-assets-routing.service 2>/dev/null || true

/usr/sbin/nft delete table inet norma_assets 2>/dev/null || true
while /usr/bin/ip -4 rule del pref 91 2>/dev/null; do :; done
while /usr/bin/ip -4 rule del pref 90 2>/dev/null; do :; done

targets=(
    /etc/systemd/system/norma-assets-routing.service
    /etc/systemd/system/norma-assets-nfqws.service
    /etc/systemd/system/norma-assets-domains.service
    /etc/systemd/system/norma-assets-domains.path
    /etc/systemd/system/norma-assets-domains.timer
    /etc/systemd/system/wstunnel-assets-client.service
    /etc/systemd/system/wg-quick@wg-assets.service.d/10-norma-assets.conf
    /etc/systemd/system/wg-quick@wg-assets.service.d/99-norma-assets.conf
    /etc/systemd/system/wg-quick@wg-assets.service.d/wstunnel.conf
    /etc/dnscrypt-proxy/dnscrypt-proxy.toml
    /usr/local/libexec/norma-assets-dns-refresh
    /usr/local/libexec/norma-assets-update-domains
    /usr/local/libexec/norma-assets-routing
    /usr/local/libexec/norma-assets-nfqws-firewall
)

for target in "${targets[@]}"; do
    if [[ -e $target || -L $target ]]; then
        rm -f -- "$target"
    fi
done

if [[ -f $FILES_MANIFEST ]]; then
    while IFS= read -r target; do
        [[ -n $target ]] || continue
        install -d -m 755 "$(dirname "$target")"
        cp -a -- "$BACKUP/files$target" "$target"
    done <"$FILES_MANIFEST"
fi

# Backups produced before 2026-07-26 20:04 had their copied modes narrowed
# recursively. Normalize the known managed file classes so those backups remain
# usable; future backups preserve the original metadata.
for target in \
    /etc/systemd/system/norma-assets-routing.service \
    /etc/systemd/system/norma-assets-nfqws.service \
    /etc/systemd/system/norma-assets-domains.service \
    /etc/systemd/system/norma-assets-domains.path \
    /etc/systemd/system/norma-assets-domains.timer \
    /etc/systemd/system/wstunnel-assets-client.service \
    /etc/systemd/system/wg-quick@wg-assets.service.d/10-norma-assets.conf \
    /etc/systemd/system/wg-quick@wg-assets.service.d/99-norma-assets.conf \
    /etc/systemd/system/wg-quick@wg-assets.service.d/wstunnel.conf; do
    [[ -f $target ]] && chmod 644 "$target"
done

for target in \
    /usr/local/libexec/norma-assets-dns-refresh \
    /usr/local/libexec/norma-assets-update-domains \
    /usr/local/libexec/norma-assets-routing \
    /usr/local/libexec/norma-assets-nfqws-firewall; do
    [[ -f $target ]] && chmod 755 "$target"
done

if [[ -f /etc/dnscrypt-proxy/dnscrypt-proxy.toml ]]; then
    chown root:root /etc/dnscrypt-proxy/dnscrypt-proxy.toml
    chmod 644 /etc/dnscrypt-proxy/dnscrypt-proxy.toml
fi

systemctl daemon-reload

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
    systemctl disable "$unit" >/dev/null 2>&1 || true
done

if [[ -f $UNIT_STATE ]]; then
    while IFS=$'\t' read -r unit enabled _active; do
        case "$enabled" in
            enabled|enabled-runtime|linked|linked-runtime)
                systemctl enable "$unit" >/dev/null 2>&1 || true
                ;;
        esac
    done <"$UNIT_STATE"
fi

restore_active() {
    local wanted_unit=$1
    local wanted_state
    wanted_state=$(awk -F '\t' -v unit="$wanted_unit" \
        '$1 == unit {print $3}' "$UNIT_STATE")
    if [[ $wanted_state == active ]]; then
        systemctl start "$wanted_unit"
    fi
}

restore_active AmneziaVPN.service
restore_active norma-assets-routing.service
restore_active norma-assets-nfqws.service
restore_active norma-assets-domains.service
restore_active norma-assets-domains.path
restore_active norma-assets-domains.timer
restore_active wstunnel-assets-client.service
restore_active wg-quick@wg-assets.service

systemctl try-restart dnscrypt-proxy.service 2>/dev/null || true
resolvectl flush-caches 2>/dev/null || true
systemctl reset-failed wg-quick@wg-assets.service 2>/dev/null || true
install -m 755 -o root -g root \
    "$ROLLBACK_SELF" /usr/local/sbin/norma-assets-bindfix-rollback

echo "rollback: complete"
systemctl is-enabled "${units[@]}" 2>&1 || true
systemctl is-active "${units[@]}" 2>&1 || true
