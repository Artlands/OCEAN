#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SERVICE_SRC="${SCRIPT_DIR}/cxl-numa-setup.service"
SETUP_SCRIPT_SRC="${SCRIPT_DIR}/setup_cxl_numa.sh"
REPO_OWNER="$(stat -c '%U' "${REPO_ROOT}")"
REPO_GROUP="$(stat -c '%G' "${REPO_ROOT}")"
REPO_OWNER_HOME="$(getent passwd "${REPO_OWNER}" | cut -d: -f6)"
MPI_SHIM_SRC=${MPI_SHIM_SRC:-}
HOSTFILE_SRC=${HOSTFILE_SRC:-}
BENCHMARKS_DIR=${BENCHMARKS_DIR:-}
BENCHMARKS_AVAILABLE=0

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <num_hosts> [base_image]"
    echo "  num_hosts: 1..16"
    echo "  base_image: defaults to ./images/qemu.img"
    exit 1
fi

num_hosts="$1"
base_image="${2:-./images/qemu.img}"

if ! [[ "$num_hosts" =~ ^[0-9]+$ ]] || [[ "$num_hosts" -lt 1 ]] || [[ "$num_hosts" -gt 16 ]]; then
    echo "num_hosts must be an integer in [1, 16]" >&2
    exit 1
fi

if [[ ! -f "$base_image" ]]; then
    echo "Base image not found: $base_image" >&2
    exit 1
fi

base_image="$(cd "$(dirname "$base_image")" && pwd)/$(basename "$base_image")"

QEMU_IMG=${QEMU_IMG:-}
if [[ -z "$QEMU_IMG" ]]; then
    if [[ -x "$HOME/.local/ocean/qemu/bin/qemu-img" ]]; then
        QEMU_IMG="$HOME/.local/ocean/qemu/bin/qemu-img"
    elif [[ -n "$REPO_OWNER_HOME" && -x "$REPO_OWNER_HOME/.local/ocean/qemu/bin/qemu-img" ]]; then
        QEMU_IMG="$REPO_OWNER_HOME/.local/ocean/qemu/bin/qemu-img"
    elif command -v qemu-img >/dev/null 2>&1; then
        QEMU_IMG="$(command -v qemu-img)"
    else
        echo "qemu-img not found. Set QEMU_IMG or add qemu-img to PATH." >&2
        exit 1
    fi
fi

QEMU_NBD=${QEMU_NBD:-}
if [[ -z "$QEMU_NBD" ]]; then
    if [[ -x "$HOME/.local/ocean/qemu/bin/qemu-nbd" ]]; then
        QEMU_NBD="$HOME/.local/ocean/qemu/bin/qemu-nbd"
    elif [[ -n "$REPO_OWNER_HOME" && -x "$REPO_OWNER_HOME/.local/ocean/qemu/bin/qemu-nbd" ]]; then
        QEMU_NBD="$REPO_OWNER_HOME/.local/ocean/qemu/bin/qemu-nbd"
    elif command -v qemu-nbd >/dev/null 2>&1; then
        QEMU_NBD="$(command -v qemu-nbd)"
    else
        echo "qemu-nbd not found. Set QEMU_NBD or add qemu-nbd to PATH." >&2
        exit 1
    fi
fi

BASE_IMAGE_FORMAT=${BASE_IMAGE_FORMAT:-}
if [[ -z "$BASE_IMAGE_FORMAT" ]]; then
    case "$base_image" in
        *.qcow2)
            BASE_IMAGE_FORMAT="qcow2"
            ;;
        *)
            BASE_IMAGE_FORMAT="raw"
            ;;
    esac
fi

base_dir="$(dirname "$base_image")"

SUDO=${SUDO:-sudo}
if [[ $(id -u) -eq 0 ]]; then
    SUDO=""
elif [[ -n "$SUDO" ]] && ! command -v "$SUDO" >/dev/null 2>&1; then
    echo "Root privileges are required to customize overlays, but '$SUDO' is not available." >&2
    echo "Run this script as root, install sudo, or set SUDO to an available privilege-escalation command." >&2
    exit 1
fi

run_root() {
    if [[ -n "$SUDO" ]]; then
        "$SUDO" "$@"
    else
        "$@"
    fi
}

resolve_mpi_shim_source() {
    local candidate
    local -a candidates=(
        "${REPO_ROOT}/images/libmpi_cxl_shim.so"
        "${REPO_ROOT}/workloads/gromacs/libmpi_cxl_shim.so"
        "${REPO_ROOT}/libmpi_cxl_shim.so"
    )

    if [[ -n "$MPI_SHIM_SRC" ]]; then
        if [[ ! -f "$MPI_SHIM_SRC" ]]; then
            echo "MPI shim library not found: $MPI_SHIM_SRC" >&2
            exit 1
        fi
        MPI_SHIM_SRC="$(cd "$(dirname "$MPI_SHIM_SRC")" && pwd)/$(basename "$MPI_SHIM_SRC")"
        return 0
    fi

    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            MPI_SHIM_SRC="$candidate"
            return 0
        fi
    done

    MPI_SHIM_SRC=""
}

