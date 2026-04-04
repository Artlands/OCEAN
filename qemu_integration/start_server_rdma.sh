#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TCP_PORT=${1:-9999}
RDMA_PORT=${2:-$((TCP_PORT + 1000))}

export CXL_TRANSPORT_MODE=rdma

if [[ -x "${SCRIPT_DIR}/cxlmemsim_server_rdma" ]]; then
    server_bin="${SCRIPT_DIR}/cxlmemsim_server_rdma"
elif [[ -x "${SCRIPT_DIR}/build/cxlmemsim_server_rdma" ]]; then
    server_bin="${SCRIPT_DIR}/build/cxlmemsim_server_rdma"
else
    echo "cxlmemsim_server_rdma not found next to this script or under ${SCRIPT_DIR}/build" >&2
    echo "Build it first with: cmake -S qemu_integration -B qemu_integration/build && cmake --build qemu_integration/build -j" >&2
    exit 1
fi

echo "Starting CXLMemSim RDMA server: ${server_bin}" 
echo "TCP port: ${TCP_PORT}, RDMA port: ${RDMA_PORT}"
exec "${server_bin}" "${TCP_PORT}" "${RDMA_PORT}"
