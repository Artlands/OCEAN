# QEMU RDMA Deployment Guide

This guide documents the recommended multi-host OCEAN workflow for one VM per physical host over RDMA.

The end-to-end flow is:

1. Set up the cross-host VM network.
2. Prepare the VM images.
3. Start the `cxlmemsim` RDMA server.
4. Launch the VMs.

## Scope

This guide assumes:

- one VM per physical host
- `ib0` (or another underlay NIC) is already configured on each host
- host IDs are `1..16`
- you want the QEMU CXL path to use RDMA

Current scale limit: 16 hosts. The current coherence metadata uses 16-bit sharer bitmaps.

## Prerequisites

Run the host setup once on every physical machine that will build or run OCEAN:

```bash
bash script/setup_host.sh
sudo bash script/setup_host_sudo.sh
```

Build the QEMU integration once before preparing images or starting the server:

```bash
cmake -S qemu_integration -B qemu_integration/build
cmake --build qemu_integration/build -j$(nproc)
```

You also need:

- a base guest image, typically `images/qemu.img`
- a kernel image, typically `images/bzImage`
- a populated host list at `script/hosts.txt`

Example `script/hosts.txt`:

```text
1 10.0.0.1 rpc-94-1
2 10.0.0.2 rpc-94-2
3 10.0.0.3 rpc-94-3
```

Format:

```text
<host_id> <underlay_ip> [label]
```

If you want to use a different host list file, set `HOSTS_FILE=/absolute/path/to/hosts.txt` when using the all-host wrappers, or set `VXLAN_HOSTS_FILE=/absolute/path/to/hosts.txt` when using the per-host scripts.

## 1. Setup Network

OCEAN uses `tap + br0 + vxlan` for guest Ethernet between hosts. The recommended entry point is the all-host wrapper.

### Recommended: run from one host for all participating hosts

If you are running as `root` and want to avoid `sudo`, use:

```bash
SSH_USER=root bash script/setup_optional_cross_machine_network_all_hosts.sh 1 all
SSH_USER=root bash script/verify_optional_cross_machine_network_all_hosts.sh 1 all
```

This does the following on each selected host:

- destroys the existing VM network first by default (`DESTROY_FIRST=1`)
- removes stale `tapN` devices by default (`CLEAN_ALL_TAPS=1`)
- recreates `br0`, `vxlan100`, and the correct TAP interface
- verifies the resulting configuration

If you only want a subset of hosts:

```bash
SSH_USER=root bash script/setup_optional_cross_machine_network_all_hosts.sh 1 1 2 3 4
SSH_USER=root bash script/verify_optional_cross_machine_network_all_hosts.sh 1 1 2 3 4
```

### Per-host alternative

If you prefer to run setup locally on each machine:

```bash
bash script/setup_optional_cross_machine_network.sh 1 <host_id>
bash script/verify_optional_cross_machine_network.sh 1 <host_id>
```

Examples:

```bash
bash script/setup_optional_cross_machine_network.sh 1 1
bash script/verify_optional_cross_machine_network.sh 1 1

bash script/setup_optional_cross_machine_network.sh 1 2
bash script/verify_optional_cross_machine_network.sh 1 2
```

### Notes

- Host 1 uses `tap0`.
- Host 2 uses `tap1`.
- Host `N` uses `tap(N-1)`.
- By default the scripts derive unicast VXLAN peers from `script/hosts.txt`.
- By default `br0` does not get an IP address. Set `BR_ADDR=192.168.100.<host_id>/24` only if you want the host itself on the guest overlay subnet.

### Cleanup

To tear down the VM network later:

```bash
SSH_USER=root bash script/destroy_optional_cross_machine_network_all_hosts.sh 1 all
```

Or on a single host:

```bash
bash script/destroy_optional_cross_machine_network.sh 1 <host_id>
```

## 2. Build Images

Prepare one QCOW2 overlay per participating host. The helper keeps existing overlays and reinjects the current guest boot setup into every overlay each time you rerun it.

Basic example for 16 hosts:

