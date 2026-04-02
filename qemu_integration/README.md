# QEMU CXL Memory Simulator Integration

This directory contains the QEMU-side integration for OCEAN. The current tree supports three transport modes selected with `CXL_TRANSPORT_MODE`:

- `tcp`: QEMU client talks to the CXLMemSim server over TCP.
- `shm`: single-host shared-memory mode.
- `rdma`: multi-host RDMA mode using the RDMA client/server implementation in this repository.

## Build

```bash
cmake -S qemu_integration -B qemu_integration/build
cmake --build qemu_integration/build -j$(nproc)
```

Important build outputs:

- `qemu_integration/build/libCXLMemSim.so`
- `qemu_integration/build/cxlmemsim_server`
- `qemu_integration/build/cxlmemsim_server_rdma`
- `qemu_integration/build/start_server_rdma.sh`
- `qemu_integration/build/print_rdma_launch_plan.sh`

## Multi-Host RDMA Deployment

This is the recommended deployment for one VM per physical host on InfiniBand-connected nodes.

### Current Scale Limit

The current coherency metadata uses 16-bit sharer bitmaps, so the practical ceiling is 16 hosts in this path.

Relevant definitions:

- `include/distributed_server.h`: `uint16_t sharers_bitmap`
- `include/cxl_backend.h`: `uint16_t sharers_bitmap`

### Network Model

There are two separate communication paths:

1. Guest Ethernet connectivity between VMs.
   This still uses `tap + br0 + vxlan` created by `script/setup_optional_cross_machine_network.sh`.
2. OCEAN CXL memory traffic.
   This is what uses RDMA when `CXL_TRANSPORT_MODE=rdma`.

Using `ib0` as the underlay NIC for VXLAN does not by itself make guest Ethernet traffic RDMA. RDMA applies to the CXL request path after the QEMU hook library connects to `cxlmemsim_server_rdma`.

### Step 1: Prepare Cross-Host Guest Networking

Run on each physical host with one VM per host. By default, if `script/hosts.txt` exists, the scripts use it to build unicast VXLAN peers.

Default unicast VXLAN using `script/hosts.txt`:

```bash
# script/hosts.txt contains one line per host: <host_id> <underlay_ip> [label]
sudo bash script/setup_optional_cross_machine_network.sh 1 1
bash script/verify_optional_cross_machine_network.sh 1 1
```

Explicit multicast VXLAN:

```bash
sudo env VXLAN_HOSTS_FILE= bash script/setup_optional_cross_machine_network.sh 1 1
env VXLAN_HOSTS_FILE= bash script/verify_optional_cross_machine_network.sh 1 1
```

In this HPC mode, the script does not touch the existing `ib0` IP address. It creates only the local bridge, TAP devices, and a unicast VXLAN device with static peer entries. By default, `br0` is left without an IP address. Set `BR_ADDR=192.168.100.<host_id>/24` only if you want the host itself to participate in that overlay subnet.

Use a shared host list file to derive the peer set automatically:

```text
1 10.0.0.1 rpc-94-1
2 10.0.0.2 rpc-94-2
3 10.0.0.3 rpc-94-3
```

The script reads `script/hosts.txt` by default, removes the current host's own entry by `host_id`, and uses the remaining IPs as the unicast VXLAN peers. Set `VXLAN_HOSTS_FILE` only if you want a different file.

This creates:

- host 1 -> `tap0`
- host 2 -> `tap1`
- host N -> `tap(N-1)`

### Step 2: Prepare Per-Host VM Images

Use the helper to clone a base image and print the host/IP mapping:

```bash
bash qemu_integration/prepare_rdma_vm_images.sh 16 ./qemu.img
```

This creates `qemu0.img ... qemu15.img` and prints the derived mapping for:

- `tap0 ... tap15`
- `CXL_HOST_ID=0 ... 15`
- guest IPs `192.168.100.10 ... 192.168.100.25`

### Step 3: Start the RDMA Server

Choose one server host reachable over the InfiniBand IP network and start the RDMA-capable server from `qemu_integration/build`:

```bash
cd qemu_integration/build
./start_server_rdma.sh 9999 10999
```

This listens on:

- TCP fallback port `9999`
- RDMA port `10999`

### Step 4: Print the Exact Per-Host Launch Plan

Once you know the server host's IPoIB address, print the exact commands for each host:

```bash
bash qemu_integration/print_rdma_launch_plan.sh 16 <server_ib0_ip>
```

You can also override the default ports:

```bash
bash qemu_integration/print_rdma_launch_plan.sh 16 <server_ib0_ip> 9999 10999
```

The helper prints, for each host:

- `sudo bash script/setup_optional_cross_machine_network.sh 1 <host_id>`
- `bash script/verify_optional_cross_machine_network.sh 1 <host_id>`
- the derived guest IP
- the exact `export CXL_*` lines
- `bash qemu_integration/launch_qemu_cxl_host.sh <host_id>`

### Step 5: Launch One VM Per Host

Use the generic launcher with the 1-based physical host id:

```bash
export CXL_MEMSIM_HOST=<server_ib0_ip>
export CXL_MEMSIM_PORT=9999
export CXL_MEMSIM_RDMA_PORT=10999
export CXL_TRANSPORT_MODE=rdma

# host 1
bash qemu_integration/launch_qemu_cxl_host.sh 1

# host 2
bash qemu_integration/launch_qemu_cxl_host.sh 2

# host N
bash qemu_integration/launch_qemu_cxl_host.sh N
```

What the launcher derives automatically:

- `CXL_HOST_ID = host_id - 1`
- `TAP_IFACE = tap(host_id - 1)`
- default disk image = `qemu(host_id - 1).img`
- default MAC = `52:54:00:00:00:XX`

Host 1 also falls back to `./qemu.img` if `./qemu0.img` does not exist.

### Step 6: Configure Guest IPs

Inside the guests, assign sequential overlay IPs:

- host 1 VM -> `192.168.100.10`
- host 2 VM -> `192.168.100.11`
- host 3 VM -> `192.168.100.12`
- ...
- host 16 VM -> `192.168.100.25`

A simple rule is:

```text
guest_ip = 192.168.100.(9 + host_id)
```

### Step 7: Verify Both Paths

Verify guest Ethernet:

```bash
ping 192.168.100.11
```

Verify the RDMA-backed CXL path by checking the server output. You should see the RDMA server start message and the QEMU client should be launched with:

```bash
export CXL_TRANSPORT_MODE=rdma
```

## Notes

- `CXL_MEMSIM_HOST` should be the server host's IPoIB address on `ib0`, not the guest overlay address `192.168.100.x`.
- The generic launchers `launch_qemu_cxl.sh` and `launch_qemu_cxl1.sh` remain useful for the two-host case. For larger deployments use `launch_qemu_cxl_host.sh`.
- If you want a different disk image path, set `DISK_IMAGE` explicitly before launching.
