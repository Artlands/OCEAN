#!/usr/bin/env bash
set -euo pipefail

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
    echo "Usage: $0 <num_vms> <host_id>"
    echo "  Example host 1: $0 1 1"
    echo "  Example host 2: $0 1 2"
    echo ""
    echo "  Optional environment for HPC clusters:"
    echo "    VXLAN_HOSTS_FILE=script/hosts.txt   # derive peer IPs from a host list file (default)"
    echo "    VXLAN_PEERS=10.0.0.2,10.0.0.3       # optional explicit peer validation"
    echo "    BR_ADDR=192.168.100.<host_id>/24"
    echo "    DEV=ib0"
    exit 1
fi

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
MCAST="${MCAST:-239.1.1.1}"
VXLAN_HOSTS_FILE="${VXLAN_HOSTS_FILE:-${SCRIPT_DIR}/hosts.txt}"
VXLAN_PEERS="${VXLAN_PEERS:-}"
BR_ADDR="${BR_ADDR:-none}"
VXLAN_IFACE="vxlan${VNI}"
tap_start_index=$((host_id - 1))

if [[ -z "$VXLAN_PEERS" && -n "$VXLAN_HOSTS_FILE" ]]; then
    VXLAN_PEERS="$(derive_vxlan_peers_from_file "$VXLAN_HOSTS_FILE" "$host_id")"
fi

ip link show "$BR" >/dev/null 2>&1 || fail "bridge ${BR} not found"
ip link show "$VXLAN_IFACE" >/dev/null 2>&1 || fail "${VXLAN_IFACE} not found"

if [[ "$BR_ADDR" != "none" ]]; then
    ip -o addr show dev "$BR" | grep -Fq "$BR_ADDR" || fail "bridge ${BR} is missing address ${BR_ADDR}"
fi

vxlan_details=$(ip -d link show "$VXLAN_IFACE")
ip -o link show dev "$VXLAN_IFACE" | grep -Fq "master ${BR}" || fail "${VXLAN_IFACE} is not attached to bridge ${BR}"
grep -Fq "vxlan id ${VNI}" <<< "$vxlan_details" || fail "${VXLAN_IFACE} is not configured with VNI ${VNI}"
grep -Fq "${DEV}" <<< "$vxlan_details" || fail "${VXLAN_IFACE} is not attached to underlay device ${DEV}"

if grep -Eq "(^|[[:space:]])group[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" <<< "$vxlan_details"; then
    mode="multicast"
    grep -Fq "group ${MCAST}" <<< "$vxlan_details" || fail "${VXLAN_IFACE} is not using multicast group ${MCAST}"
    vxlan_note="group=${MCAST} dev=${DEV}"
else
    mode="unicast"
    if [[ -n "$VXLAN_PEERS" ]]; then
        IFS=',' read -r -a peers <<< "$VXLAN_PEERS"
        for peer in "${peers[@]}"; do
            peer="${peer//[[:space:]]/}"
            if [[ -z "$peer" ]]; then
                continue
            fi
            bridge fdb show dev "$VXLAN_IFACE" | grep -Fq "dst ${peer}" || fail "${VXLAN_IFACE} is missing FDB entry for peer ${peer}"
        done
        vxlan_note="peers=${VXLAN_PEERS} dev=${DEV}"
    else
        vxlan_note="unicast dev=${DEV}; peer FDB not checked"
    fi
fi

printf '%-10s %-10s %-12s %-18s %s\n' "Object" "Status" "Master" "Address" "Notes"
if [[ "$BR_ADDR" == "none" ]]; then
    printf '%-10s %-10s %-12s %-18s %s\n' "$BR" "ok" "-" "-" "bridge present; BR_ADDR defaulted to none"
else
    printf '%-10s %-10s %-12s %-18s %s\n' "$BR" "ok" "-" "$BR_ADDR" "bridge present"
fi
printf '%-10s %-10s %-12s %-18s %s\n' "$VXLAN_IFACE" "ok" "$BR" "-" "$vxlan_note"

for ((i = 0; i < num_vms; i++)); do
    tap_index=$((tap_start_index + i))
    tap_name="tap${tap_index}"

    ip link show "$tap_name" >/dev/null 2>&1 || fail "${tap_name} not found"
    ip -o link show dev "$tap_name" | grep -Fq "master ${BR}" || fail "${tap_name} is not attached to bridge ${BR}"

    printf '%-10s %-10s %-12s %-18s %s\n' "$tap_name" "ok" "$BR" "-" "vm_index=${tap_index}"
done

echo
echo "Cross-machine network looks consistent for host_id=${host_id} (${mode} mode)."
if [[ "$mode" == "unicast" && -z "$VXLAN_PEERS" ]]; then
    echo "Set VXLAN_PEERS if you also want the verifier to check specific remote FDB entries explicitly."
fi
