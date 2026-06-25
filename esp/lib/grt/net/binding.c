#include <stddef.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "esp_err.h"
#include "esp_event.h"
#include "esp_heap_caps.h"
#include "esp_idf_version.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_netif_defaults.h"
#include "esp_netif_net_stack.h"
#include "esp_netif_ppp.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
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

typedef struct {
    esp_netif_driver_base_t base;
    esp_netif_t *netif;
    void *ctx;
#ifdef CONFIG_PPP_SUPPORT
    EventGroupHandle_t events;
    esp_event_handler_instance_t ppp_event_instance;
#endif
} espz_modem_ppp_t;

extern void espz_lwip_runtime_on_event(void *ctx, int event, uint16_t len);
extern int espz_modem_ppp_write(void *ctx, const uint8_t *data, size_t len, size_t *written);

#define ESPZ_LWIP_SEND_DIAG_ENABLED 0

#if ESPZ_LWIP_SEND_DIAG_ENABLED
static const char *const espz_lwip_tag = "espz_lwip";

typedef struct {
    uint32_t count;
    uint64_t bytes;
    uint64_t total_us;
    uint64_t new_us;
    uint64_t alloc_us;
    uint64_t copy_us;
    uint64_t send_us;
    uint64_t delete_us;
} espz_lwip_send_diag_t;

static espz_lwip_send_diag_t espz_lwip_sendto_diag;

static int64_t espz_lwip_now_us(void)
{
    return esp_timer_get_time();
}

static uint64_t espz_lwip_elapsed_us(int64_t start)
{
    const int64_t end = esp_timer_get_time();
    return end > start ? (uint64_t)(end - start) : 0;
}

static void espz_lwip_send_diag_log(const char *name, espz_lwip_send_diag_t *diag)
{
    if (diag->count == 0 || diag->count % 1000 != 0) {
        return;
    }
    ESP_LOGI(
        espz_lwip_tag,
        "%s count=%" PRIu32 " bytes=%" PRIu64 " avg_us total=%" PRIu64 " new=%" PRIu64 " alloc=%" PRIu64 " copy=%" PRIu64 " send=%" PRIu64 " delete=%" PRIu64,
        name,
        diag->count,
        diag->bytes,
        diag->total_us / diag->count,
        diag->new_us / diag->count,
        diag->alloc_us / diag->count,
        diag->copy_us / diag->count,
        diag->send_us / diag->count,
        diag->delete_us / diag->count
    );
}
#endif

static esp_err_t espz_ok_if_already_initialized(esp_err_t err)
{
    return err == ESP_ERR_INVALID_STATE ? ESP_OK : err;
}

int espz_lwip_runtime_init(void)
{
    return (int)espz_ok_if_already_initialized(esp_netif_init());
}

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

int espz_lwip_netconn_set_recvbuf_size(struct netconn *conn, int size)
{
#if LWIP_SO_RCVBUF
    if (conn == NULL || size < 0) {
        return (int)ERR_VAL;
    }
    netconn_set_recvbufsize(conn, size);
    return (int)ERR_OK;
#else
    (void)conn;
    (void)size;
    return (int)ERR_VAL;
#endif
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
#if ESPZ_LWIP_SEND_DIAG_ENABLED
    const int64_t total_start = espz_lwip_now_us();
    int64_t stage_start = total_start;
    uint64_t new_us = 0;
    uint64_t alloc_us = 0;
    uint64_t copy_us = 0;
    uint64_t send_us = 0;
    uint64_t delete_us = 0;
#endif
    struct netbuf *buf = netbuf_new();
#if ESPZ_LWIP_SEND_DIAG_ENABLED
    new_us = espz_lwip_elapsed_us(stage_start);
    stage_start = espz_lwip_now_us();
#endif
    if (buf == NULL) {
        return (int)ERR_MEM;
    }
    void *dst = netbuf_alloc(buf, (uint16_t)len);
#if ESPZ_LWIP_SEND_DIAG_ENABLED
    alloc_us = espz_lwip_elapsed_us(stage_start);
    stage_start = espz_lwip_now_us();
#endif
    if (dst == NULL) {
        netbuf_delete(buf);
        return (int)ERR_MEM;
    }
    memcpy(dst, data, len);
#if ESPZ_LWIP_SEND_DIAG_ENABLED
    copy_us = espz_lwip_elapsed_us(stage_start);
    stage_start = espz_lwip_now_us();
#endif

    ip_addr_t ip;
    espz_lwip_to_ip_addr(&ip, addr);
    const int rc = (int)netconn_sendto(conn, buf, &ip, port);
#if ESPZ_LWIP_SEND_DIAG_ENABLED
    send_us = espz_lwip_elapsed_us(stage_start);
    stage_start = espz_lwip_now_us();
#endif
    netbuf_delete(buf);
#if ESPZ_LWIP_SEND_DIAG_ENABLED
    delete_us = espz_lwip_elapsed_us(stage_start);
    espz_lwip_sendto_diag.count += 1;
    espz_lwip_sendto_diag.bytes += len;
    espz_lwip_sendto_diag.total_us += espz_lwip_elapsed_us(total_start);
    espz_lwip_sendto_diag.new_us += new_us;
    espz_lwip_sendto_diag.alloc_us += alloc_us;
    espz_lwip_sendto_diag.copy_us += copy_us;
    espz_lwip_sendto_diag.send_us += send_us;
    espz_lwip_sendto_diag.delete_us += delete_us;
    espz_lwip_send_diag_log("sendto", &espz_lwip_sendto_diag);
#endif
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

int espz_lwip_netconn_bind_default_netif(struct netconn *conn, uintptr_t *out_id, uint8_t *out_if_idx)
{
    if (conn == NULL || out_id == NULL || out_if_idx == NULL) {
        return (int)ERR_ARG;
    }
    esp_netif_t *netif = esp_netif_get_default_netif();
    if (netif == NULL) {
        *out_id = 0;
        *out_if_idx = 0;
        return (int)ERR_RTE;
    }
    int if_idx = esp_netif_get_netif_impl_index(netif);
    if (if_idx <= 0 || if_idx > UINT8_MAX) {
        *out_id = (uintptr_t)netif;
        *out_if_idx = 0;
        return (int)ERR_IF;
    }
    *out_id = (uintptr_t)netif;
    *out_if_idx = (uint8_t)if_idx;
    return (int)netconn_bind_if(conn, (uint8_t)if_idx);
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
        return ESP_OK;
    }
    *out_id = (uintptr_t)netif;
    return ESP_OK;
}

