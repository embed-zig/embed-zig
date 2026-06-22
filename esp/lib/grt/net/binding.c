#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "esp_netif.h"
#include "lwip/api.h"
#include "lwip/err.h"
#include "lwip/ip.h"
#include "lwip/netbuf.h"
#include "lwip/pbuf.h"
#include "lwip/tcp.h"

#if !LWIP_NETCONN_FULLDUPLEX
#error "esp-zig lwIP Runtime requires LWIP_NETCONN_FULLDUPLEX=1"
#endif

typedef struct {
    uint8_t is_ipv6;
    uint8_t bytes[16];
    uint32_t zone;
} espz_lwip_ip_addr_t;

typedef struct {
    uintptr_t id;
    char name[32];
    size_t name_len;
    uint8_t up;
    uint8_t is_default;
    int route_prio;
    uint8_t has_ipv4;
    uint8_t ipv4[4];
    uint8_t gateway[4];
    uint8_t netmask[4];
} espz_netif_info_t;

extern void espz_lwip_runtime_on_event(void *ctx, int event, uint16_t len);

static void espz_lwip_netconn_callback(struct netconn *conn, enum netconn_evt event, uint16_t len)
{
    espz_lwip_runtime_on_event(netconn_get_callback_arg(conn), (int)event, len);
}

static void espz_lwip_to_ip_addr(ip_addr_t *out, const espz_lwip_ip_addr_t *in)
{
    if (in->is_ipv6 != 0U) {
        IP_ADDR6(out,
            lwip_htonl(((uint32_t)in->bytes[0] << 24) | ((uint32_t)in->bytes[1] << 16) | ((uint32_t)in->bytes[2] << 8) | in->bytes[3]),
            lwip_htonl(((uint32_t)in->bytes[4] << 24) | ((uint32_t)in->bytes[5] << 16) | ((uint32_t)in->bytes[6] << 8) | in->bytes[7]),
            lwip_htonl(((uint32_t)in->bytes[8] << 24) | ((uint32_t)in->bytes[9] << 16) | ((uint32_t)in->bytes[10] << 8) | in->bytes[11]),
            lwip_htonl(((uint32_t)in->bytes[12] << 24) | ((uint32_t)in->bytes[13] << 16) | ((uint32_t)in->bytes[14] << 8) | in->bytes[15]));
        ip6_addr_set_zone(ip_2_ip6(out), (uint8_t)in->zone);
    } else {
        IP_ADDR4(out, in->bytes[0], in->bytes[1], in->bytes[2], in->bytes[3]);
    }
}

static void espz_lwip_from_ip_addr(espz_lwip_ip_addr_t *out, const ip_addr_t *in)
{
    memset(out, 0, sizeof(*out));
    if (IP_IS_V6(in)) {
        const ip6_addr_t *addr = ip_2_ip6(in);
        out->is_ipv6 = 1U;
        for (size_t word = 0; word < 4; word++) {
            const uint32_t value = lwip_htonl(addr->addr[word]);
            out->bytes[word * 4 + 0] = (uint8_t)(value >> 24);
            out->bytes[word * 4 + 1] = (uint8_t)(value >> 16);
            out->bytes[word * 4 + 2] = (uint8_t)(value >> 8);
            out->bytes[word * 4 + 3] = (uint8_t)value;
        }
        out->zone = ip6_addr_zone(addr);
    } else {
        const uint32_t value = ip_2_ip4(in)->addr;
        out->bytes[0] = ip4_addr1(ip_2_ip4(in));
        out->bytes[1] = ip4_addr2(ip_2_ip4(in));
        out->bytes[2] = ip4_addr3(ip_2_ip4(in));
        out->bytes[3] = ip4_addr4(ip_2_ip4(in));
        (void)value;
    }
}

struct netconn *espz_lwip_netconn_new(uint32_t netconn_type, void *ctx)
{
    struct netconn *conn = netconn_new_with_callback((enum netconn_type)netconn_type, espz_lwip_netconn_callback);
    if (conn == NULL) {
        return NULL;
    }
    netconn_set_callback_arg(conn, ctx);
    netconn_set_nonblocking(conn, 1);
    return conn;
}

void espz_lwip_netconn_set_callback_arg(struct netconn *conn, void *ctx)
{
    netconn_set_callback_arg(conn, ctx);
}

