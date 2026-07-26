#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
    echo "run as root" >&2
    exit 2
fi

readonly CONFIG=/etc/wireguard/wg-assets.conf
TS=$(date +%Y%m%d-%H%M%S)
readonly TS
readonly BACKUP="/root/wg-assets.conf.backup-$TS"

[[ -f $CONFIG ]] || {
    echo "not found: $CONFIG" >&2
    exit 2
}

mapfile -t additions <<'EOF'
1.0.0.1/32
1.1.1.1/32
3.128.0.0/9
4.144.0.0/12
4.192.0.0/12
5.101.152.0/24
8.0.0.0/13
8.32.0.0/11
9.9.9.9/32
9.9.9.10/32
13.32.0.0/12
13.64.0.0/11
13.104.0.0/14
13.224.0.0/12
15.196.0.0/14
18.64.0.0/10
18.128.0.0/9
20.40.0.0/13
20.48.0.0/12
20.64.0.0/10
20.135.0.0/16
20.184.0.0/13
40.74.0.0/15
40.76.0.0/14
40.80.0.0/12
51.10.0.0/15
51.104.0.0/15
51.116.0.0/16
51.132.0.0/16
52.84.0.0/14
52.136.0.0/13
52.160.0.0/11
54.224.0.0/11
64.239.109.0/24
64.239.123.0/24
65.8.0.0/14
74.119.238.0/23
99.84.0.0/16
104.16.0.0/12
104.40.0.0/13
104.208.0.0/13
108.136.0.0/14
108.156.0.0/14
143.204.0.0/16
149.112.112.10/32
150.168.0.0/14
162.158.0.0/15
172.64.0.0/13
184.104.0.0/15
188.114.96.0/22
EOF

mapfile -t allowed_lines < <(
    grep -nE '^[[:space:]]*AllowedIPs[[:space:]]*=' "$CONFIG"
)
if (( ${#allowed_lines[@]} != 1 )); then
    echo "expected exactly one AllowedIPs line, found ${#allowed_lines[@]}" >&2
    exit 2
fi

current=${allowed_lines[0]#*:}
current=${current#*=}

declare -A seen=()
combined=()

append_unique() {
    local cidr=$1
    cidr=${cidr#"${cidr%%[![:space:]]*}"}
    cidr=${cidr%"${cidr##*[![:space:]]}"}
    [[ -n $cidr ]] || return 0
    if [[ -z ${seen[$cidr]+set} ]]; then
        seen["$cidr"]=1
        combined+=("$cidr")
    fi
}

IFS=',' read -ra existing <<<"$current"
for cidr in "${existing[@]}"; do
    append_unique "$cidr"
done
readonly EXISTING_UNIQUE=${#combined[@]}

for cidr in "${additions[@]}"; do
    append_unique "$cidr"
done

printf -v joined '%s, ' "${combined[@]}"
joined=${joined%, }

cp -a -- "$CONFIG" "$BACKUP"
tmp=$(mktemp)
trap 'rm -f -- "$tmp"' EXIT

awk -v replacement="AllowedIPs = $joined" '
    /^[[:space:]]*AllowedIPs[[:space:]]*=/ && !replaced {
        match($0, /^[[:space:]]*/)
        print substr($0, RSTART, RLENGTH) replacement
        replaced = 1
        next
    }
    { print }
    END {
        if (!replaced) {
            exit 3
        }
    }
' "$CONFIG" >"$tmp"

install -m 600 -o root -g root "$tmp" "$CONFIG"

if ! wg-quick strip wg-assets >/dev/null; then
    cp -a -- "$BACKUP" "$CONFIG"
    echo "validation failed; restored $BACKUP" >&2
    exit 3
fi

if systemctl is-active --quiet wg-quick@wg-assets.service; then
    if ! systemctl restart wg-quick@wg-assets.service; then
        cp -a -- "$BACKUP" "$CONFIG"
        systemctl restart wg-quick@wg-assets.service || true
        echo "restart failed; restored $BACKUP" >&2
        exit 3
    fi
    restarted=yes
else
    restarted=no
fi

echo "AllowedIPs updated: before=$EXISTING_UNIQUE after=${#combined[@]}"
echo "backup=$BACKUP"
echo "wg-assets-restarted=$restarted"
