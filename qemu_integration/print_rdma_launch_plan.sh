#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGES_DIR="${IMAGES_DIR:-${REPO_ROOT}/images}"

trim_line() {
    local line="$1"
    line="${line%%#*}"
    xargs <<< "$line"
}

derive_vxlan_peers_from_file() {
    local hosts_file="$1"
    local self_host_id="$2"
    local -a peers=()

    [[ -f "$hosts_file" ]] || return 1

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        local line host_id host_ip _label
        line="$(trim_line "$raw_line")"
        [[ -n "$line" ]] || continue

        read -r host_id host_ip _label <<< "$line"
        [[ -n "${host_id:-}" && -n "${host_ip:-}" ]] || continue

        if ! [[ "$host_id" =~ ^[0-9]+$ ]]; then
            continue
        fi

        if [[ "$host_id" == "$self_host_id" ]]; then
            continue
        fi

        peers+=("$host_ip")
    done < "$hosts_file"

    [[ ${#peers[@]} -gt 0 ]] || return 1
    (IFS=,; echo "${peers[*]}")
}

resolve_default_disk() {
    local vm_index="$1"

    if [[ -n "${DISK_IMAGE:-}" ]]; then
        echo "${DISK_IMAGE}"
    elif [[ -f "${IMAGES_DIR}/qemu${vm_index}.qcow2" ]]; then
        echo "${IMAGES_DIR}/qemu${vm_index}.qcow2"
    elif [[ -f "${IMAGES_DIR}/qemu${vm_index}.img" ]]; then
        echo "${IMAGES_DIR}/qemu${vm_index}.img"
    elif [[ "$vm_index" -eq 0 && -f "${IMAGES_DIR}/qemu.img" ]]; then
        echo "${IMAGES_DIR}/qemu.img"
    else
        echo "${IMAGES_DIR}/qemu${vm_index}.qcow2"
    fi
}

if [[ $# -lt 2 || $# -gt 4 ]]; then
    echo "Usage: $0 <num_hosts> <server_ib0_ip> [tcp_port] [rdma_port]"
    echo "  num_hosts: 1..16"
    echo "  server_ib0_ip: IPoIB address of the RDMA server host"
    echo "  tcp_port: defaults to 9999"
    echo "  rdma_port: defaults to tcp_port + 1000"
    exit 1
fi

num_hosts="$1"
server_ip="$2"
tcp_port="${3:-9999}"
rdma_port="${4:-$((tcp_port + 1000))}"
cxl_memory="${CXL_MEMORY:-4G}"

if ! [[ "$num_hosts" =~ ^[0-9]+$ ]] || [[ "$num_hosts" -lt 1 ]] || [[ "$num_hosts" -gt 16 ]]; then
    echo "num_hosts must be an integer in [1, 16]" >&2
    exit 1
fi

if ! [[ "$tcp_port" =~ ^[0-9]+$ ]] || [[ "$tcp_port" -lt 1 ]] || [[ "$tcp_port" -gt 65535 ]]; then
    echo "tcp_port must be an integer in [1, 65535]" >&2
    exit 1
fi

if ! [[ "$rdma_port" =~ ^[0-9]+$ ]] || [[ "$rdma_port" -lt 1 ]] || [[ "$rdma_port" -gt 65535 ]]; then
    echo "rdma_port must be an integer in [1, 65535]" >&2
    exit 1
fi

env_prefix=""
for var_name in BR DEV LOCAL_IP VXLAN_HOSTS_FILE VXLAN_PEERS BR_ADDR VNI MCAST VXLAN_PORT; do
    value="${!var_name:-}"
    if [[ -n "$value" ]]; then
        env_prefix+="${var_name}=${value} "
    fi
done

if [[ -n "$env_prefix" ]]; then
    setup_prefix="sudo env ${env_prefix}"
    verify_prefix="env ${env_prefix}"
else
    setup_prefix="sudo "
    verify_prefix=""
fi

if [[ ${VXLAN_HOSTS_FILE+x} ]]; then
    vxlan_hosts_file="${VXLAN_HOSTS_FILE}"
else
    vxlan_hosts_file="${REPO_ROOT}/script/hosts.txt"
fi

echo "RDMA server"
echo "  Host IP : ${server_ip}"
echo "  TCP port: ${tcp_port}"
echo "  RDMA port: ${rdma_port}"
echo "  Guest CXL memory: ${cxl_memory}"
if [[ -n "${VXLAN_PEERS:-}" ]]; then
    echo "  VXLAN default: unicast via VXLAN_PEERS"
elif [[ -n "$vxlan_hosts_file" && -f "$vxlan_hosts_file" ]]; then
    echo "  VXLAN default: unicast via ${vxlan_hosts_file}"
else
    echo "  VXLAN default: multicast via ${MCAST:-239.1.1.1}"
fi
echo
printf '%-6s %-8s %-10s %-18s %s\n' "Host" "VMIdx" "Tap" "GuestIP" "DefaultDisk"
for ((host_id = 1; host_id <= num_hosts; host_id++)); do
    vm_index=$((host_id - 1))
    guest_ip="192.168.100.$((9 + host_id))"
    disk_image="$(resolve_default_disk "${vm_index}")"
    printf '%-6s %-8s %-10s %-18s %s\n' \
        "$host_id" \
        "$vm_index" \
        "tap${vm_index}" \
        "$guest_ip" \
        "$disk_image"
done

echo
for ((host_id = 1; host_id <= num_hosts; host_id++)); do
    vm_index=$((host_id - 1))
    guest_ip="192.168.100.$((9 + host_id))"
    disk_image="$(resolve_default_disk "${vm_index}")"

    vxlan_mode="multicast"
    vxlan_detail="${MCAST:-239.1.1.1}"
    if [[ -n "${VXLAN_PEERS:-}" ]]; then
        vxlan_mode="unicast"
        vxlan_detail="${VXLAN_PEERS}"
    elif [[ -n "$vxlan_hosts_file" ]]; then
        derived_peers="$(derive_vxlan_peers_from_file "$vxlan_hosts_file" "$host_id" || true)"
        if [[ -n "$derived_peers" ]]; then
            vxlan_mode="unicast"
            vxlan_detail="${derived_peers} (from ${vxlan_hosts_file})"
        fi
    fi

    echo "Host ${host_id}"
    echo "  Network setup: ${setup_prefix}bash script/setup_optional_cross_machine_network.sh 1 ${host_id}"
    echo "  Verify       : ${verify_prefix}bash script/verify_optional_cross_machine_network.sh 1 ${host_id}"
    echo "  VXLAN mode   : ${vxlan_mode} (${vxlan_detail})"
    echo "  Guest IP     : ${guest_ip}"
    echo "  Default disk : ${disk_image}"
    echo "  Launch       :"
    echo "    export CXL_TRANSPORT_MODE=rdma"
    echo "    export CXL_MEMORY=${cxl_memory}"
    echo "    export CXL_MEMSIM_HOST=${server_ip}"
    echo "    export CXL_MEMSIM_PORT=${tcp_port}"
    echo "    export CXL_MEMSIM_RDMA_PORT=${rdma_port}"
    echo "    bash qemu_integration/launch_qemu_cxl_host.sh ${host_id}"
    echo

done