require_command() {
    local cmd="$1"
    local hint="$2"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "$hint" >&2
        exit 1
    fi
}

resolve_mpi_shim_source

canonicalize_path() {
    local path="$1"

    printf '%s\n' "$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"
}

trim_line() {
    local line="$1"

    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    printf '%s\n' "$line"
}

resolve_hostfile_source() {
    local default_hostfile="${REPO_ROOT}/images/hostfile"

    if [[ -n "$HOSTFILE_SRC" ]]; then
        if [[ ! -f "$HOSTFILE_SRC" ]]; then
            echo "Hostfile not found: $HOSTFILE_SRC" >&2
            exit 1
        fi
        HOSTFILE_SRC="$(canonicalize_path "$HOSTFILE_SRC")"
        return 0
    fi

    if [[ -f "$default_hostfile" ]]; then
        HOSTFILE_SRC="$(canonicalize_path "$default_hostfile")"
    else
        HOSTFILE_SRC=""
    fi
}

resolve_benchmarks_dir() {
    local default_dir="${REPO_ROOT}/images/benchmarks"

    if [[ -n "$BENCHMARKS_DIR" ]]; then
        if [[ ! -d "$BENCHMARKS_DIR" ]]; then
            echo "Benchmarks directory not found: $BENCHMARKS_DIR" >&2
            exit 1
        fi
        BENCHMARKS_DIR="$(canonicalize_path "$BENCHMARKS_DIR")"
        BENCHMARKS_AVAILABLE=1
        return 0
    fi

    if [[ -d "$default_dir" ]]; then
        BENCHMARKS_DIR="$(canonicalize_path "$default_dir")"
        BENCHMARKS_AVAILABLE=1
    else
        BENCHMARKS_DIR=""
        BENCHMARKS_AVAILABLE=0
    fi
}

emit_default_hostfile() {
    local target="$1"
    local idx

    : > "$target"
    for ((idx = 0; idx < num_hosts; idx++)); do
        printf 'node%d slots=1\n' "$idx" >> "$target"
    done
}

install_guest_hostfiles() {
    local mount_dir="$1"
    local hostfile_tmp

    if [[ -n "$HOSTFILE_SRC" ]]; then
        run_root install -m 0644 "$HOSTFILE_SRC" "$mount_dir/root/hostfile"
        run_root install -m 0644 "$HOSTFILE_SRC" "$mount_dir/root/hostlist"
        return 0
    fi

    hostfile_tmp="$(mktemp /tmp/ocean-stream-hostfile.XXXXXX)"
    emit_default_hostfile "$hostfile_tmp"
    run_root install -m 0644 "$hostfile_tmp" "$mount_dir/root/hostfile"
    run_root install -m 0644 "$hostfile_tmp" "$mount_dir/root/hostlist"
    rm -f "$hostfile_tmp"
}

emit_guest_hosts_entries() {
    local target="$1"
    local idx=0
    local host_name guest_ip raw_line line

    : > "$target"
    if [[ -n "$HOSTFILE_SRC" ]]; then
        while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
            line="$(trim_line "$raw_line")"
            [[ -n "$line" ]] || continue
            read -r host_name _rest <<< "$line"
            [[ -n "${host_name:-}" ]] || continue
            guest_ip="192.168.100.$((10 + idx))"
            printf '%s %s\n' "$guest_ip" "$host_name" >> "$target"
            idx=$((idx + 1))
        done < "$HOSTFILE_SRC"
        return 0
    fi

    for ((idx = 0; idx < num_hosts; idx++)); do
        guest_ip="192.168.100.$((10 + idx))"
        printf '%s node%d\n' "$guest_ip" "$idx" >> "$target"
    done
}

