#include "../include/qemu_cxl_memsim.h"
#include "../../include/rdma_communication.h"

#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>

namespace {
std::unique_ptr<RDMAClient> g_rdma_client;
std::mutex g_rdma_mutex;
uint8_t g_host_id = 0;

int get_rdma_port(int tcp_port) {
    const char* env = std::getenv("CXL_MEMSIM_RDMA_PORT");
    if (env && *env) {
        return std::atoi(env);
    }
    return tcp_port + 1000;
}

uint8_t get_host_id() {
    const char* env = std::getenv("CXL_HOST_ID");
    if (env && *env) {
        return static_cast<uint8_t>(std::atoi(env));
    }
    return 0;
}
}

extern "C" int cxlmemsim_rdma_init(const char* host, int tcp_port) {
    std::lock_guard<std::mutex> lock(g_rdma_mutex);

    if (g_rdma_client && g_rdma_client->is_connected()) {
        return 0;
    }

    g_host_id = get_host_id();
    g_rdma_client = std::make_unique<RDMAClient>(host, static_cast<uint16_t>(get_rdma_port(tcp_port)));
    return g_rdma_client->connect();
}

extern "C" int cxlmemsim_rdma_send_request(const CXLMemSimRequest* req, CXLMemSimResponse* resp) {
    std::lock_guard<std::mutex> lock(g_rdma_mutex);
    if (!g_rdma_client || !g_rdma_client->is_connected()) {
        return -1;
    }

    RDMARequest rdma_req{};
    rdma_req.op_type = req->op_type == CXL_READ_OP ? RDMA_OP_READ : RDMA_OP_WRITE;
    rdma_req.addr = req->addr;
    rdma_req.size = req->size;
    rdma_req.timestamp = req->timestamp;
    rdma_req.host_id = g_host_id;
    rdma_req.virtual_addr = req->addr;
    std::memcpy(rdma_req.data, req->data, CACHELINE_SIZE);

    RDMAResponse rdma_resp{};
    if (g_rdma_client->send_request(rdma_req, rdma_resp) < 0) {
        return -1;
    }

    resp->status = rdma_resp.status;
    resp->latency_ns = rdma_resp.latency_ns;
    std::memcpy(resp->data, rdma_resp.data, CACHELINE_SIZE);
    resp->data[CACHELINE_SIZE - 1] = rdma_resp.cache_state;
    return 0;
}

extern "C" void cxlmemsim_rdma_cleanup(void) {
    std::lock_guard<std::mutex> lock(g_rdma_mutex);
    g_rdma_client.reset();
}
