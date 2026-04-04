#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <host_id>"
    echo "  host_id: 1-based physical host identifier, typically 1..16"
    exit 1
fi

host_id="$1"
if ! [[ "$host_id" =~ ^[0-9]+$ ]] || [[ "$host_id" -lt 1 ]] || [[ "$host_id" -gt 16 ]]; then
    echo "host_id must be an integer in [1, 16]" >&2
    exit 1
fi

vm_index=$((host_id - 1))
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGES_DIR="${IMAGES_DIR:-${REPO_ROOT}/images}"
QEMU_BINARY=${QEMU_BINARY:-$HOME/.local/ocean/qemu/bin/qemu-system-x86_64}
CXL_MEMSIM_HOST=${CXL_MEMSIM_HOST:-10.102.94.20}
CXL_MEMSIM_PORT=${CXL_MEMSIM_PORT:-9999}
CXL_MEMSIM_RDMA_PORT=${CXL_MEMSIM_RDMA_PORT:-$((CXL_MEMSIM_PORT + 1000))}
CXL_TRANSPORT_MODE=${CXL_TRANSPORT_MODE:-rdma}
QEMU_ACCEL=${QEMU_ACCEL:-auto}
KERNEL_IMAGE=${KERNEL_IMAGE:-${IMAGES_DIR}/bzImage}
VM_MEMORY=${VM_MEMORY:-2G}
CXL_MEMORY=${CXL_MEMORY:-4G}
CXL_BACKING_PATH=${CXL_BACKING_PATH:-/dev/shm/cxlmemsim_shared}
CXL_LSA_PATH=${CXL_LSA_PATH:-/dev/shm/lsa1.raw}
CXL_LSA_SIZE=${CXL_LSA_SIZE:-1G}
TAP_IFACE=${TAP_IFACE:-tap${vm_index}}
CXL_HOST_ID=${CXL_HOST_ID:-${vm_index}}
GUEST_IP=${GUEST_IP:-192.168.100.$((9 + host_id))}
GUEST_HOSTNAME=${GUEST_HOSTNAME:-node${vm_index}}

printf -v default_mac_suffix '%02x' "$host_id"
VM_MAC=${VM_MAC:-52:54:00:00:00:${default_mac_suffix}}

if [[ -n "${DISK_IMAGE:-}" ]]; then
    disk_image="${DISK_IMAGE}"
elif [[ -f "${IMAGES_DIR}/qemu${vm_index}.qcow2" ]]; then
    disk_image="${IMAGES_DIR}/qemu${vm_index}.qcow2"
elif [[ -f "${IMAGES_DIR}/qemu${vm_index}.img" ]]; then
    disk_image="${IMAGES_DIR}/qemu${vm_index}.img"
elif [[ -f "./qemu${vm_index}.qcow2" ]]; then
    disk_image="./qemu${vm_index}.qcow2"
elif [[ -f "./qemu${vm_index}.img" ]]; then
    disk_image="./qemu${vm_index}.img"
elif [[ "$vm_index" -eq 0 && -f "${IMAGES_DIR}/qemu.img" ]]; then
    disk_image="${IMAGES_DIR}/qemu.img"
elif [[ "$vm_index" -eq 0 && -f ./qemu.img ]]; then
    disk_image="./qemu.img"
else
    echo "Unable to locate a disk image for host_id=${host_id}." >&2
    echo "Set DISK_IMAGE explicitly or create ${IMAGES_DIR}/qemu${vm_index}.qcow2" >&2
    exit 1
fi

kernel_image="${KERNEL_IMAGE}"
if [[ ! -f "${kernel_image}" ]]; then
    echo "Unable to locate bzImage." >&2
    echo "Set KERNEL_IMAGE explicitly or place bzImage at ${IMAGES_DIR}/bzImage" >&2
    exit 1
fi

DISK_FORMAT=${DISK_FORMAT:-}
if [[ -z "$DISK_FORMAT" ]]; then
    case "$disk_image" in
        *.qcow2)
            DISK_FORMAT="qcow2"
            ;;
        *)
            DISK_FORMAT="raw"
            ;;
    esac
fi

