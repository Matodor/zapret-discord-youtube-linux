#!/usr/bin/env bash

set -euo pipefail

BASE_DIR="$(realpath "$(dirname "$0")/..")"

source "$BASE_DIR/src/lib/constants.sh"

CUSTOM_STRATEGIES_DIR="$BASE_DIR/custom-strategies"
TMP_REPO_DIR="$(mktemp -d "$BASE_DIR/.tmp-test-repo.XXXXXX")"
trap 'rm -rf "$TMP_REPO_DIR"' EXIT
REPO_DIR="$TMP_REPO_DIR"
mkdir -p "$REPO_DIR/lists"
source "$BASE_DIR/src/lib/common.sh"

STRATEGY_FILE="$BASE_DIR/custom-strategies/general_alt12_custom_ports.bat"

CUSTOM_TCP_PORTS="8100,8090,8187,8188,8190,8200,8902,9112,8903,8904,9113,8000,8001,8003,8005,56000-56666,12995,13060,20480-20500,50000-52000"
CUSTOM_UDP_PORTS="19294-19344,50000-50100"
EXPECTED_WF_TCP="80,443,2053,2083,2087,2096,8443,$CUSTOM_TCP_PORTS"
EXPECTED_WF_UDP="443,$CUSTOM_UDP_PORTS"

assert_equals() {
    local expected="$1"
    local actual="$2"
    local label="$3"

    if [[ "$actual" != "$expected" ]]; then
        echo "FAIL: $label"
        echo "expected: $expected"
        echo "actual:   $actual"
        exit 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"

    if [[ "$haystack" != *"$needle"* ]]; then
        echo "FAIL: $label"
        echo "missing: $needle"
        exit 1
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"

    if [[ "$haystack" == *"$needle"* ]]; then
        echo "FAIL: $label"
        echo "unexpected: $needle"
        exit 1
    fi
}

assert_same_inode() {
    local left="$1"
    local right="$2"
    local label="$3"
    local left_inode
    local right_inode

    left_inode=$(stat -c '%i' "$left")
    right_inode=$(stat -c '%i' "$right")

    if [[ "$left_inode" != "$right_inode" ]]; then
        echo "FAIL: $label"
        echo "left:  $left inode $left_inode"
        echo "right: $right inode $right_inode"
        exit 1
    fi
}

sync_user_lists

USE_GAME_FILTER=true
USE_GAME_FILTER_TCP=true
USE_GAME_FILTER_UDP=true
gamefiltertcp_ports="$CUSTOM_TCP_PORTS"
gamefilterudp_ports="$CUSTOM_UDP_PORTS"

parse_bat_file "$STRATEGY_FILE"

params_joined="${nfqws_params[*]}"
expected_user_general="lists/list-general-user.txt"
expected_user_exclude="lists/list-exclude-user.txt"
expected_user_ipset_exclude="lists/ipset-exclude-user.txt"

assert_equals "$EXPECTED_WF_TCP" "$tcp_ports" "TCP wf ports should use explicit gamefiltertcp_ports"
assert_equals "$EXPECTED_WF_UDP" "$udp_ports" "UDP wf ports should use explicit gamefilterudp_ports"
assert_contains "$params_joined" "--filter-tcp=$CUSTOM_TCP_PORTS" "TCP gamefilter block should use explicit ports"
assert_contains "$params_joined" "--filter-udp=$CUSTOM_UDP_PORTS" "UDP gamefilter block should use explicit ports"
assert_contains "$params_joined" "--hostlist=lists/list-general.txt" "Bundled general hostlist should stay relative to zapret-latest"
assert_contains "$params_joined" "--hostlist=$expected_user_general" "User general hostlist should be read through zapret-latest hardlink"
assert_contains "$params_joined" "--hostlist-exclude=$expected_user_exclude" "User exclude hostlist should be read through zapret-latest hardlink"
assert_contains "$params_joined" "--ipset-exclude=$expected_user_ipset_exclude" "User ipset exclude should be read through zapret-latest hardlink"
assert_same_inode "$BASE_DIR/user-lists/list-general-user.txt" "$REPO_DIR/lists/list-general-user.txt" "User general hostlist should be hardlinked from root user-lists"
assert_same_inode "$BASE_DIR/user-lists/list-exclude-user.txt" "$REPO_DIR/lists/list-exclude-user.txt" "User exclude hostlist should be hardlinked from root user-lists"
assert_same_inode "$BASE_DIR/user-lists/ipset-exclude-user.txt" "$REPO_DIR/lists/ipset-exclude-user.txt" "User ipset exclude should be hardlinked from root user-lists"
assert_not_contains "$tcp_ports" "1024-65535" "TCP wf ports should not include fallback high ports"
assert_not_contains "$udp_ports" "1024-65535" "UDP wf ports should not include fallback high ports"
assert_not_contains "$params_joined" "1024-65535" "nfqws params should not include fallback high ports"

echo "PASS: explicit gamefilter ports are used without 1024-65535 fallback"
