#!/bin/bash

# CXL NUMA Configuration Script
# This script automatically configures CXL memory as NUMA node 1 at boot

set -e

LOG_FILE="/var/log/cxl_numa_setup.log"
CXL_REGION_SIZE_DEFAULT="1G"
MAX_RETRIES=10
RETRY_DELAY=2
NETWORK_IFACE="${NETWORK_IFACE:-enp0s2}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

get_cmdline_arg() {
    local key="$1"
    local value

    for arg in $(cat /proc/cmdline); do
        case "$arg" in
            "${key}="*)
                value="${arg#${key}=}"
                printf '%s\n' "$value"
                return 0
                ;;
        esac
    done

    return 1
}

wait_for_network_iface() {
    local retries=0
    while [ $retries -lt $MAX_RETRIES ]; do
        if ip link show "$NETWORK_IFACE" >/dev/null 2>&1; then
            return 0
        fi
        log "Waiting for network interface ${NETWORK_IFACE}... (attempt $((retries+1))/$MAX_RETRIES)"
        sleep $RETRY_DELAY
        retries=$((retries+1))
    done

    log "ERROR: Network interface ${NETWORK_IFACE} not found after $MAX_RETRIES attempts"
    return 1
}

wait_for_cxl_device() {
    local retries=0
    while [ $retries -lt $MAX_RETRIES ]; do
        if cxl list -M 2>/dev/null | grep -q "mem0"; then
            log "CXL device mem0 detected"
            return 0
        fi
        log "Waiting for CXL device... (attempt $((retries+1))/$MAX_RETRIES)"
        sleep $RETRY_DELAY
        retries=$((retries+1))
    done
    log "ERROR: CXL device not found after $MAX_RETRIES attempts"
    return 1
}

setup_cxl_region() {
    local cxl_region_size
    cxl_region_size="$(get_cmdline_arg cxl_region_size || echo "$CXL_REGION_SIZE_DEFAULT")"

    log "Creating CXL region (${cxl_region_size})..."

    # Check if region already exists
    if cxl list -R 2>/dev/null | grep -q "region0"; then
        log "Region0 already exists, skipping creation"
        return 0
    fi

    # Create CXL region
    if cxl create-region -m -d decoder0.0 -w 1 mem0 -s "$cxl_region_size" 2>&1 | tee -a "$LOG_FILE"; then
        log "CXL region created successfully"
        return 0
    else
        log "ERROR: Failed to create CXL region"
        return 1
    fi
}

ensure_dax_device_node() {
    local chardev="$1"
    local dev_path="/dev/${chardev}"
    local sysfs_dev="/sys/class/dax/${chardev}/dev"
    local major minor

    if [[ -e "$dev_path" ]]; then
        return 0
    fi

    udevadm trigger >/dev/null 2>&1 || true
    udevadm settle >/dev/null 2>&1 || true

    if [[ -e "$dev_path" ]]; then
        return 0
    fi

    if [[ ! -f "$sysfs_dev" ]]; then
        log "WARNING: ${sysfs_dev} is missing; cannot create ${dev_path}"
        return 1
    fi

    IFS=':' read -r major minor < "$sysfs_dev"
    [[ -n "${major:-}" && -n "${minor:-}" ]] || return 1

    mknod "$dev_path" c "$major" "$minor"
    chmod 0660 "$dev_path"
    return 0
}