void espz_lwip_netconn_set_nonblocking(struct netconn *conn, uint32_t enabled)
{
    netconn_set_nonblocking(conn, enabled != 0U);
}

int espz_lwip_netconn_delete(struct netconn *conn)
{
    return (int)netconn_delete(conn);
}

int espz_lwip_netconn_close(struct netconn *conn)
{
    return (int)netconn_close(conn);
}

int espz_lwip_netconn_shutdown(struct netconn *conn, uint32_t shut_rx, uint32_t shut_tx)
{
    return (int)netconn_shutdown(conn, (uint8_t)shut_rx, (uint8_t)shut_tx);
}

int espz_lwip_netconn_bind(struct netconn *conn, const espz_lwip_ip_addr_t *addr, uint16_t port)
{
    ip_addr_t ip;
    espz_lwip_to_ip_addr(&ip, addr);
    return (int)netconn_bind(conn, &ip, port);
}

int espz_lwip_netconn_connect(struct netconn *conn, const espz_lwip_ip_addr_t *addr, uint16_t port)
{
    ip_addr_t ip;
    espz_lwip_to_ip_addr(&ip, addr);
    return (int)netconn_connect(conn, &ip, port);
}

int espz_lwip_netconn_listen(struct netconn *conn, uint32_t backlog)
{
    return (int)netconn_listen_with_backlog(conn, (uint8_t)backlog);
}

int espz_lwip_netconn_accept(struct netconn *conn, struct netconn **out)
{
    return (int)netconn_accept(conn, out);
}

int espz_lwip_netconn_recv(struct netconn *conn, struct netbuf **out)
{
    return (int)netconn_recv(conn, out);
}

int espz_lwip_netconn_write(struct netconn *conn, const void *data, size_t len, size_t *written)
{
    return (int)netconn_write_partly(conn, data, len, NETCONN_COPY, written);
}

int espz_lwip_netconn_send_to(struct netconn *conn, const void *data, size_t len, const espz_lwip_ip_addr_t *addr, uint16_t port)
{
    if (len > UINT16_MAX) {
        return (int)ERR_VAL;
    }
    struct netbuf *buf = netbuf_new();
    if (buf == NULL) {
        return (int)ERR_MEM;
    }
    void *dst = netbuf_alloc(buf, (uint16_t)len);
    if (dst == NULL) {
        netbuf_delete(buf);
        return (int)ERR_MEM;
    }
    memcpy(dst, data, len);

    ip_addr_t ip;
    espz_lwip_to_ip_addr(&ip, addr);
    const int rc = (int)netconn_sendto(conn, buf, &ip, port);
    netbuf_delete(buf);
    return rc;
}

int espz_lwip_netconn_send(struct netconn *conn, const void *data, size_t len)
{
    if (len > UINT16_MAX) {
        return (int)ERR_VAL;
    }
    struct netbuf *buf = netbuf_new();
    if (buf == NULL) {
        return (int)ERR_MEM;
    }
    void *dst = netbuf_alloc(buf, (uint16_t)len);
    if (dst == NULL) {
        netbuf_delete(buf);
        return (int)ERR_MEM;
    }
    memcpy(dst, data, len);

    const int rc = (int)netconn_send(conn, buf);
    netbuf_delete(buf);
    return rc;
}

int espz_lwip_netconn_get_addr(struct netconn *conn, uint32_t local, espz_lwip_ip_addr_t *addr, uint16_t *port)
{
    ip_addr_t ip;
    const int rc = (int)netconn_getaddr(conn, &ip, port, (uint8_t)local);
    if (rc == ERR_OK) {
        espz_lwip_from_ip_addr(addr, &ip);
    }
    return rc;
}

int espz_lwip_netconn_err(struct netconn *conn)
{
    return (int)netconn_err(conn);
}

void espz_lwip_netbuf_delete(struct netbuf *buf)
{
    netbuf_delete(buf);
}

size_t espz_lwip_netbuf_len(struct netbuf *buf)
{
    return (size_t)netbuf_len(buf);
}

size_t espz_lwip_netbuf_copy(struct netbuf *buf, size_t offset, void *dst, size_t len)
{
    return (size_t)netbuf_copy_partial(buf, dst, len, offset);
}

