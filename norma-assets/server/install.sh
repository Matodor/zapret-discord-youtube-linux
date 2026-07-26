#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
    echo "run as root" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
TS=$(date +%Y%m%d-%H%M%S)
readonly TS
readonly BACKUP="/root/norma-assets-server-backup-$TS"

required=(
    "$SCRIPT_DIR/norma-assets.nft"
    "$SCRIPT_DIR/norma-assets-update-dynamic-targets"
    "$SCRIPT_DIR/norma-assets-firewall.service.d/10-dynamic-targets.conf"
    /etc/nftables.d/norma-assets.nft
    /etc/systemd/system/norma-assets-firewall.service
)
for file in "${required[@]}"; do
    [[ -f $file ]] || {
        echo "required file not found: $file" >&2
        exit 2
    }
done

install -d -m 700 "$BACKUP"
targets=(
    /etc/nftables.d/norma-assets.nft
    /usr/local/sbin/norma-assets-update-dynamic-targets
    /etc/systemd/system/norma-assets-firewall.service.d/10-dynamic-targets.conf
)
for target in "${targets[@]}"; do
    if [[ -e $target || -L $target ]]; then
        install -d -m 700 "$BACKUP$(dirname "$target")"
        cp -a -- "$target" "$BACKUP$target"
        printf '%s\n' "$target" >>"$BACKUP/files-present"
    fi
done

test_table=norma_assets_check
sed "s/table ip norma_assets/table ip $test_table/" \
    "$SCRIPT_DIR/norma-assets.nft" | nft -c -f -

committed=no
rollback() {
    local rc=$?
    trap - EXIT
    if [[ $committed != yes ]]; then
        for target in "${targets[@]}"; do
            rm -f -- "$target"
            if [[ -e $BACKUP$target || -L $BACKUP$target ]]; then
                install -d -m 755 "$(dirname "$target")"
                cp -a -- "$BACKUP$target" "$target"
            fi
        done
        systemctl daemon-reload
        systemctl restart norma-assets-firewall.service || true
        echo "server install failed; restored $BACKUP" >&2
    fi
    exit "$rc"
}
trap rollback EXIT

install -m 644 -o root -g root \
    "$SCRIPT_DIR/norma-assets.nft" \
    /etc/nftables.d/norma-assets.nft
install -m 755 -o root -g root \
    "$SCRIPT_DIR/norma-assets-update-dynamic-targets" \
    /usr/local/sbin/norma-assets-update-dynamic-targets
install -D -m 644 -o root -g root \
    "$SCRIPT_DIR/norma-assets-firewall.service.d/10-dynamic-targets.conf" \
    /etc/systemd/system/norma-assets-firewall.service.d/10-dynamic-targets.conf

systemctl daemon-reload
systemctl restart norma-assets-firewall.service
systemctl is-active --quiet norma-assets-firewall.service
nft list set ip norma_assets norma_assets_dynamic_v4 >/dev/null

committed=yes
trap - EXIT
echo "server install: success"
echo "backup=$BACKUP"
