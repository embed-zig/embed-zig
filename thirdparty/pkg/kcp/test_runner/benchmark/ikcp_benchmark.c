#include "ikcp.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifndef IKCP_BENCH_LABEL
#define IKCP_BENCH_LABEL "ikcp"
#endif

enum {
    BENCH_MTU = 1400,
    BENCH_PAYLOAD = 64,
    BENCH_PACKET_CAP = 1600,
    BENCH_SMALL_WRITES = 200000,
    BENCH_TRANSFER_BYTES = 8 * 1024 * 1024,
    BENCH_IDLE_FLUSH_ROUNDS = 200000,
};

typedef struct BenchStats {
    uint64_t allocs;
    uint64_t frees;
    uint64_t output_packets;
    uint64_t output_bytes;
    uint64_t recv_bytes;
} BenchStats;

typedef struct Packet {
    int len;
    char data[BENCH_PACKET_CAP];
} Packet;

typedef struct PacketQueue {
    Packet *items;
    size_t cap;
    size_t head;
    size_t len;
} PacketQueue;

typedef struct Peer Peer;

struct Peer {
    ikcpcb *kcp;
    PacketQueue inbox;
    Peer *remote;
    BenchStats *stats;
};

static BenchStats stats;

static uint64_t nowNs(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        perror("clock_gettime");
        exit(1);
    }
    return ((uint64_t)ts.tv_sec * 1000000000ULL) + (uint64_t)ts.tv_nsec;
}

static void *benchMalloc(size_t size)
{
    stats.allocs++;
    return malloc(size);
}

static void benchFree(void *ptr)
{
    if (ptr != NULL) stats.frees++;
    free(ptr);
}

static void queueInit(PacketQueue *queue, size_t cap)
{
    queue->items = (Packet *)calloc(cap, sizeof(Packet));
    if (queue->items == NULL) {
        perror("calloc");
        exit(1);
    }
    queue->cap = cap;
    queue->head = 0;
    queue->len = 0;
}

static void queueDeinit(PacketQueue *queue)
{
    free(queue->items);
    queue->items = NULL;
    queue->cap = 0;
    queue->head = 0;
    queue->len = 0;
}

static int queuePush(PacketQueue *queue, const char *data, int len)
{
    if (queue->len == queue->cap) return -1;
    size_t pos = (queue->head + queue->len) % queue->cap;
    queue->items[pos].len = len;
    memcpy(queue->items[pos].data, data, (size_t)len);
    queue->len++;
    return 0;
}

static int queuePop(PacketQueue *queue, Packet *out)
{
    if (queue->len == 0) return 0;
    *out = queue->items[queue->head];
    queue->head = (queue->head + 1) % queue->cap;
    queue->len--;
    return 1;
}

static int peerOutput(const char *buf, int len, ikcpcb *kcp, void *user)
{
    (void)kcp;
    Peer *peer = (Peer *)user;
    peer->stats->output_packets++;
    peer->stats->output_bytes += (uint64_t)len;
    return queuePush(&peer->remote->inbox, buf, len);
}

static int countOutput(const char *buf, int len, ikcpcb *kcp, void *user)
{
    (void)buf;
    (void)kcp;
    BenchStats *s = (BenchStats *)user;
    s->output_packets++;
    s->output_bytes += (uint64_t)len;
    return 0;
}

static void peerInit(Peer *peer, IUINT32 conv, BenchStats *s)
{
    queueInit(&peer->inbox, 65536);
    peer->stats = s;
    peer->remote = NULL;
    peer->kcp = ikcp_create(conv, peer);
    if (peer->kcp == NULL) {
        fprintf(stderr, "ikcp_create failed\n");
        exit(1);
    }
    ikcp_setoutput(peer->kcp, peerOutput);
    ikcp_nodelay(peer->kcp, 1, 10, 2, 1);
    ikcp_wndsize(peer->kcp, 256, 256);
    peer->kcp->stream = 1;
}

static void peerDeinit(Peer *peer)
{
    ikcp_release(peer->kcp);
    queueDeinit(&peer->inbox);
}

static void pumpPeer(Peer *peer, IUINT32 current)
{
    Packet pkt;
    while (queuePop(&peer->inbox, &pkt)) {
        peer->kcp->current = current;
        if (ikcp_input(peer->kcp, pkt.data, pkt.len) != 0) {
            fprintf(stderr, "ikcp_input failed\n");
            exit(1);
        }
    }
}

static void drainRecv(Peer *peer, BenchStats *s)
{
    char buf[4096];
    for (;;) {
        int n = ikcp_recv(peer->kcp, buf, (int)sizeof(buf));
        if (n < 0) return;
        s->recv_bytes += (uint64_t)n;
    }
}

static void printScenario(const char *name, uint64_t started, BenchStats before)
{
    const uint64_t elapsed_ns = nowNs() - started;
    printf(
        "%-22s elapsed_ms=%8.3f allocs=%llu frees=%llu output_packets=%llu output_bytes=%llu recv_bytes=%llu\n",
        name,
        (double)elapsed_ns / 1000000.0,
        (unsigned long long)(stats.allocs - before.allocs),
        (unsigned long long)(stats.frees - before.frees),
        (unsigned long long)(stats.output_packets - before.output_packets),
        (unsigned long long)(stats.output_bytes - before.output_bytes),
        (unsigned long long)(stats.recv_bytes - before.recv_bytes));
}

