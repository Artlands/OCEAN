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
QEMU_BINARY=${QEMU_BINARY:-$HOME/.local/ocean/qemu/bin/qemu-system-x86_64}
CXL_MEMSIM_HOST=${CXL_MEMSIM_HOST:-127.0.0.1}
CXL_MEMSIM_PORT=${CXL_MEMSIM_PORT:-9999}
CXL_MEMSIM_RDMA_PORT=${CXL_MEMSIM_RDMA_PORT:-$((CXL_MEMSIM_PORT + 1000))}
CXL_TRANSPORT_MODE=${CXL_TRANSPORT_MODE:-rdma}
VM_MEMORY=${VM_MEMORY:-2G}
CXL_MEMORY=${CXL_MEMORY:-4G}
TAP_IFACE=${TAP_IFACE:-tap${vm_index}}
CXL_HOST_ID=${CXL_HOST_ID:-${vm_index}}

printf -v default_mac_suffix '%02x' "$host_id"
VM_MAC=${VM_MAC:-52:54:00:00:00:${default_mac_suffix}}

if [[ -n "${DISK_IMAGE:-}" ]]; then
    disk_image="${DISK_IMAGE}"
elif [[ "$vm_index" -eq 0 && -f ./qemu.img ]]; then
    disk_image="./qemu.img"
elif [[ -f "./qemu${vm_index}.img" ]]; then
    disk_image="./qemu${vm_index}.img"
else
    echo "Unable to locate a disk image for host_id=${host_id}." >&2
    echo "Set DISK_IMAGE explicitly or create ./qemu${vm_index}.img" >&2
    exit 1
fi

if [[ ! -x "${QEMU_BINARY}" ]]; then
    echo "QEMU binary not found: ${QEMU_BINARY}" >&2
    echo "Run bash script/setup_host.sh or set QEMU_BINARY to your QEMU path." >&2
    exit 1
fi

if [[ ! -e "/sys/class/net/${TAP_IFACE}" ]]; then
    echo "TAP interface not found: ${TAP_IFACE}" >&2
    echo "Run bash script/setup_optional_cross_machine_network.sh 1 ${host_id} first." >&2
    exit 1
fi

export CXL_MEMSIM_HOST
export CXL_MEMSIM_PORT
export CXL_MEMSIM_RDMA_PORT
export CXL_TRANSPORT_MODE
export CXL_HOST_ID

"${QEMU_BINARY}" \
    --enable-kvm -cpu qemu64,+xsave,+rdtscp,+avx,+avx2,+sse4.1,+sse4.2,+avx512f,+avx512dq,+avx512ifma,+avx512cd,+avx512bw,+avx512vl,+avx512vbmi,+clflushopt \
    -m 16G,maxmem=32G,slots=8 \
    -smp 4 \
    -M q35,cxl=on \
    -kernel ./bzImage \
    -append "root=/dev/sda rw console=ttyS0,115200 nokaslr" \
    -drive file="${disk_image}",index=0,media=disk,format=raw \
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
    -object memory-backend-file,id=cxl-mem1,share=on,mem-path=/dev/shm/cxlmemsim_shared,size=1G \
    -object memory-backend-file,id=cxl-lsa1,share=on,mem-path=/dev/shm/lsa1.raw,size=1G \
    -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G \
    -nographic
