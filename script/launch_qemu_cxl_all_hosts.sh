#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOSTS_FILE="${HOSTS_FILE:-${SCRIPT_DIR}/hosts.txt}"
SSH_USER="${SSH_USER:-$USER}"
SSH_PORT="${SSH_PORT:-22}"
SSH_OPTS=(
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -p "${SSH_PORT}"
)
REMOTE_REPO_ROOT="${REMOTE_REPO_ROOT:-${REPO_ROOT}}"
RUN_LOCAL="${RUN_LOCAL:-1}"
LOG_DIR="${LOG_DIR:-${REPO_ROOT}/logs/qemu}"
REMOTE_LOG_DIR="${REMOTE_LOG_DIR:-${REMOTE_REPO_ROOT}/logs/qemu}"
LAUNCH_SCRIPT_REL="qemu_integration/launch_qemu_cxl_host.sh"
CXL_MEMSIM_HOST="${CXL_MEMSIM_HOST:-10.102.94.20}"
CXL_MEMSIM_PORT="${CXL_MEMSIM_PORT:-9999}"
CXL_MEMSIM_RDMA_PORT="${CXL_MEMSIM_RDMA_PORT:-$((CXL_MEMSIM_PORT + 1000))}"
CXL_TRANSPORT_MODE="${CXL_TRANSPORT_MODE:-rdma}"
QEMU_ACCEL="${QEMU_ACCEL:-auto}"