if [[ ! -x "${QEMU_BINARY}" ]]; then
    echo "QEMU binary not found: ${QEMU_BINARY}" >&2
    echo "Run bash script/setup_host.sh or set QEMU_BINARY to your QEMU path." >&2
    exit 1
fi

accel_args=()
case "${QEMU_ACCEL}" in
    auto)
        if [[ -e /dev/kvm ]]; then
            qemu_accel_selected="kvm"
        else
            qemu_accel_selected="tcg"
        fi
        ;;
    kvm|tcg)
        qemu_accel_selected="${QEMU_ACCEL}"
        ;;
    *)
        echo "Unsupported QEMU_ACCEL=${QEMU_ACCEL}. Use auto, kvm, or tcg." >&2
        exit 1
        ;;
esac

case "${qemu_accel_selected}" in
    kvm)
        if [[ ! -e /dev/kvm ]]; then
            echo "QEMU_ACCEL=kvm requested, but /dev/kvm is not available on this host." >&2
            exit 1
        fi
        accel_args=(--enable-kvm -cpu qemu64,+xsave,+rdtscp,+avx,+avx2,+sse4.1,+sse4.2,+avx512f,+avx512dq,+avx512ifma,+avx512cd,+avx512bw,+avx512vl,+avx512vbmi,+clflushopt)
        ;;
    tcg)
        accel_args=(-accel tcg,thread=multi -cpu qemu64)
        echo "QEMU_ACCEL=${QEMU_ACCEL}: launching with TCG because /dev/kvm is unavailable." >&2
        ;;
esac

if [[ ! -e "/sys/class/net/${TAP_IFACE}" ]]; then
    echo "TAP interface not found: ${TAP_IFACE}" >&2
    echo "Run bash script/setup_optional_cross_machine_network.sh 1 ${host_id} first." >&2
    exit 1
fi

mkdir -p "$(dirname "${CXL_BACKING_PATH}")" "$(dirname "${CXL_LSA_PATH}")"
truncate -s "${CXL_MEMORY}" "${CXL_BACKING_PATH}"
truncate -s "${CXL_LSA_SIZE}" "${CXL_LSA_PATH}"

export CXL_MEMSIM_HOST
export CXL_MEMSIM_PORT
export CXL_MEMSIM_RDMA_PORT
export CXL_TRANSPORT_MODE
export CXL_HOST_ID

"${QEMU_BINARY}" \
    "${accel_args[@]}" \
    -m 16G,maxmem=32G,slots=8 \
    -smp 4 \
    -M q35,cxl=on \
    -kernel "${kernel_image}" \
    -append "root=/dev/sda rw console=ttyS0,115200 nokaslr cxl_guest_ip=${GUEST_IP} cxl_guest_hostname=${GUEST_HOSTNAME} cxl_region_size=${CXL_MEMORY}" \
    -drive file="${disk_image}",index=0,media=disk,format="${DISK_FORMAT}" \
    -netdev tap,id=net0,ifname="${TAP_IFACE}",script=no,downscript=no \
    -device virtio-net-pci,netdev=net0,mac="${VM_MAC}" \
    -fsdev local,security_model=none,id=fsdev0,path=/dev/shm \
    -device virtio-9p-pci,id=fs0,fsdev=fsdev0,mount_tag=hostshm,bus=pcie.0 \
    -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
    -device cxl-rp,port=0,bus=cxl.1,id=root_port13,chassis=0,slot=0 \
    -device cxl-rp,port=1,bus=cxl.1,id=root_port14,chassis=0,slot=1 \
    -device cxl-type3,bus=root_port13,persistent-memdev=cxl-mem1,lsa=cxl-lsa1,id=cxl-pmem0,sn=0x1 \
    -device cxl-type1,bus=root_port14,size=1G,cache-size=64M \
    -device virtio-cxl-accel-pci,bus=pcie.0 \
    -object memory-backend-file,id=cxl-mem1,share=on,mem-path="${CXL_BACKING_PATH}",size="${CXL_MEMORY}" \
    -object memory-backend-file,id=cxl-lsa1,share=on,mem-path="${CXL_LSA_PATH}",size="${CXL_LSA_SIZE}" \
    -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size="${CXL_MEMORY}" \
    -nographic
