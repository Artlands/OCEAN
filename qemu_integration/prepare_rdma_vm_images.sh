#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <num_hosts> [base_image]"
    echo "  num_hosts: 1..16"
    echo "  base_image: defaults to ./qemu.img"
    exit 1
fi

num_hosts="$1"
base_image="${2:-./qemu.img}"

if ! [[ "$num_hosts" =~ ^[0-9]+$ ]] || [[ "$num_hosts" -lt 1 ]] || [[ "$num_hosts" -gt 16 ]]; then
    echo "num_hosts must be an integer in [1, 16]" >&2
    exit 1
fi

if [[ ! -f "$base_image" ]]; then
    echo "Base image not found: $base_image" >&2
    exit 1
fi

for ((host_id = 1; host_id <= num_hosts; host_id++)); do
    vm_index=$((host_id - 1))
    target="./qemu${vm_index}.img"

    if [[ "$base_image" == "$target" ]]; then
        continue
    fi

    cp "$base_image" "$target"
done

echo "Prepared VM disk images from $base_image"
echo
printf '%-8s %-8s %-12s %-10s %-18s %s\n' "Host" "VMIdx" "Disk" "Tap" "GuestIP" "CXL_HOST_ID"
for ((host_id = 1; host_id <= num_hosts; host_id++)); do
    vm_index=$((host_id - 1))
    guest_ip="192.168.100.$((9 + host_id))"
    printf '%-8s %-8s %-12s %-10s %-18s %s\n' \
        "$host_id" \
        "$vm_index" \
        "qemu${vm_index}.img" \
        "tap${vm_index}" \
        "$guest_ip" \
        "$vm_index"
done

echo
echo "Launch example:"
echo "  export CXL_TRANSPORT_MODE=rdma"
echo "  export CXL_MEMSIM_HOST=<server_ib0_ip>"
echo "  export CXL_MEMSIM_PORT=9999"
echo "  export CXL_MEMSIM_RDMA_PORT=10999"
echo "  bash qemu_integration/launch_qemu_cxl_host.sh <host_id>"
