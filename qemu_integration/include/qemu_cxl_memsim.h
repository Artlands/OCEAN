#ifndef QEMU_CXL_MEMSIM_H
#define QEMU_CXL_MEMSIM_H

#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>
#include <pthread.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CACHELINE_SIZE 64
#define CXL_READ_OP 0
#define CXL_WRITE_OP 1

typedef struct {
    char host[256];
    int port;
    int socket_fd;
    bool connected;
    uint64_t total_reads;
    uint64_t total_writes;
    uint64_t *hotness_map;
    size_t hotness_map_size;
    pthread_mutex_t lock;
} CXLMemSimContext;

typedef struct {
    uint8_t op_type;
    uint64_t addr;
    uint64_t size;
    uint64_t timestamp;
    uint8_t data[CACHELINE_SIZE];
} CXLMemSimRequest;

typedef struct {
    uint8_t status;
    uint64_t latency_ns;
    uint8_t data[CACHELINE_SIZE];
} CXLMemSimResponse;
typedef uint32_t MemTxResult;

typedef struct MemTxAttrs {
    unsigned int unspecified : 1;
    unsigned int secure : 1;
    unsigned int user : 1;
    unsigned int memory : 1;
    unsigned int requester_id : 16;
    unsigned int byte_swap : 1;
    unsigned int target_tlb_bit0 : 1;
    unsigned int target_tlb_bit1 : 1;
    unsigned int target_tlb_bit2 : 1;
} MemTxAttrs;

int cxlmemsim_init(const char *host, int port);
void cxlmemsim_cleanup(void);

int cxlmemsim_rdma_init(const char *host, int tcp_port);
int cxlmemsim_rdma_send_request(const CXLMemSimRequest *req, CXLMemSimResponse *resp);
void cxlmemsim_rdma_cleanup(void);

MemTxResult cxl_type3_read(void *, long unsigned int, long unsigned int *, unsigned int, MemTxAttrs);
MemTxResult cxl_type3_write(void *d, uint64_t addr, uint64_t data,
    unsigned size, MemTxAttrs attrs);

uint64_t cxlmemsim_get_hotness(uint64_t addr);
void cxlmemsim_dump_hotness_stats(void);

int cxlmemsim_check_invalidation(uint64_t phys_addr, size_t size, void *data);
void cxlmemsim_register_invalidation(uint64_t phys_addr, void *data, size_t size);

#ifdef __cplusplus
}
#endif

#endif
