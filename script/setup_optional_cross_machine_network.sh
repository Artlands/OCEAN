#!/usr/bin/env bash
set -euxo pipefail

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

trim_line() {
    local line="$1"
    line="${line%%#*}"
    xargs <<< "$line"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

derive_vxlan_peers_from_file() {
    local hosts_file="$1"
    local self_host_id="$2"
    local -a peers=()

    [[ -f "$hosts_file" ]] || fail "hosts file not found: $hosts_file"

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        local line host_id host_ip _label
        line="$(trim_line "$raw_line")"
        [[ -n "$line" ]] || continue

        read -r host_id host_ip _label <<< "$line"
        [[ -n "${host_id:-}" && -n "${host_ip:-}" ]] || fail "invalid line in $hosts_file: $raw_line"

        if ! [[ "$host_id" =~ ^[0-9]+$ ]]; then
            fail "invalid host_id in $hosts_file: $host_id"
        fi

        if [[ "$host_id" == "$self_host_id" ]]; then
            continue
        fi

        peers+=("$host_ip")
    done < "$hosts_file"

    [[ ${#peers[@]} -gt 0 ]] || fail "no peer hosts found in $hosts_file for host_id=$self_host_id"
    (IFS=,; echo "${peers[*]}")
}

if [[ $# -ne 2 ]]; then
    echo "[ERROR] Usage: $0 <num_vms> <host_id>"
    echo "        Example host 1: sudo bash $0 1 1   -> creates tap0"
    echo "        Example host 2: sudo bash $0 1 2   -> creates tap1"
    echo ""
    echo "        Optional environment for HPC clusters:"
    echo "          VXLAN_HOSTS_FILE=script/hosts.txt # derive peer IPs from a host list file (default)"
    echo "          VXLAN_PEERS=10.0.0.2,10.0.0.3    # explicit peers, overrides VXLAN_HOSTS_FILE"
    echo "          BR_ADDR=192.168.100.<host_id>/24 # optionally assign an overlay IP to br0"
    echo "          DEV=ib0                          # underlay NIC"
    echo "          LOCAL_IP=10.0.0.1               # optional explicit local underlay IP"
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

DEV="${DEV:-ib0}"
BR="${BR:-br0}"
VNI="${VNI:-100}"
VXLAN_PORT="${VXLAN_PORT:-4789}"
MCAST="${MCAST:-239.1.1.1}"
VXLAN_HOSTS_FILE="${VXLAN_HOSTS_FILE:-${SCRIPT_DIR}/hosts.txt}"
VXLAN_PEERS="${VXLAN_PEERS:-}"
BR_ADDR="${BR_ADDR:-none}"
CLEAN_ALL_TAPS="${CLEAN_ALL_TAPS:-1}"
TAP_START_INDEX=$((host_id - 1))
VXLAN_IFACE="vxlan${VNI}"
MODE="multicast"

if [[ -z "$VXLAN_PEERS" && -n "$VXLAN_HOSTS_FILE" ]]; then
    VXLAN_PEERS="$(derive_vxlan_peers_from_file "$VXLAN_HOSTS_FILE" "$host_id")"
fi

if [[ -n "$VXLAN_PEERS" ]]; then
    MODE="unicast"
fi

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

ip link del "$BR" 2>/dev/null || true
ip link del "$VXLAN_IFACE" 2>/dev/null || true

ip link add "$BR" type bridge
ip link set "$BR" up

if [[ "$MODE" == "multicast" ]]; then
    ip route replace "$MCAST/32" dev "$DEV"
    ip link add "$VXLAN_IFACE" type vxlan id "$VNI" group "$MCAST" dev "$DEV" dstport "$VXLAN_PORT" ttl 10 nolearning
else
    local_args=()
    if [[ -n "${LOCAL_IP:-}" ]]; then
        local_args=(local "$LOCAL_IP")
    fi

    ip link add "$VXLAN_IFACE" type vxlan id "$VNI" dev "$DEV" dstport "$VXLAN_PORT" ttl 10 nolearning "${local_args[@]}"
fi

ip link set "$VXLAN_IFACE" up
ip link set "$VXLAN_IFACE" master "$BR"

if [[ "$MODE" == "unicast" ]]; then
    IFS=',' read -r -a peers <<< "$VXLAN_PEERS"
    for peer in "${peers[@]}"; do
        peer="${peer//[[:space:]]/}"
        if [[ -z "$peer" ]]; then
            continue
        fi
        bridge fdb append 00:00:00:00:00:00 dev "$VXLAN_IFACE" dst "$peer"
    done
fi

if [[ "$BR_ADDR" != "none" ]]; then
    ip addr add "$BR_ADDR" dev "$BR"
fi

for ((i = 0; i < num_vms; i++)); do
    tap_index=$((TAP_START_INDEX + i))
    ip tuntap add "tap${tap_index}" mode tap
    ip link set "tap${tap_index}" up
    ip link set "tap${tap_index}" master "$BR"
done

echo "Bridge $BR ready on host $(hostname) with taps tap${TAP_START_INDEX}..tap$((TAP_START_INDEX + num_vms - 1))"
echo "VXLAN mode: ${MODE} via ${DEV}"
if [[ "$MODE" == "unicast" ]]; then
    echo "VXLAN peers: ${VXLAN_PEERS}"
    if [[ -n "$VXLAN_HOSTS_FILE" ]]; then
        echo "VXLAN hosts file: ${VXLAN_HOSTS_FILE}"
    fi
else
    echo "VXLAN multicast group: ${MCAST}"
fi
if [[ "$BR_ADDR" == "none" ]]; then
    echo "Bridge address assignment skipped by default (BR_ADDR=none)."
else
    echo "Bridge address: ${BR_ADDR}"
fi
if [[ "$CLEAN_ALL_TAPS" == "1" ]]; then
    echo "Stale managed tap interfaces were cleaned before recreation (CLEAN_ALL_TAPS=1)."
else
    echo "Only the tap range for this host_id was cleaned (CLEAN_ALL_TAPS=0)."
fi
echo "Run bash script/verify_optional_cross_machine_network.sh ${num_vms} ${host_id} to verify as a normal user."