install_guest_etc_hosts() {
    local mount_dir="$1"
    local hosts_tmp entries_tmp filtered_tmp
    local begin_marker="# OCEAN-GUEST-HOSTS-BEGIN"
    local end_marker="# OCEAN-GUEST-HOSTS-END"

    hosts_tmp="$(mktemp /tmp/ocean-guest-hosts.XXXXXX)"
    entries_tmp="$(mktemp /tmp/ocean-guest-hosts-entries.XXXXXX)"
    filtered_tmp="$(mktemp /tmp/ocean-guest-hosts-filtered.XXXXXX)"

    if [[ -f "$mount_dir/etc/hosts" ]]; then
        run_root cat "$mount_dir/etc/hosts" > "$hosts_tmp"
    else
        cat > "$hosts_tmp" <<'EOF'
127.0.0.1 localhost
::1 localhost ip6-localhost ip6-loopback
EOF
    fi

    emit_guest_hosts_entries "$entries_tmp"

    awk -v begin="$begin_marker" -v end="$end_marker" '
        $0 == begin { skip=1; next }
        $0 == end { skip=0; next }
        skip { next }
        {
            for (i = 2; i <= NF; i++) {
                if ($i ~ /^node[0-9]+$/) {
                    next
                }
            }
            print
        }
    ' "$hosts_tmp" > "$filtered_tmp"

    {
        cat "$filtered_tmp"
        printf '\n%s\n' "$begin_marker"
        cat "$entries_tmp"
        printf '%s\n' "$end_marker"
    } > "$hosts_tmp"

    run_root install -m 0644 "$hosts_tmp" "$mount_dir/etc/hosts"
    rm -f "$hosts_tmp" "$entries_tmp" "$filtered_tmp"
}

install_guest_mpi_shim() {
    local mount_dir="$1"
    local shim_name

    [[ -n "$MPI_SHIM_SRC" ]] || return 0

    shim_name="$(basename "$MPI_SHIM_SRC")"
    run_root install -m 0755 "$MPI_SHIM_SRC" "$mount_dir/root/$shim_name"
    if [[ "$shim_name" != "libmpi_cxl_shim.so" ]]; then
        run_root ln -sfn "$shim_name" "$mount_dir/root/libmpi_cxl_shim.so"
    fi
}