usage() {
    cat <<USAGE
Usage: $0 <all|host_id|start-end...>

Examples:
  $0 all
  $0 2-15
  QEMU_ACCEL=kvm $0 2 3 4   # launch remote hosts while starting host 1 manually

Optional environment:
  HOSTS_FILE=/path/to/hosts.txt
  SSH_USER=$(printf %s "$SSH_USER")   # defaults to the current normal user
  SSH_PORT=$(printf %s "$SSH_PORT")
  REMOTE_REPO_ROOT=/path/to/OCEAN
  RUN_LOCAL=1
  LOG_DIR=${LOG_DIR}
  REMOTE_LOG_DIR=${REMOTE_LOG_DIR}
  CXL_MEMSIM_HOST=$(printf %s "$CXL_MEMSIM_HOST")
  CXL_MEMSIM_PORT=$(printf %s "$CXL_MEMSIM_PORT")
  CXL_MEMSIM_RDMA_PORT=$(printf %s "$CXL_MEMSIM_RDMA_PORT")
  CXL_TRANSPORT_MODE=$(printf %s "$CXL_TRANSPORT_MODE")
  QEMU_ACCEL=$(printf %s "$QEMU_ACCEL")
USAGE
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

declare -A HOST_IPS=()
declare -a HOST_ORDER=()

load_hosts() {
    [[ -f "$HOSTS_FILE" ]] || fail "hosts file not found: $HOSTS_FILE"

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        local line host_id host_ip _label
        line="$(trim_line "$raw_line")"
        [[ -n "$line" ]] || continue

        read -r host_id host_ip _label <<< "$line"
        [[ -n "${host_id:-}" && -n "${host_ip:-}" ]] || fail "invalid line in $HOSTS_FILE: $raw_line"
        [[ "$host_id" =~ ^[0-9]+$ ]] || fail "invalid host_id in $HOSTS_FILE: $host_id"

        HOST_IPS["$host_id"]="$host_ip"
        HOST_ORDER+=("$host_id")
    done < "$HOSTS_FILE"

    [[ ${#HOST_ORDER[@]} -gt 0 ]] || fail "no hosts found in $HOSTS_FILE"
}

get_local_ips() {
    hostname -I 2>/dev/null || true
}

is_local_host_id() {
    local host_id="$1"
    local host_ip="${HOST_IPS[$host_id]}"
    local local_ips

    local_ips="$(get_local_ips)"
    [[ -n "$local_ips" ]] || return 1

    for ip in $local_ips; do
        if [[ "$ip" == "$host_ip" ]]; then
            return 0
        fi
    done

    return 1
}

build_env_args() {
    local -n out_ref=$1
    shift
    out_ref=()

    local key
    for key in "$@"; do
        if [[ -n ${!key+x} ]]; then
            out_ref+=("${key}=${!key}")
        fi
    done
}

build_remote_env_prefix() {
    local out_var=$1
    shift
    local prefix=""
    local key

    for key in "$@"; do
        if [[ -n ${!key+x} ]]; then
            printf -v prefix '%s %s=%q' "$prefix" "$key" "${!key}"
        fi
    done

    printf -v "$out_var" '%s' "$prefix"
}

add_selected_host() {
    local host_id="$1"
    local -n out_ref=$2
    local -n seen_ref=$3

    [[ -n "${HOST_IPS[$host_id]:-}" ]] || fail "host_id $host_id not found in $HOSTS_FILE"
    if [[ -z "${seen_ref[$host_id]:-}" ]]; then
        out_ref+=("$host_id")
        seen_ref["$host_id"]=1
    fi
}

expand_target() {
    local target="$1"
    local out_name="$2"
    local seen_name="$3"
    local -n out_ref="$out_name"
    local -n seen_ref="$seen_name"
    local range_start range_end host_id

    if [[ "$target" =~ ^[0-9]+$ ]]; then
        add_selected_host "$target" "$out_name" "$seen_name"
        return 0
    fi

    if [[ "$target" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        range_start="${BASH_REMATCH[1]}"
        range_end="${BASH_REMATCH[2]}"
        (( range_start <= range_end )) || fail "invalid host range $target: start must be <= end"
        for ((host_id = range_start; host_id <= range_end; host_id++)); do
            add_selected_host "$host_id" "$out_name" "$seen_name"
        done
        return 0
    fi

    fail "target must be an integer host_id, a range like 2-15, or all: $target"
}

run_launch_for_host() {
    local host_id="$1"
    local host_ip="${HOST_IPS[$host_id]}"
    local log_file_name="host${host_id}.log"
    local remote_env_prefix remote_cmd local_log_file remote_log_file pid launch_cmd
    local -a env_args=()

    build_env_args env_args         CXL_MEMSIM_HOST CXL_MEMSIM_PORT CXL_MEMSIM_RDMA_PORT CXL_TRANSPORT_MODE QEMU_ACCEL         VM_MEMORY CXL_MEMORY IMAGES_DIR KERNEL_IMAGE DISK_IMAGE DISK_FORMAT QEMU_BINARY         CXL_BACKING_PATH CXL_LSA_PATH CXL_LSA_SIZE TAP_IFACE CXL_HOST_ID GUEST_IP GUEST_HOSTNAME VM_MAC
    build_remote_env_prefix remote_env_prefix         CXL_MEMSIM_HOST CXL_MEMSIM_PORT CXL_MEMSIM_RDMA_PORT CXL_TRANSPORT_MODE QEMU_ACCEL         VM_MEMORY CXL_MEMORY IMAGES_DIR KERNEL_IMAGE DISK_IMAGE DISK_FORMAT QEMU_BINARY         CXL_BACKING_PATH CXL_LSA_PATH CXL_LSA_SIZE TAP_IFACE CXL_HOST_ID GUEST_IP GUEST_HOSTNAME VM_MAC

    echo "==> host_id=${host_id} host_ip=${host_ip}"
    if [[ "$RUN_LOCAL" == "1" ]] && is_local_host_id "$host_id"; then
        local_log_file="${LOG_DIR}/${log_file_name}"
        mkdir -p "$LOG_DIR"
        printf -v launch_cmd 'cd %q && exec env' "$REPO_ROOT"
        local key value
        for key_value in "${env_args[@]}"; do
            key="${key_value%%=*}"
            value="${key_value#*=}"
            printf -v launch_cmd '%s %s=%q' "$launch_cmd" "$key" "$value"
        done
        printf -v launch_cmd '%s bash %q %q > %q 2>&1 < /dev/null' "$launch_cmd" "$LAUNCH_SCRIPT_REL" "$host_id" "$local_log_file"
        pid="$(setsid -f bash -lc "$launch_cmd" && sleep 1 && pgrep -n -f "${LAUNCH_SCRIPT_REL} ${host_id}" | head -n1 || true)"
        echo "    launched locally with pid=${pid:-unknown} log=${local_log_file}"
    else
        remote_log_file="${REMOTE_LOG_DIR}/${log_file_name}"
        printf -v remote_cmd 'mkdir -p %q && cd %q && setsid -f env%s bash %q %q > %q 2>&1 < /dev/null'             "$REMOTE_LOG_DIR" "$REMOTE_REPO_ROOT" "$remote_env_prefix" "$LAUNCH_SCRIPT_REL" "$host_id" "$remote_log_file"
        ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host_ip}" "$remote_cmd"
        echo "    launched via ssh log=${remote_log_file}"
    fi
}

main() {
    local target
    local -a selected_hosts=()
    local -A seen_hosts=()

    [[ $# -ge 1 ]] || {
        usage
        exit 1
    }

    load_hosts

    if [[ "$1" == "all" ]]; then
        selected_hosts=("${HOST_ORDER[@]}")
    else
        for target in "$@"; do
            expand_target "$target" selected_hosts seen_hosts
        done
    fi

    [[ ${#selected_hosts[@]} -gt 0 ]] || fail "no hosts selected"

    echo "Using CXLMemSim transport settings:"
    echo "  CXL_TRANSPORT_MODE=${CXL_TRANSPORT_MODE}"
    echo "  CXL_MEMSIM_HOST=${CXL_MEMSIM_HOST}"
    echo "  CXL_MEMSIM_PORT=${CXL_MEMSIM_PORT}"
    echo "  CXL_MEMSIM_RDMA_PORT=${CXL_MEMSIM_RDMA_PORT}"

    for target in "${selected_hosts[@]}"; do
        run_launch_for_host "$target"
    done
}

main "$@"
