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

usage() {
    cat <<USAGE
Usage: $0 <all|host_id|start-end...>

Examples:
  $0 all
  $0 2-15
  $0 2 3 4

Optional environment:
  HOSTS_FILE=/path/to/hosts.txt
  SSH_USER=$(printf %s "$SSH_USER")   # defaults to the current normal user
  SSH_PORT=$(printf %s "$SSH_PORT")
  REMOTE_REPO_ROOT=/path/to/OCEAN
  RUN_LOCAL=1
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

kill_host_vm() {
    local host_id="$1"
    local host_ip="${HOST_IPS[$host_id]}"
    local vm_index=$((host_id - 1))
    local tap_iface="tap${vm_index}"
    local remote_cmd

    printf -v remote_cmd 'pkill -f -- %q || true' "[q]emu-system-x86_64.*ifname=${tap_iface}"

    echo "==> host_id=${host_id} host_ip=${host_ip} tap=${tap_iface}"
    if [[ "$RUN_LOCAL" == "1" ]] && is_local_host_id "$host_id"; then
        bash -lc "$remote_cmd"
        echo "    stop issued locally"
    else
        ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host_ip}" "$remote_cmd"
        echo "    stop issued via ssh"
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

    for target in "${selected_hosts[@]}"; do
        kill_host_vm "$target"
    done
}

main "$@"
