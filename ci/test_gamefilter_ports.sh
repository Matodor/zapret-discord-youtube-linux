#!/usr/bin/env bash

set -euo pipefail

BASE_DIR="$(realpath "$(dirname "$0")/..")"

source "$BASE_DIR/src/lib/constants.sh"

CUSTOM_STRATEGIES_DIR="$BASE_DIR/custom-strategies"
REPO_DIR="$BASE_DIR/zapret-latest"
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

USE_GAME_FILTER=true
USE_GAME_FILTER_TCP=true
USE_GAME_FILTER_UDP=true
gamefiltertcp_ports="$CUSTOM_TCP_PORTS"
gamefilterudp_ports="$CUSTOM_UDP_PORTS"

parse_bat_file "$STRATEGY_FILE"

params_joined="${nfqws_params[*]}"

assert_equals "$EXPECTED_WF_TCP" "$tcp_ports" "TCP wf ports should use explicit gamefiltertcp_ports"
assert_equals "$EXPECTED_WF_UDP" "$udp_ports" "UDP wf ports should use explicit gamefilterudp_ports"
assert_contains "$params_joined" "--filter-tcp=$CUSTOM_TCP_PORTS" "TCP gamefilter block should use explicit ports"
assert_contains "$params_joined" "--filter-udp=$CUSTOM_UDP_PORTS" "UDP gamefilter block should use explicit ports"
assert_not_contains "$tcp_ports" "1024-65535" "TCP wf ports should not include fallback high ports"
assert_not_contains "$udp_ports" "1024-65535" "UDP wf ports should not include fallback high ports"
assert_not_contains "$params_joined" "1024-65535" "nfqws params should not include fallback high ports"

echo "PASS: explicit gamefilter ports are used without 1024-65535 fallback"