static void benchStreamSmallWrites(void)
{
    Peer a;
    Peer b;
    char payload[BENCH_PAYLOAD];
    memset(payload, 0x5a, sizeof(payload));
    peerInit(&a, 100, &stats);
    peerInit(&b, 100, &stats);
    a.remote = &b;
    b.remote = &a;

    BenchStats before = stats;
    uint64_t started = nowNs();
    for (int i = 0; i < BENCH_SMALL_WRITES; i++) {
        int n = ikcp_send(a.kcp, payload, (int)sizeof(payload));
        if (n != (int)sizeof(payload)) {
            fprintf(stderr, "ikcp_send failed: %d\n", n);
            exit(1);
        }
    }
    printScenario("stream-small-writes", started, before);

    peerDeinit(&a);
    peerDeinit(&b);
}

static void benchLoopbackTransfer(void)
{
    Peer a;
    Peer b;
    char payload[1024];
    memset(payload, 0xa5, sizeof(payload));
    peerInit(&a, 200, &stats);
    peerInit(&b, 200, &stats);
    a.remote = &b;
    b.remote = &a;

    BenchStats before = stats;
    uint64_t started = nowNs();
    size_t sent = 0;
    IUINT32 current = 0;
    while (stats.recv_bytes - before.recv_bytes < BENCH_TRANSFER_BYTES) {
        while (sent < BENCH_TRANSFER_BYTES && ikcp_waitsnd(a.kcp) < 128) {
            size_t remaining = BENCH_TRANSFER_BYTES - sent;
            int len = (int)(remaining < sizeof(payload) ? remaining : sizeof(payload));
            int n = ikcp_send(a.kcp, payload, len);
            if (n < 0) {
                fprintf(stderr, "ikcp_send failed: %d\n", n);
                exit(1);
            }
            sent += (size_t)n;
        }
        a.kcp->current = current;
        b.kcp->current = current;
        ikcp_update(a.kcp, current);
        pumpPeer(&b, current);
        drainRecv(&b, &stats);
        ikcp_update(b.kcp, current);
        pumpPeer(&a, current);
        current += 10;
    }
    printScenario("loopback-transfer", started, before);

    peerDeinit(&a);
    peerDeinit(&b);
}

static void benchIdleFlushScan(void)
{
    ikcpcb *kcp = ikcp_create(300, &stats);
    if (kcp == NULL) {
        fprintf(stderr, "ikcp_create failed\n");
        exit(1);
    }
    ikcp_setoutput(kcp, countOutput);
    ikcp_nodelay(kcp, 1, 10, 2, 1);
    ikcp_wndsize(kcp, 1024, 1024);

    char payload[1024];
    memset(payload, 0x3c, sizeof(payload));
    for (int i = 0; i < 512; i++) {
        int n = ikcp_send(kcp, payload, (int)sizeof(payload));
        if (n < 0) {
            fprintf(stderr, "ikcp_send failed: %d\n", n);
            exit(1);
        }
    }
    ikcp_update(kcp, 1);

    BenchStats before = stats;
    uint64_t started = nowNs();
    for (int i = 0; i < BENCH_IDLE_FLUSH_ROUNDS; i++) {
        ikcp_flush(kcp);
    }
    printScenario("idle-flush-scan", started, before);

    ikcp_release(kcp);
}

static void probeFlushSkipHazard(void)
{
    BenchStats local = {0};
    ikcpcb *kcp = ikcp_create(400, &local);
    if (kcp == NULL) {
        fprintf(stderr, "ikcp_create failed\n");
        exit(1);
    }
    ikcp_setoutput(kcp, countOutput);
    ikcp_nodelay(kcp, 1, 10, 2, 1);
    ikcp_wndsize(kcp, 32, 32);

    char payload[1024];
    memset(payload, 0x7e, sizeof(payload));
    for (int i = 0; i < 2; i++) {
        if (ikcp_send(kcp, payload, (int)sizeof(payload)) < 0) {
            fprintf(stderr, "ikcp_send failed\n");
            exit(1);
        }
    }
    ikcp_update(kcp, 1);
    local.output_packets = 0;
    local.output_bytes = 0;

    if (kcp->snd_buf.next != &kcp->snd_buf &&
        kcp->snd_buf.next->next != &kcp->snd_buf) {
        struct IKCPSEG *first = iqueue_entry(kcp->snd_buf.next, struct IKCPSEG, node);
        struct IKCPSEG *second = iqueue_entry(kcp->snd_buf.next->next, struct IKCPSEG, node);
        kcp->current = 1000;
        first->resendts = 2000;
        second->resendts = 999;
        first->xmit = 1;
        second->xmit = 1;
        ikcp_flush(kcp);
    }

    printf(
        "%-22s retransmit_packets=%llu retransmit_bytes=%llu\n",
        "flush-skip-probe",
        (unsigned long long)local.output_packets,
        (unsigned long long)local.output_bytes);

    ikcp_release(kcp);
}

int main(void)
{
    printf("== %s ==\n", IKCP_BENCH_LABEL);
    memset(&stats, 0, sizeof(stats));
    ikcp_allocator(benchMalloc, benchFree);
    benchStreamSmallWrites();
    benchLoopbackTransfer();
    benchIdleFlushScan();
    probeFlushSkipHazard();
    return 0;
}
