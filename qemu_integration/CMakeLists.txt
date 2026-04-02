cmake_minimum_required(VERSION 3.10)
project(QEMUCXLMemSimIntegration)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 20)

# Find parent CXLMemSim directory
get_filename_component(CXLMEMSIM_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/.. ABSOLUTE)

# Include directories
include_directories(
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CXLMEMSIM_ROOT}/include
    ${CXLMEMSIM_ROOT}/lib/Drywall/include
    ${CXLMEMSIM_ROOT}/lib/Drywall/build
)

# QEMU interception library
add_library(CXLMemSim SHARED
    src/qemu_cxl_memsim.c
    src/qemu_init_wrapper.c
    src/qemu_rdma_wrapper.cpp
    ${CXLMEMSIM_ROOT}/src/rdma_communication.cpp
)

target_link_libraries(CXLMemSim
    pthread
    rdmacm
    ibverbs
)

set_target_properties(CXLMemSim PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)

# CXLMemSim server (simple version without full CXLController dependency)
add_executable(cxlmemsim_server
    src/cxlmemsim_server_simple.cpp
)

target_link_libraries(cxlmemsim_server
    pthread
)

# RDMA-capable CXLMemSim server
add_executable(cxlmemsim_server_rdma
    src/cxlmemsim_server_rdma.cpp
    ${CXLMEMSIM_ROOT}/src/rdma_communication.cpp
)

target_link_libraries(cxlmemsim_server_rdma
    pthread
    rdmacm
    ibverbs
)

# Test program
add_executable(test_cxl_mem
    test_cxl_mem.c
    src/qemu_cxl_memsim.c
    src/qemu_rdma_wrapper.cpp
    ${CXLMEMSIM_ROOT}/src/rdma_communication.cpp
)

target_link_libraries(test_cxl_mem
    pthread
    rdmacm
    ibverbs
)

# Test kbd hook
add_executable(test_kbd_hook
    test_kbd_hook.c
)

target_link_libraries(test_kbd_hook
    dl
)

# Install targets
install(TARGETS CXLMemSim
    LIBRARY DESTINATION /usr/local/lib
)

install(TARGETS cxlmemsim_server cxlmemsim_server_rdma test_cxl_mem test_kbd_hook
    RUNTIME DESTINATION ${CMAKE_CURRENT_BINARY_DIR}
)

# Copy scripts
configure_file(${CMAKE_CURRENT_SOURCE_DIR}/launch_qemu_cxl.sh
    ${CMAKE_CURRENT_BINARY_DIR}/launch_qemu_cxl.sh COPYONLY)
configure_file(${CMAKE_CURRENT_SOURCE_DIR}/launch_qemu_cxl1.sh
    ${CMAKE_CURRENT_BINARY_DIR}/launch_qemu_cxl1.sh COPYONLY)
configure_file(${CMAKE_CURRENT_SOURCE_DIR}/launch_qemu_cxl_host.sh
    ${CMAKE_CURRENT_BINARY_DIR}/launch_qemu_cxl_host.sh COPYONLY)
configure_file(${CMAKE_CURRENT_SOURCE_DIR}/prepare_rdma_vm_images.sh
    ${CMAKE_CURRENT_BINARY_DIR}/prepare_rdma_vm_images.sh COPYONLY)
configure_file(${CMAKE_CURRENT_SOURCE_DIR}/print_rdma_launch_plan.sh
    ${CMAKE_CURRENT_BINARY_DIR}/print_rdma_launch_plan.sh COPYONLY)
configure_file(${CMAKE_CURRENT_SOURCE_DIR}/start_server.sh
    ${CMAKE_CURRENT_BINARY_DIR}/start_server.sh COPYONLY)
configure_file(${CMAKE_CURRENT_SOURCE_DIR}/start_server_rdma.sh
    ${CMAKE_CURRENT_BINARY_DIR}/start_server_rdma.sh COPYONLY)
configure_file(${CMAKE_CURRENT_SOURCE_DIR}/topology_simple.txt
    ${CMAKE_CURRENT_BINARY_DIR}/topology_simple.txt COPYONLY)