```bash
bash qemu_integration/prepare_rdma_vm_images.sh 16 ./images/qemu.img
```

If `images/hostfile` exists, the script copies it into every VM image as `/root/hostfile` and `/root/hostlist`. If it is missing, the script falls back to generating `node0 ... node15` entries automatically. Use `HOSTFILE_SRC` to override the source path.

If `images/libmpi_cxl_shim.so` exists, the script copies it into every VM image automatically as `/root/libmpi_cxl_shim.so`. Use `MPI_SHIM_SRC` to override the source path:

```bash
MPI_SHIM_SRC=$(pwd)/images/libmpi_cxl_shim.so \
    bash qemu_integration/prepare_rdma_vm_images.sh 16 ./images/qemu.img
```

If `images/benchmarks/` exists, the script copies its full contents into every VM image at `/root/benchmarks/`. Top-level files are also linked into `/root/` for compatibility. Use `BENCHMARKS_DIR` to override the source directory.

If your base image is QCOW2 instead of raw:

```bash
BASE_IMAGE_FORMAT=qcow2 bash qemu_integration/prepare_rdma_vm_images.sh 16 ./images/qemu.qcow2
```

What this script creates and injects:

- `images/qemu0.qcow2 ... images/qemu15.qcow2`
- guest boot setup service and script
- guest hostname `node0 ... node15`
- guest IP convention `192.168.100.(9 + host_id)`
- `/root/hostfile` and `/root/hostlist` copied from `images/hostfile` when present, otherwise generated automatically
- `/etc/hosts` updated with managed guest-name mappings such as `node0 -> 192.168.100.10`
- optional MPI shim from `images/libmpi_cxl_shim.so`, copied into `/root/libmpi_cxl_shim.so`
- optional benchmark payload copied from `images/benchmarks/` into `/root/benchmarks/`
- top-level benchmark files linked into `/root/` for compatibility with existing launch commands

If you change either of these files, rerun image preparation so the changes are reinjected:

- `qemu_integration/setup_cxl_numa.sh`
- `qemu_integration/cxl-numa-setup.service`

## 3. Start CXLMemSim Server

Choose one physical host as the RDMA server host. Use that host's underlay IP on `ib0`, not a guest overlay IP like `192.168.100.x`.

Start the server with the helper:

```bash
bash qemu_integration/start_server_rdma.sh 9999 10999
```

This starts:

- TCP port `9999`
- RDMA port `10999`

A practical way to keep it running is `tmux`:

```bash
tmux new -s ocean-rdma-server
bash qemu_integration/start_server_rdma.sh 9999 10999
```

## 4. Launch VMs

There are two supported ways to launch the VMs after the network and images are ready.

### Option A: launch from each host individually

Set the server connection variables first:

```bash
export CXL_TRANSPORT_MODE=rdma
export CXL_MEMSIM_HOST=10.102.94.20
export CXL_MEMSIM_PORT=9999
export CXL_MEMSIM_RDMA_PORT=10999
# export CXL_MEMSIM_HOST=<server_ib0_ip>
```

Then launch the VM for that physical host:

```bash
bash qemu_integration/launch_qemu_cxl_host.sh <host_id>
```

Examples:

```bash
bash qemu_integration/launch_qemu_cxl_host.sh 1
bash qemu_integration/launch_qemu_cxl_host.sh 2
```

### Option B: launch all VMs from one controller host

Use the all-host launcher to fan out `launch_qemu_cxl_host.sh` over SSH, detach the QEMU processes, and write one log per host. This launcher is intended to run as the normal user who owns the allocated nodes; it does not require `root`.

Launch every listed host:

```bash
QEMU_ACCEL=kvm bash script/launch_qemu_cxl_all_hosts.sh all
```

Launch an inclusive range:

```bash
bash script/launch_qemu_cxl_all_hosts.sh 2-15
```

Launch an explicit subset:

```bash
bash script/launch_qemu_cxl_all_hosts.sh 2 3 4
```

A common workflow is to start host `1` manually so you can log into `node0` and run benchmarks there, then use the all-host launcher for the rest:

```bash
bash qemu_integration/launch_qemu_cxl_host.sh 1
bash script/launch_qemu_cxl_all_hosts.sh 2-15
```

By default the launcher uses:

- `CXL_TRANSPORT_MODE=rdma`
- `CXL_MEMSIM_HOST=10.102.94.20`
- `CXL_MEMSIM_PORT=9999`
- `CXL_MEMSIM_RDMA_PORT=10999`

Override `CXL_MEMSIM_HOST` if your RDMA server is running on a different underlay IP.

Logs are written locally under `logs/qemu/` and remotely under `${REMOTE_REPO_ROOT}/logs/qemu/` by default.

The per-host launcher derives these values automatically:

- `CXL_HOST_ID = host_id - 1`
- `TAP_IFACE = tap(host_id - 1)`
- disk image `images/qemu(host_id - 1).qcow2`
- guest hostname `node(host_id - 1)`
- guest IP `192.168.100.(9 + host_id)`

Optional launch overrides:

```bash
export VM_MEMORY=2G
export CXL_MEMORY=4G
export QEMU_ACCEL=kvm
export DISK_IMAGE=/absolute/path/to/custom.qcow2
bash qemu_integration/launch_qemu_cxl_host.sh <host_id>
```

## Stop VMs

To stop detached VMs from one controller host, use the matching stop helper `script/stop_qemu_cxl_all_hosts.sh`. It accepts the same selectors as the launcher, including `all` and inclusive ranges like `2-15`.

Stop every listed host:

```bash
bash script/stop_qemu_cxl_all_hosts.sh all
```

Stop a range:

```bash
bash script/stop_qemu_cxl_all_hosts.sh 2-15
```

Stop an explicit subset:

```bash
bash script/stop_qemu_cxl_all_hosts.sh 2 3 4
```

If you used the common workflow of starting host `1` manually and launching `2-15` through the all-host launcher, stop them the same way:

```bash
# host 1 was started manually in the foreground
# stop it with Ctrl-C in that terminal

bash script/stop_qemu_cxl_all_hosts.sh 2-15
```

The stop helper kills the QEMU process for each selected host by matching the derived TAP interface, so host `N` maps to `tap(N-1)`.

## Quick Checklist

Before launching VMs, make sure all of the following are true:

- `script/hosts.txt` contains the correct underlay IPs and host IDs
- `images/qemu.img` exists
- `images/bzImage` exists
- `bash qemu_integration/prepare_rdma_vm_images.sh ...` has been run
- `bash script/setup_optional_cross_machine_network.sh 1 <host_id>` or the all-host wrapper has been run
- `bash qemu_integration/start_server_rdma.sh 9999 10999` is already running on the server host
- `CXL_MEMSIM_HOST` points to the server host underlay IP on `ib0`

## Example End-to-End Session

From a controller host with SSH access to all participating machines:

```bash
cmake -S qemu_integration -B qemu_integration/build
cmake --build qemu_integration/build -j$(nproc)

SSH_USER=root bash script/setup_optional_cross_machine_network_all_hosts.sh 1 all
SSH_USER=root bash script/verify_optional_cross_machine_network_all_hosts.sh 1 all

bash qemu_integration/prepare_rdma_vm_images.sh 16 ./images/qemu.img

bash qemu_integration/start_server_rdma.sh 9999 10999
```

Then either launch all VMs from the controller host as the normal user who owns the allocation:

```bash
QEMU_ACCEL=kvm bash script/launch_qemu_cxl_all_hosts.sh all
```

Or launch only the remote hosts after starting host `1` manually:

```bash
bash qemu_integration/launch_qemu_cxl_host.sh 1
bash script/launch_qemu_cxl_all_hosts.sh 2-15
```

Or launch from each participating host individually:

```bash
export CXL_TRANSPORT_MODE=rdma
export CXL_MEMSIM_HOST=<server_ib0_ip>
export CXL_MEMSIM_PORT=9999
export CXL_MEMSIM_RDMA_PORT=10999
bash qemu_integration/launch_qemu_cxl_host.sh <host_id>
```