int espz_netif_set_default(uintptr_t id)
{
    esp_netif_t *netif = espz_netif_find_by_id(id);
    if (netif == NULL) {
        return -2;
    }
    return esp_netif_set_default_netif(netif) == ESP_OK ? 0 : -3;
}

#ifdef CONFIG_PPP_SUPPORT
#define ESPZ_MODEM_PPP_STOPPED_BIT BIT0
#define ESPZ_MODEM_PPP_STARTED_BIT BIT1

static void espz_modem_ppp_on_status(void *arg, esp_event_base_t base, int32_t event_id, void *event_data)
{
    (void)base;
    espz_modem_ppp_t *ppp = (espz_modem_ppp_t *)arg;
    if (ppp == NULL || ppp->events == NULL || event_data == NULL) {
        return;
    }

    esp_netif_t *netif = *(esp_netif_t **)event_data;
    if (netif != ppp->netif) {
        return;
    }

    if (event_id == NETIF_PPP_ERRORUSER ||
        event_id == NETIF_PPP_ERRORCONNECT ||
        event_id == NETIF_PPP_CONNECT_FAILED ||
        event_id == NETIF_PPP_PHASE_DEAD ||
        event_id == NETIF_PPP_PHASE_DISCONNECT) {
        xEventGroupSetBits(ppp->events, ESPZ_MODEM_PPP_STOPPED_BIT);
    }
}

static esp_err_t espz_modem_ppp_transmit(void *handle, void *buffer, size_t len)
{
    espz_modem_ppp_t *ppp = (espz_modem_ppp_t *)handle;
    size_t written = 0;
    if (espz_modem_ppp_write(ppp->ctx, (const uint8_t *)buffer, len, &written) != 0) {
        return ESP_FAIL;
    }
    return written == len ? ESP_OK : ESP_FAIL;
}

static esp_err_t espz_modem_ppp_post_attach(esp_netif_t *netif, esp_netif_iodriver_handle handle)
{
    espz_modem_ppp_t *ppp = (espz_modem_ppp_t *)handle;
    ppp->base.netif = netif;
    ppp->netif = netif;

    esp_netif_driver_ifconfig_t driver_config = {
        .handle = ppp,
        .transmit = espz_modem_ppp_transmit,
        .transmit_wrap = NULL,
        .driver_free_rx_buffer = NULL,
#if ESP_IDF_VERSION >= ESP_IDF_VERSION_VAL(5, 5, 0)
        .driver_set_mac_filter = NULL,
#endif
    };
    return esp_netif_set_driver_config(netif, &driver_config);
}
#endif