void espz_lwip_netbuf_from_addr(struct netbuf *buf, espz_lwip_ip_addr_t *addr, uint16_t *port)
{
    espz_lwip_from_ip_addr(addr, netbuf_fromaddr(buf));
    *port = netbuf_fromport(buf);
}

int espz_lwip_netconn_set_socket_reuse_addr(struct netconn *conn, int enabled)
{
    if (conn == NULL || conn->pcb.ip == NULL) {
        return (int)ERR_VAL;
    }
    if (enabled != 0) {
        ip_set_option(conn->pcb.ip, SOF_REUSEADDR);
    } else {
        ip_reset_option(conn->pcb.ip, SOF_REUSEADDR);
    }
    return (int)ERR_OK;
}

int espz_lwip_netconn_set_socket_broadcast(struct netconn *conn, int enabled)
{
#if IP_SOF_BROADCAST
    if (conn == NULL || conn->pcb.ip == NULL) {
        return (int)ERR_VAL;
    }
    if (enabled != 0) {
        ip_set_option(conn->pcb.ip, SOF_BROADCAST);
    } else {
        ip_reset_option(conn->pcb.ip, SOF_BROADCAST);
    }
    return (int)ERR_OK;
#else
    (void)conn;
    (void)enabled;
    return (int)ERR_VAL;
#endif
}

int espz_lwip_netconn_set_tcp_no_delay(struct netconn *conn, int enabled)
{
    if (conn == NULL || conn->pcb.tcp == NULL) {
        return (int)ERR_VAL;
    }
    if (enabled != 0) {
        tcp_nagle_disable(conn->pcb.tcp);
    } else {
        tcp_nagle_enable(conn->pcb.tcp);
    }
    return (int)ERR_OK;
}

static void espz_netif_fill_ip4(uint8_t out[4], esp_ip4_addr_t addr)
{
    out[0] = esp_ip4_addr1(&addr);
    out[1] = esp_ip4_addr2(&addr);
    out[2] = esp_ip4_addr3(&addr);
    out[3] = esp_ip4_addr4(&addr);
}

static esp_netif_t *espz_netif_find_by_id(uintptr_t id)
{
    esp_netif_t *netif = NULL;
    while ((netif = esp_netif_next_unsafe(netif)) != NULL) {
        if ((uintptr_t)netif == id) {
            return netif;
        }
    }
    return NULL;
}

size_t espz_netif_list(espz_netif_info_t *out, size_t cap)
{
    size_t count = 0;
    esp_netif_t *default_netif = esp_netif_get_default_netif();
    esp_netif_t *netif = NULL;
    while ((netif = esp_netif_next_unsafe(netif)) != NULL) {
        if (count >= cap) {
            return count + 1;
        }

        espz_netif_info_t *info = &out[count];
        memset(info, 0, sizeof(*info));
        info->id = (uintptr_t)netif;
        info->up = esp_netif_is_netif_up(netif) ? 1U : 0U;
        info->is_default = (netif == default_netif) ? 1U : 0U;
        info->route_prio = esp_netif_get_route_prio(netif);

        const char *desc = esp_netif_get_desc(netif);
        if (desc != NULL) {
            size_t len = strnlen(desc, sizeof(info->name));
            memcpy(info->name, desc, len);
            info->name_len = len;
        }

        esp_netif_ip_info_t ip;
        if (esp_netif_get_ip_info(netif, &ip) == ESP_OK && ip.ip.addr != 0) {
            info->has_ipv4 = 1U;
            espz_netif_fill_ip4(info->ipv4, ip.ip);
            espz_netif_fill_ip4(info->gateway, ip.gw);
            espz_netif_fill_ip4(info->netmask, ip.netmask);
        }
        count++;
    }
    return count;
}

int espz_netif_get_default(uintptr_t *out_id)
{
    esp_netif_t *netif = esp_netif_get_default_netif();
    if (netif == NULL) {
        *out_id = 0;
        return 0;
    }
    *out_id = (uintptr_t)netif;
    return 0;
}

int espz_netif_set_default(uintptr_t id)
{
    esp_netif_t *netif = espz_netif_find_by_id(id);
    if (netif == NULL) {
        return -2;
    }
    return esp_netif_set_default_netif(netif) == ESP_OK ? 0 : -3;
}