ensure_devdax_namespace() {
    local region namespace_json namespace_dev

    if ! command -v ndctl >/dev/null 2>&1; then
        log "WARNING: ndctl is not installed; cannot create a devdax namespace automatically"
        return 1
    fi

    region="$(cxl list -R 2>/dev/null | sed -n 's/.*"region":"\([^"]*\)".*/\1/p' | head -n1)"
    if [[ -z "$region" ]]; then
        log "WARNING: No CXL region was found for devdax namespace creation"
        return 1
    fi

    if daxctl list 2>/dev/null | grep -q '"chardev":"'; then
        log "devdax namespace already available on ${region}"
        return 0
    fi

    namespace_json="$(ndctl list -N -r "$region" 2>/dev/null || true)"
    if grep -q '"mode":"devdax"' <<< "$namespace_json"; then
        log "devdax namespace already exists on ${region}; waiting for daxctl to report it"
        udevadm trigger >/dev/null 2>&1 || true
        udevadm settle >/dev/null 2>&1 || true
        return 0
    fi

    if grep -q '"dev":"namespace' <<< "$namespace_json"; then
        namespace_dev="$(printf '%s\n' "$namespace_json" | sed -n 's/.*"dev":"\([^"]*\)".*/\1/p' | head -n1)"
        log "Namespace ${namespace_dev:-<unknown>} already exists on ${region}, recreating it in devdax mode"
        printf '%s\n' "$namespace_json" | tee -a "$LOG_FILE" || true
        if [[ -n "$namespace_dev" ]]; then
            ndctl disable-namespace "$namespace_dev" 2>&1 | tee -a "$LOG_FILE" || true
            ndctl destroy-namespace "$namespace_dev" -f 2>&1 | tee -a "$LOG_FILE" || true
        fi
    fi

    log "Creating devdax namespace on ${region}..."
    if ndctl create-namespace --region="$region" --mode=devdax --map=mem 2>&1 | tee -a "$LOG_FILE"; then
        udevadm trigger >/dev/null 2>&1 || true
        udevadm settle >/dev/null 2>&1 || true
        return 0
    fi

    log "WARNING: Failed to create devdax namespace on ${region}"
    return 1
}

setup_dax_device() {
    local chardev

    log "Checking DAX device..."
    sleep 2

    chardev="$(daxctl list 2>/dev/null | sed -n 's/.*"chardev":"\([^"]*\)".*/\1/p' | head -n1)"
    if [[ -z "$chardev" ]]; then
        log "daxctl did not report a devdax device; attempting namespace creation"
        ensure_devdax_namespace || true
        sleep 1
        chardev="$(daxctl list 2>/dev/null | sed -n 's/.*"chardev":"\([^"]*\)".*/\1/p' | head -n1)"
    fi

    if [[ -z "$chardev" ]]; then
        log "WARNING: daxctl still did not report a devdax device"
        daxctl list 2>&1 | tee -a "$LOG_FILE" || true
        ndctl list -N 2>&1 | tee -a "$LOG_FILE" || true
        return 1
    fi

    if ensure_dax_device_node "$chardev"; then
        log "DAX device ready at /dev/${chardev}"
        return 0
    fi

    log "WARNING: DAX device ${chardev} exists in sysfs but /dev/${chardev} could not be prepared"
    return 1
}

configure_numa_node() {
    log "Configuring NUMA node..."
    
    # Find the DAX device
    local dax_device=$(ls /sys/bus/dax/devices/ 2>/dev/null | head -n1)
    
    if [ -z "$dax_device" ]; then
        log "WARNING: No DAX device found"
        return 1
    fi
    
    # Online the memory as NUMA node 1
    if [ -f "/sys/bus/dax/devices/$dax_device/target_node" ]; then
        local target_node=$(cat "/sys/bus/dax/devices/$dax_device/target_node")
        log "Target NUMA node: $target_node"
        
        # Try to online the memory
        if daxctl reconfigure-device --mode=system-ram "$dax_device" 2>&1 | tee -a "$LOG_FILE"; then
            log "Memory onlined as system RAM"
        else
            log "WARNING: Could not online memory as system RAM"
        fi
    fi
    
    # Verify NUMA configuration
    numactl --hardware 2>&1 | tee -a "$LOG_FILE"
    
    return 0
}

main() {
    log "Starting CXL NUMA configuration..."
    
    # Load required kernel modules
    modprobe cxl_core 2>/dev/null || true
    modprobe cxl_pci 2>/dev/null || true
    modprobe cxl_acpi 2>/dev/null || true
    modprobe cxl_port 2>/dev/null || true
    modprobe cxl_mem 2>/dev/null || true
    modprobe cxl_pmem 2>/dev/null || true
    modprobe nd_pmem 2>/dev/null || true
    modprobe dax_pmem 2>/dev/null || true
    modprobe dax 2>/dev/null || true
    modprobe device_dax 2>/dev/null || true
    modprobe kmem 2>/dev/null || true
    
    # Wait for CXL device to appear
    if ! wait_for_cxl_device; then
        log "Aborting: CXL device not available"
        exit 1
    fi
    
    # Setup CXL region
    if ! setup_cxl_region; then
        log "Warning: CXL region setup failed, continuing anyway"
    fi
    
    # Ensure a usable DAX device node exists for the CXL region.
    if ! setup_dax_device; then
        log "Warning: DAX device setup failed, continuing anyway"
    fi
    
    # Configure NUMA node
    #if ! configure_numa_node; then
    #    log "Warning: NUMA node configuration incomplete"
    #fi
    
    log "CXL NUMA configuration completed"
    
    # Display final configuration
    log "Final CXL configuration:"
    cxl list 2>&1 | tee -a "$LOG_FILE"
    log "Final NUMA configuration:"
    numactl --hardware 2>&1 | tee -a "$LOG_FILE"
}

# Run main function
main

guest_ip="$(get_cmdline_arg cxl_guest_ip || echo 192.168.100.10)"
guest_hostname="$(get_cmdline_arg cxl_guest_hostname || echo node0)"

hostnamectl set-hostname "$guest_hostname" 2>/dev/null || echo "$guest_hostname" > /etc/hostname
wait_for_network_iface
ip link set "$NETWORK_IFACE" up
ip addr replace "${guest_ip}/24" dev "$NETWORK_IFACE"
ip route replace default via 192.168.100.1
