#!/bin/bash
# STREAM MPI benchmark with and without CXL shim.
# Run from node0. Requires ~/hostfile with node0/node1 slots=1.

export CXL_DAX_PATH="/dev/dax0.0"
export CXL_DAX_RESET=1
export CXL_SHIM_VERBOSE=1
export LD_PRELOAD=/root/libmpi_cxl_shim.so

for size in small medium large; do
    echo "=== ${size} with CXL ==="
    mpirun --allow-run-as-root --hostfile ~/hostfile --wdir /root \
        -x CXL_DAX_PATH -x CXL_DAX_RESET -x CXL_SHIM_VERBOSE -x LD_PRELOAD \
        /root/stream_mpi_${size}
done

unset LD_PRELOAD

for size in small medium large; do
    echo "=== ${size} baseline ==="
    mpirun --allow-run-as-root --hostfile ~/hostfile --wdir /root \
        /root/stream_mpi_${size}
done