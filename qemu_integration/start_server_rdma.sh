#!/usr/bin/env bash
set -euo pipefail

TCP_PORT=${1:-9999}
RDMA_PORT=${2:-$((TCP_PORT + 1000))}

export CXL_TRANSPORT_MODE=rdma

echo "Starting CXLMemSim RDMA server on TCP port ${TCP_PORT} and RDMA port ${RDMA_PORT}"
exec ./cxlmemsim_server_rdma "${TCP_PORT}" "${RDMA_PORT}"
