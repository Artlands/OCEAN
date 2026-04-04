#!/usr/bin/env bash
set -euo pipefail

check_root() {
    if [[ $(id -u) -ne 0 ]]; then
        echo "[ERROR] This script must be run as root." >&2
        echo "        Example: sudo bash $0 1 1" >&2
        exit 1
    fi
}

fail() {
    echo "[ERROR] $*" >&2
    exit 1
}

if [[ $# -ne 2 ]]; then
    echo "[ERROR] Usage: $0 <num_vms> <host_id>"
    echo "        Example host 1: sudo bash $0 1 1   -> removes tap0, br0, vxlan100"
    echo "        Example host 2: sudo bash $0 1 2   -> removes tap1, br0, vxlan100"
    echo ""
    echo "        Optional environment:"
    echo "          BR=br0"
    echo "          VNI=100"
    echo "          CLEAN_ALL_TAPS=1   # remove every tapN before bridge/vxlan teardown (default)"
    exit 1
fi

check_root

num_vms="$1"
host_id="$2"

if ! [[ "$num_vms" =~ ^[0-9]+$ ]] || [[ "$num_vms" -lt 1 ]]; then
    fail "<num_vms> must be a positive integer"
fi

if ! [[ "$host_id" =~ ^[0-9]+$ ]] || [[ "$host_id" -lt 1 ]] || [[ "$host_id" -gt 254 ]]; then
    fail "<host_id> must be an integer between 1 and 254"
fi

BR="${BR:-br0}"
VNI="${VNI:-100}"
CLEAN_ALL_TAPS="${CLEAN_ALL_TAPS:-1}"
VXLAN_IFACE="vxlan${VNI}"
TAP_START_INDEX=$((host_id - 1))

if [[ "$CLEAN_ALL_TAPS" == "1" ]]; then
    shopt -s nullglob
    for tap_path in /sys/class/net/tap*; do
        tap_name="${tap_path##*/}"
        [[ "$tap_name" =~ ^tap[0-9]+$ ]] || continue
        ip link del "$tap_name" 2>/dev/null || true
    done
    shopt -u nullglob
else
    for ((i = 0; i < num_vms; i++)); do
        tap_index=$((TAP_START_INDEX + i))
        ip link del "tap${tap_index}" 2>/dev/null || true
    done
fi

ip link del "$VXLAN_IFACE" 2>/dev/null || true
ip link del "$BR" 2>/dev/null || true

if [[ "$CLEAN_ALL_TAPS" == "1" ]]; then
    echo "Removed all managed tap interfaces plus ${VXLAN_IFACE} and ${BR} for host_id=${host_id}."
else
    echo "Removed VM network objects for host_id=${host_id}: taps tap${TAP_START_INDEX}..tap$((TAP_START_INDEX + num_vms - 1)), ${VXLAN_IFACE}, ${BR}"
fi