espz_modem_ppp_t *espz_modem_ppp_create(void *ctx)
{
#ifdef CONFIG_PPP_SUPPORT
    espz_modem_ppp_t *ppp = calloc(1, sizeof(espz_modem_ppp_t));
    if (ppp == NULL) {
        return NULL;
    }

    ppp->events = xEventGroupCreate();
    if (ppp->events == NULL) {
        free(ppp);
        return NULL;
    }

    esp_netif_config_t netif_config = ESP_NETIF_DEFAULT_PPP();
    ppp->netif = esp_netif_new(&netif_config);
    if (ppp->netif == NULL) {
        vEventGroupDelete(ppp->events);
        free(ppp);
        return NULL;
    }

    esp_netif_ppp_config_t ppp_config = {
        .ppp_phase_event_enabled = true,
        .ppp_error_event_enabled = true,
    };
    if (esp_netif_ppp_set_params(ppp->netif, &ppp_config) != ESP_OK) {
        esp_netif_destroy(ppp->netif);
        vEventGroupDelete(ppp->events);
        free(ppp);
        return NULL;
    }
    if (esp_event_handler_instance_register(
            NETIF_PPP_STATUS,
            ESP_EVENT_ANY_ID,
            espz_modem_ppp_on_status,
            ppp,
            &ppp->ppp_event_instance) != ESP_OK) {
        esp_netif_destroy(ppp->netif);
        vEventGroupDelete(ppp->events);
        free(ppp);
        return NULL;
    }

    ppp->ctx = ctx;
    ppp->base.post_attach = espz_modem_ppp_post_attach;
    ppp->base.netif = ppp->netif;
    if (esp_netif_attach(ppp->netif, ppp) != ESP_OK) {
        esp_event_handler_instance_unregister(NETIF_PPP_STATUS, ESP_EVENT_ANY_ID, ppp->ppp_event_instance);
        esp_netif_destroy(ppp->netif);
        vEventGroupDelete(ppp->events);
        free(ppp);
        return NULL;
    }

    return ppp;
#else
    (void)ctx;
    return NULL;
#endif
}

int espz_modem_ppp_start(espz_modem_ppp_t *ppp)
{
#ifdef CONFIG_PPP_SUPPORT
    if (ppp == NULL || ppp->netif == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    if (ppp->events != NULL && (xEventGroupGetBits(ppp->events) & ESPZ_MODEM_PPP_STARTED_BIT) != 0) {
        return ESP_OK;
    }
    if (ppp->events != NULL) {
        xEventGroupClearBits(ppp->events, ESPZ_MODEM_PPP_STOPPED_BIT);
        xEventGroupSetBits(ppp->events, ESPZ_MODEM_PPP_STARTED_BIT);
    }
    esp_netif_action_start(ppp->netif, 0, 0, NULL);
    return ESP_OK;
#else
    (void)ppp;
    return ESP_ERR_NOT_SUPPORTED;
#endif
}

int espz_modem_ppp_stop(espz_modem_ppp_t *ppp)
{
#ifdef CONFIG_PPP_SUPPORT
    if (ppp == NULL || ppp->netif == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    if (ppp->events != NULL && (xEventGroupGetBits(ppp->events) & ESPZ_MODEM_PPP_STARTED_BIT) == 0) {
        return ESP_OK;
    }
    if (ppp->events != NULL) {
        xEventGroupClearBits(ppp->events, ESPZ_MODEM_PPP_STOPPED_BIT | ESPZ_MODEM_PPP_STARTED_BIT);
    }
    esp_netif_action_stop(ppp->netif, 0, 0, NULL);
    if (ppp->events != NULL) {
        (void)xEventGroupWaitBits(
            ppp->events,
            ESPZ_MODEM_PPP_STOPPED_BIT,
            pdFALSE,
            pdFALSE,
            pdMS_TO_TICKS(1500)
        );
    }
    return ESP_OK;
#else
    (void)ppp;
    return ESP_ERR_NOT_SUPPORTED;
#endif
}

void espz_modem_ppp_destroy(espz_modem_ppp_t *ppp)
{
    if (ppp == NULL) {
        return;
    }
#ifdef CONFIG_PPP_SUPPORT
    if (ppp->netif != NULL) {
        (void)espz_modem_ppp_stop(ppp);
        esp_event_handler_instance_unregister(NETIF_PPP_STATUS, ESP_EVENT_ANY_ID, ppp->ppp_event_instance);
        esp_netif_destroy(ppp->netif);
        ppp->netif = NULL;
    }
    if (ppp->events != NULL) {
        vEventGroupDelete(ppp->events);
        ppp->events = NULL;
    }
#endif
    free(ppp);
}

int espz_modem_ppp_input(espz_modem_ppp_t *ppp, const void *data, size_t len)
{
#ifdef CONFIG_PPP_SUPPORT
    if (ppp == NULL || ppp->netif == NULL || data == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    return esp_netif_receive(ppp->netif, (void *)data, len, NULL);
#else
    (void)ppp;
    (void)data;
    (void)len;
    return ESP_ERR_NOT_SUPPORTED;
#endif
}

int espz_modem_ppp_set_default(espz_modem_ppp_t *ppp)
{
#ifdef CONFIG_PPP_SUPPORT
    if (ppp == NULL || ppp->netif == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    return esp_netif_set_default_netif(ppp->netif);
#else
    (void)ppp;
    return ESP_ERR_NOT_SUPPORTED;
#endif
}

uintptr_t espz_modem_ppp_netif_id(espz_modem_ppp_t *ppp)
{
#ifdef CONFIG_PPP_SUPPORT
    if (ppp == NULL) {
        return 0;
    }
    return (uintptr_t)ppp->netif;
#else
    (void)ppp;
    return 0;
#endif
}
