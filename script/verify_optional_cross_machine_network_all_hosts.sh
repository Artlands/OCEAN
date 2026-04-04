#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOSTS_FILE_WAS_SET=0
if [[ -n ${HOSTS_FILE+x} ]]; then
    HOSTS_FILE_WAS_SET=1
fi
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
VERIFY_SCRIPT_REL="script/verify_optional_cross_machine_network.sh"

if [[ "$HOSTS_FILE_WAS_SET" == "1" && -z ${VXLAN_HOSTS_FILE+x} ]]; then
    VXLAN_HOSTS_FILE="$HOSTS_FILE"
fi

usage() {
    cat <<USAGE
Usage: $0 <num_vms> <all|host_id...>

Examples:
  $0 1 all
  $0 1 1 2 3 4

Environment:
  HOSTS_FILE=/path/to/hosts.txt
  SSH_USER=$(printf %s "$SSH_USER")
  SSH_PORT=$(printf %s "$SSH_PORT")
  REMOTE_REPO_ROOT=/path/to/OCEAN
  RUN_LOCAL=1   # run the matching local host_id without ssh when possible
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

run_verify_for_host() {
    local num_vms="$1"
    local host_id="$2"
    local host_ip="${HOST_IPS[$host_id]}"
    local remote_env_prefix remote_cmd
    local -a env_args=()

    build_env_args env_args DEV BR VNI MCAST VXLAN_HOSTS_FILE VXLAN_PEERS BR_ADDR
    build_remote_env_prefix remote_env_prefix DEV BR VNI MCAST VXLAN_HOSTS_FILE VXLAN_PEERS BR_ADDR

    printf -v remote_cmd 'cd %q && env%s bash %q %q %q' "$REMOTE_REPO_ROOT" "$remote_env_prefix" "$VERIFY_SCRIPT_REL" "$num_vms" "$host_id"

    echo "==> host_id=${host_id} host_ip=${host_ip}"
    if [[ "$RUN_LOCAL" == "1" ]] && is_local_host_id "$host_id"; then
        echo "    running locally: ${VERIFY_SCRIPT_REL}"
        (cd "$REPO_ROOT" && env "${env_args[@]}" bash "$VERIFY_SCRIPT_REL" "$num_vms" "$host_id")
    else
        echo "    running via ssh ${SSH_USER}@${host_ip}:${SSH_PORT}: ${VERIFY_SCRIPT_REL}"
        ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host_ip}" "$remote_cmd"
    fi
}

main() {
    local num_vms target
    local -a selected_hosts=()

    [[ $# -ge 2 ]] || {
        usage
        exit 1
    }

    num_vms="$1"
    shift

    [[ "$num_vms" =~ ^[0-9]+$ ]] && [[ "$num_vms" -ge 1 ]] || fail "<num_vms> must be a positive integer"

    load_hosts

    if [[ "$1" == "all" ]]; then
        selected_hosts=("${HOST_ORDER[@]}")
    else
        for target in "$@"; do
            [[ "$target" =~ ^[0-9]+$ ]] || fail "host_id must be an integer: $target"
            [[ -n "${HOST_IPS[$target]:-}" ]] || fail "host_id $target not found in $HOSTS_FILE"
            selected_hosts+=("$target")
        done
    fi

    [[ ${#selected_hosts[@]} -gt 0 ]] || fail "no hosts selected"

    for target in "${selected_hosts[@]}"; do
        run_verify_for_host "$num_vms" "$target"
    done
}

main "$@"