install_guest_benchmarks() {
    local mount_dir="$1"
    local artifact artifact_name

    [[ "$BENCHMARKS_AVAILABLE" -eq 1 ]] || return 0

    run_root mkdir -p "$mount_dir/root/benchmarks"
    run_root cp -a "$BENCHMARKS_DIR/." "$mount_dir/root/benchmarks/"

    for artifact in "$BENCHMARKS_DIR"/*; do
        [[ -f "$artifact" ]] || continue
        artifact_name="$(basename "$artifact")"
        run_root ln -sfn "benchmarks/$artifact_name" "$mount_dir/root/$artifact_name"
    done
}

resolve_hostfile_source
resolve_benchmarks_dir

find_nbd_device() {
    local dev

    for dev in /dev/nbd*; do
        [[ -b "$dev" ]] || continue
        if [[ ! -f "/sys/block/$(basename "$dev")/pid" ]]; then
            echo "$dev"
            return 0
        fi
    done

    return 1
}

find_root_partition() {
    local nbd_dev="$1"
    local part

    while read -r part fstype; do
        [[ -n "$part" ]] || continue
        case "$fstype" in
            ext2|ext3|ext4|xfs|btrfs)
                echo "$part"
                return 0
                ;;
        esac
    done < <(lsblk -lnpo NAME,FSTYPE "$nbd_dev")

    return 1
}

inject_guest_setup() {
    local image="$1"
    local host_id="$2"
    local vm_index="$3"
    local nbd_dev root_part mount_dir

    require_command lsblk "lsblk not found."

    mount_dir="$(mktemp -d /tmp/ocean-rdma-image.XXXXXX)"
    nbd_dev=""

    cleanup_image_mount() {
        if mountpoint -q "$mount_dir" 2>/dev/null; then
            run_root umount "$mount_dir"
        fi
        if [[ -n "$nbd_dev" ]]; then
            run_root "$QEMU_NBD" --disconnect "$nbd_dev" >/dev/null 2>&1 || true
        fi
        rmdir "$mount_dir" 2>/dev/null || true
    }

    trap cleanup_image_mount RETURN

    if ! nbd_dev="$(find_nbd_device)"; then
        echo "No free /dev/nbd device is available for image customization." >&2
        echo "Load and configure the nbd module on the host before running this script." >&2
        exit 1
    fi

    run_root "$QEMU_NBD" --connect="$nbd_dev" "$image"
    run_root udevadm settle >/dev/null 2>&1 || true
    run_root partprobe "$nbd_dev" >/dev/null 2>&1 || true
    sleep 1

    if ! root_part="$(find_root_partition "$nbd_dev")"; then
        echo "Unable to find a mountable root partition inside $image" >&2
        exit 1
    fi

    run_root mount "$root_part" "$mount_dir"
    run_root mkdir -p "$mount_dir/root" "$mount_dir/usr/local/bin" "$mount_dir/etc/systemd/system/sysinit.target.wants"
    run_root install -m 0755 "$SETUP_SCRIPT_SRC" "$mount_dir/usr/local/bin/setup_cxl_numa.sh"
    run_root install -m 0644 "$SERVICE_SRC" "$mount_dir/etc/systemd/system/cxl-numa-setup.service"
    install_guest_mpi_shim "$mount_dir"
    run_root ln -sf ../cxl-numa-setup.service "$mount_dir/etc/systemd/system/sysinit.target.wants/cxl-numa-setup.service"
    run_root sh -c "printf 'node%s\n' '$vm_index' > '$mount_dir/etc/hostname'"
    install_guest_hostfiles "$mount_dir"
    install_guest_etc_hosts "$mount_dir"
    install_guest_benchmarks "$mount_dir"

    cleanup_image_mount
    trap - RETURN

    echo "Injected guest setup into $image for host ${host_id} (node${vm_index}, 192.168.100.$((9 + host_id)))"
    if [[ -n "$MPI_SHIM_SRC" ]]; then
        echo "  Installed MPI shim from $MPI_SHIM_SRC to /root/$(basename "$MPI_SHIM_SRC")"
    fi
}

restore_overlay_ownership() {
    local image="$1"

    if [[ -n "$REPO_OWNER" && -n "$REPO_GROUP" ]]; then
        run_root chown "$REPO_OWNER:$REPO_GROUP" "$image"
    fi
}

for ((host_id = 1; host_id <= num_hosts; host_id++)); do
    vm_index=$((host_id - 1))
    target="${base_dir}/qemu${vm_index}.qcow2"

    if [[ -f "$target" ]]; then
        echo "Keeping existing overlay: $target"
        continue
    fi

    "$QEMU_IMG" create -f qcow2 -F "$BASE_IMAGE_FORMAT" -b "$base_image" "$target"
done

for ((host_id = 1; host_id <= num_hosts; host_id++)); do
    vm_index=$((host_id - 1))
    target="${base_dir}/qemu${vm_index}.qcow2"
    inject_guest_setup "$target" "$host_id" "$vm_index"
    restore_overlay_ownership "$target"
done

echo "Prepared QCOW2 overlays next to $base_image"
echo
printf '%-8s %-8s %-14s %-10s %s\n' "Host" "VMIdx" "Disk" "Tap" "CXL_HOST_ID"
for ((host_id = 1; host_id <= num_hosts; host_id++)); do
    vm_index=$((host_id - 1))
    printf '%-8s %-8s %-14s %-10s %s\n' \
        "$host_id" \
        "$vm_index" \
        "${base_dir}/qemu${vm_index}.qcow2" \
        "tap${vm_index}" \
        "$vm_index"
done

echo
echo "Guest setup is injected into each overlay so the VM can apply its per-host hostname and guest IP at boot."
if [[ -n "$HOSTFILE_SRC" ]]; then
    echo "Each overlay receives /root/hostfile and /root/hostlist from $HOSTFILE_SRC."
    echo "Each overlay also receives a managed /etc/hosts block derived from that hostfile order."
else
    echo "Each overlay also receives generated /root/hostfile and /root/hostlist entries for node0..node$((num_hosts - 1))."
    echo "Each overlay also receives matching managed /etc/hosts entries for node0..node$((num_hosts - 1))."
fi
if [[ -n "$MPI_SHIM_SRC" ]]; then
    echo "The MPI shim was also injected into each overlay from $MPI_SHIM_SRC as /root/libmpi_cxl_shim.so."
else
    echo "Place libmpi_cxl_shim.so under images/, or set MPI_SHIM_SRC=/absolute/path/to/libmpi_cxl_shim.so, before rerunning this script if you want to distribute the MPI shim to every overlay."
fi
if [[ "$BENCHMARKS_AVAILABLE" -eq 1 ]]; then
    echo "The contents of $BENCHMARKS_DIR were injected into each overlay under /root/benchmarks/."
    echo "Top-level benchmark files are also linked directly under /root/ for compatibility."
else
    echo "Place benchmark payloads under images/benchmarks/, or set BENCHMARKS_DIR=/absolute/path/to/benchmarks, before rerunning this script if you want to preload benchmark binaries and assets into the overlays."
fi
echo "If you change qemu_integration/setup_cxl_numa.sh or qemu_integration/cxl-numa-setup.service, rerun this script so the updated guest boot logic is reinjected into every overlay."
echo
echo "Launch example:"
echo "  export CXL_TRANSPORT_MODE=rdma"
echo "  export CXL_MEMORY=${CXL_MEMORY:-4G}"
echo "  export CXL_MEMSIM_HOST=<server_host_ib0_ip>"
echo "  export CXL_MEMSIM_PORT=9999"
echo "  export CXL_MEMSIM_RDMA_PORT=10999"
echo "  bash qemu_integration/launch_qemu_cxl_host.sh <host_id>"
