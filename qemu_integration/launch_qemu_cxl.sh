#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGES_DIR="${IMAGES_DIR:-${REPO_ROOT}/images}"

QEMU_BINARY=${QEMU_BINARY:-$HOME/.local/ocean/qemu/bin/qemu-system-x86_64}
CXL_MEMSIM_HOST=${CXL_MEMSIM_HOST:-127.0.0.1}
CXL_MEMSIM_PORT=${CXL_MEMSIM_PORT:-9999}
CXL_MEMSIM_RDMA_PORT=${CXL_MEMSIM_RDMA_PORT:-$((CXL_MEMSIM_PORT + 1000))}
CXL_TRANSPORT_MODE=${CXL_TRANSPORT_MODE:-shm}
QEMU_ACCEL=${QEMU_ACCEL:-auto}
KERNEL_IMAGE=${KERNEL_IMAGE:-${IMAGES_DIR}/bzImage}
VM_MEMORY=${VM_MEMORY:-2G}
CXL_MEMORY=${CXL_MEMORY:-4G}
GUEST_IP=${GUEST_IP:-192.168.100.10}
GUEST_HOSTNAME=${GUEST_HOSTNAME:-node0}

printf -v default_mac_suffix '%02x' 1
VM_MAC=${VM_MAC:-52:54:00:00:00:${default_mac_suffix}}

if [[ -n "${DISK_IMAGE:-}" ]]; then
    disk_image="${DISK_IMAGE}"
elif [[ -f "${IMAGES_DIR}/qemu0.qcow2" ]]; then
    disk_image="${IMAGES_DIR}/qemu0.qcow2"
elif [[ -f "${IMAGES_DIR}/qemu0.img" ]]; then
    disk_image="${IMAGES_DIR}/qemu0.img"
elif [[ -f ./qemu0.qcow2 ]]; then
    disk_image=./qemu0.qcow2
elif [[ -f ./qemu0.img ]]; then
    disk_image=./qemu0.img
elif [[ -f "${IMAGES_DIR}/qemu.img" ]]; then
    disk_image="${IMAGES_DIR}/qemu.img"
elif [[ -f ./qemu.img ]]; then
    disk_image=./qemu.img
else
    echo "Unable to locate a disk image for host 0." >&2
    echo "Set DISK_IMAGE explicitly or create ${IMAGES_DIR}/qemu0.qcow2" >&2
    exit 1
fi

DISK_FORMAT=${DISK_FORMAT:-}
if [[ -z "${DISK_FORMAT}" ]]; then
    case "${disk_image}" in
        *.qcow2)
            DISK_FORMAT="qcow2"
            ;;
        *)
            DISK_FORMAT="raw"
            ;;
    esac
fi

kernel_image="${KERNEL_IMAGE}"
if [[ ! -f "${kernel_image}" ]]; then
    echo "Unable to locate bzImage." >&2
    echo "Set KERNEL_IMAGE explicitly or place bzImage at ${IMAGES_DIR}/bzImage" >&2
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

if [[ ! -x "${QEMU_BINARY}" ]]; then
    echo "QEMU binary not found: ${QEMU_BINARY}" >&2
    echo "Run bash script/setup_host.sh or set QEMU_BINARY to your QEMU path." >&2
    exit 1
fi

export CXL_MEMSIM_HOST
export CXL_MEMSIM_PORT
export CXL_MEMSIM_RDMA_PORT
export CXL_TRANSPORT_MODE
export CXL_HOST_ID=${CXL_HOST_ID:-0}

"${QEMU_BINARY}" \
    "${accel_args[@]}" \
    -m 16G,maxmem=32G,slots=8 \
    -smp 4 \
    -M q35,cxl=on \
    -kernel "${kernel_image}" \
    -append "root=/dev/sda rw console=ttyS0,115200 nokaslr cxl_guest_ip=${GUEST_IP} cxl_guest_hostname=${GUEST_HOSTNAME}" \
    -drive file="${disk_image}",index=0,media=disk,format="${DISK_FORMAT}" \
    -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \
    -device virtio-net-pci,netdev=net0,mac="${VM_MAC}" \
    -fsdev local,security_model=none,id=fsdev0,path=/dev/shm \
    -device virtio-9p-pci,id=fs0,fsdev=fsdev0,mount_tag=hostshm,bus=pcie.0 \
    -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
    -device cxl-rp,port=0,bus=cxl.1,id=root_port13,chassis=0,slot=0 \
    -device cxl-rp,port=1,bus=cxl.1,id=root_port14,chassis=0,slot=1 \
    -device cxl-type3,bus=root_port13,persistent-memdev=cxl-mem1,lsa=cxl-lsa1,id=cxl-pmem0,sn=0x1 \
    -device cxl-type1,bus=root_port14,size=1G,cache-size=64M \
    -device virtio-cxl-accel-pci,bus=pcie.0 \
    -object memory-backend-file,id=cxl-mem1,share=on,mem-path=/dev/shm/cxlmemsim_shared,size="${CXL_MEMORY}" \
    -object memory-backend-file,id=cxl-lsa1,share=on,mem-path=/dev/shm/lsa1.raw,size=1G \
    -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size="${CXL_MEMORY}" \
    -nographic
