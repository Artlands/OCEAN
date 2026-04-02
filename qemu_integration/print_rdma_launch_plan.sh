#!/usr/bin/env bash
set -euo pipefail

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
for var_name in DEV LOCAL_IP VXLAN_PEERS BR_ADDR VNI MCAST VXLAN_PORT; do
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

echo "RDMA server"
echo "  Host IP : ${server_ip}"
echo "  TCP port: ${tcp_port}"
echo "  RDMA port: ${rdma_port}"
if [[ -n "${VXLAN_PEERS:-}" ]]; then
    echo "  VXLAN mode: unicast"
    echo "  VXLAN peers: ${VXLAN_PEERS}"
else
    echo "  VXLAN mode: multicast"
fi
echo
printf '%-6s %-8s %-10s %-18s %s\n' "Host" "VMIdx" "Tap" "GuestIP" "Disk"
for ((host_id = 1; host_id <= num_hosts; host_id++)); do
    vm_index=$((host_id - 1))
    guest_ip="192.168.100.$((9 + host_id))"
    printf '%-6s %-8s %-10s %-18s %s\n' \
        "$host_id" \
        "$vm_index" \
        "tap${vm_index}" \
        "$guest_ip" \
        "qemu${vm_index}.img"
done

echo
for ((host_id = 1; host_id <= num_hosts; host_id++)); do
    guest_ip="192.168.100.$((9 + host_id))"

    echo "Host ${host_id}"
    echo "  Network setup: ${setup_prefix}bash script/setup_optional_cross_machine_network.sh 1 ${host_id}"
    echo "  Verify       : ${verify_prefix}bash script/verify_optional_cross_machine_network.sh 1 ${host_id}"
    echo "  Guest IP     : ${guest_ip}"
    echo "  Launch       :"
    echo "    export CXL_TRANSPORT_MODE=rdma"
    echo "    export CXL_MEMSIM_HOST=${server_ip}"
    echo "    export CXL_MEMSIM_PORT=${tcp_port}"
    echo "    export CXL_MEMSIM_RDMA_PORT=${rdma_port}"
    echo "    bash qemu_integration/launch_qemu_cxl_host.sh ${host_id}"
    echo

done
