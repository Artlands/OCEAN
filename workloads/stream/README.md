# STREAM

[STREAM](https://www.cs.virginia.edu/stream/) measures sustained memory bandwidth. The MPI variant is required so the CXL shim (`libmpi_cxl_shim.so`) can intercept MPI calls and route memory operations through the DAX device.

## Build

```bash
wget https://www.cs.virginia.edu/stream/FTP/Code/stream.c
mpicc -O3 -fopenmp -DSTREAM_ARRAY_SIZE=1000000  -o stream_mpi_small  stream.c
mpicc -O3 -fopenmp -DSTREAM_ARRAY_SIZE=10000000 -o stream_mpi_medium stream.c
mpicc -O3 -fopenmp -DSTREAM_ARRAY_SIZE=80000000 -o stream_mpi_large  stream.c

scp stream_mpi_small stream_mpi_medium stream_mpi_large root@node0:~/
scp stream_mpi_small stream_mpi_medium stream_mpi_large root@node1:~/
```

## Run

Create a hostfile on node0:

```bash
printf "node0 slots=1\nnode1 slots=1\n" > ~/hostfile
```

Run with CXL:

```bash
export CXL_DAX_PATH="/dev/dax0.0"
export CXL_DAX_RESET=1
export CXL_SHIM_VERBOSE=1
export LD_PRELOAD=/root/libmpi_cxl_shim.so

mpirun --allow-run-as-root --hostfile ~/hostfile --wdir /root \
    -x CXL_DAX_PATH -x CXL_DAX_RESET -x CXL_SHIM_VERBOSE -x LD_PRELOAD \
    /root/stream_mpi_large
```

Baseline (no CXL):

```bash
unset LD_PRELOAD
mpirun --allow-run-as-root --hostfile ~/hostfile --wdir /root /root/stream_mpi_large
```

`--wdir /root` is required — the shim loads `liba.so` from the working directory. `-x` flags are required to forward env vars to remote ranks. If the shim misbehaves, reboot all nodes.