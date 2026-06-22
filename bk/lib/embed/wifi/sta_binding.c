#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include <common/bk_err.h>
#include <components/event.h>
#include <components/netif.h>
#include <components/netif_types.h>
#include <modules/wifi.h>
#include "wifi_api.h"

#define BK_EMBED_WIFI_OK 0
#define BK_EMBED_WIFI_INVALID_ARG 1
#define BK_EMBED_WIFI_INVALID_STATE 2
#define BK_EMBED_WIFI_NO_MEM 3
#define BK_EMBED_WIFI_UNEXPECTED 9

#define BK_EMBED_WIFI_STATE_IDLE 0
#define BK_EMBED_WIFI_STATE_CONNECTING 1
#define BK_EMBED_WIFI_STATE_CONNECTED 2
#define BK_EMBED_WIFI_STATE_SCANNING 3

#define BK_EMBED_WIFI_EVENT_CONNECTED 1
#define BK_EMBED_WIFI_EVENT_DISCONNECTED 2
#define BK_EMBED_WIFI_EVENT_GOT_IP 3
#define BK_EMBED_WIFI_EVENT_LOST_IP 4
#define BK_EMBED_WIFI_EVENT_SCAN_RESULT 5

#define BK_EMBED_WIFI_SECURITY_UNKNOWN 0
#define BK_EMBED_WIFI_SECURITY_OPEN 1
#define BK_EMBED_WIFI_SECURITY_WEP 2
#define BK_EMBED_WIFI_SECURITY_WPA 3
#define BK_EMBED_WIFI_SECURITY_WPA2 4
#define BK_EMBED_WIFI_SECURITY_WPA3 5

#define BK_EMBED_WIFI_POWER_SAVE_NONE 0
#define BK_EMBED_WIFI_POWER_SAVE_DEFAULT 1
#define BK_EMBED_WIFI_POWER_SAVE_LISTEN_INTERVAL 2

typedef struct {
    int event;
    uint8_t ssid[32];
    size_t ssid_len;
    uint8_t bssid[6];
    uint8_t channel;
    int16_t rssi;
    int security;
    uint16_t reason;
    uint8_t ip[4];
    uint8_t gateway[4];
    uint8_t netmask[4];
    uint8_t dns1[4];
} bk_embed_wifi_sta_event_t;

typedef void (*bk_embed_wifi_sta_event_cb_t)(void *ctx, const bk_embed_wifi_sta_event_t *event);

static bool s_registered;
static bool s_started;
static int s_state = BK_EMBED_WIFI_STATE_IDLE;
static int s_power_save = BK_EMBED_WIFI_POWER_SAVE_DEFAULT;
static uint16_t s_listen_interval;
static bk_embed_wifi_sta_event_cb_t s_event_cb;
static void *s_event_ctx;

static int map_rc(bk_err_t rc)
{
    if (rc == BK_OK) {
        return BK_EMBED_WIFI_OK;
    }
    if (rc == BK_ERR_NULL_PARAM || rc == BK_ERR_PARAM) {
        return BK_EMBED_WIFI_INVALID_ARG;
    }
    return BK_EMBED_WIFI_UNEXPECTED;
}

static size_t bounded_strlen(const char *text, size_t max_len)
{
    size_t len = 0;
    while (len < max_len && text[len] != '\0') {
        len++;
    }
    return len;
}

static void copy_bytes(uint8_t *dst, const void *src, size_t len)
{
    if (len > 0) {
        memcpy(dst, src, len);
    }
}

static void copy_ssid(uint8_t dst[32], size_t *dst_len, const char *ssid)
{
    size_t len = bounded_strlen(ssid, 32);
    memset(dst, 0, 32);
    copy_bytes(dst, ssid, len);
    *dst_len = len;
}

static int map_security(wifi_security_t security)
{
    switch (security) {
    case WIFI_SECURITY_NONE:
        return BK_EMBED_WIFI_SECURITY_OPEN;
    case WIFI_SECURITY_WEP:
        return BK_EMBED_WIFI_SECURITY_WEP;
    case WIFI_SECURITY_WPA_TKIP:
    case WIFI_SECURITY_WPA_AES:
    case WIFI_SECURITY_WPA_MIXED:
        return BK_EMBED_WIFI_SECURITY_WPA;
    case WIFI_SECURITY_WPA2_TKIP:
    case WIFI_SECURITY_WPA2_AES:
    case WIFI_SECURITY_WPA2_MIXED:
        return BK_EMBED_WIFI_SECURITY_WPA2;
    case WIFI_SECURITY_WPA3_SAE:
    case WIFI_SECURITY_WPA3_WPA2_MIXED:
        return BK_EMBED_WIFI_SECURITY_WPA3;
    default:
        return BK_EMBED_WIFI_SECURITY_UNKNOWN;
    }
}

static bool parse_ip4(const char *text, uint8_t out[4])
{
    uint32_t parts[4] = {0, 0, 0, 0};
    int part = 0;
    bool have_digit = false;

    for (const char *p = text; *p != '\0'; p++) {
        if (*p >= '0' && *p <= '9') {
            have_digit = true;
            parts[part] = parts[part] * 10 + (uint32_t)(*p - '0');
            if (parts[part] > 255) {
                return false;
            }
        } else if (*p == '.') {
            if (!have_digit || part == 3) {
                return false;
            }
            part++;
            have_digit = false;
        } else {
            return false;
        }
    }

    if (!have_digit || part != 3) {
        return false;
    }

    for (int i = 0; i < 4; i++) {
        out[i] = (uint8_t)parts[i];
    }
    return true;
}

static bool fill_ip_info(bk_embed_wifi_sta_event_t *event)
{
    netif_ip4_config_t config = {0};
    if (bk_netif_get_ip4_config(NETIF_IF_STA, &config) != BK_OK) {
        return false;
    }
    return parse_ip4(config.ip, event->ip)
        && parse_ip4(config.gateway, event->gateway)
        && parse_ip4(config.mask, event->netmask)
        && parse_ip4(config.dns, event->dns1);
}

static void emit_event(const bk_embed_wifi_sta_event_t *event)
{
    if (s_event_cb != NULL) {
        s_event_cb(s_event_ctx, event);
    }
}

static void emit_link_event(int event_id)
{
    wifi_link_status_t link_status = {0};
    bk_embed_wifi_sta_event_t event = {0};
    event.event = event_id;

    if (bk_wifi_sta_get_link_status(&link_status) == BK_OK) {
        copy_ssid(event.ssid, &event.ssid_len, link_status.ssid);
        memcpy(event.bssid, link_status.bssid, sizeof(event.bssid));
        event.channel = link_status.channel;
        event.rssi = (int16_t)link_status.rssi;
        event.security = map_security(link_status.security);
    }

    emit_event(&event);
}

static void emit_scan_results(void)
{
    wifi_scan_result_t result = {0};
    if (bk_wifi_scan_get_result(&result) != BK_OK) {
        return;
    }

    for (int i = 0; i < result.ap_num; i++) {
        const wifi_scan_ap_info_t *ap = &result.aps[i];
        bk_embed_wifi_sta_event_t event = {0};
        event.event = BK_EMBED_WIFI_EVENT_SCAN_RESULT;
        copy_ssid(event.ssid, &event.ssid_len, ap->ssid);
        memcpy(event.bssid, ap->bssid, sizeof(event.bssid));
        event.channel = ap->channel;
        event.rssi = (int16_t)ap->rssi;
        event.security = map_security(ap->security);
        emit_event(&event);
    }

    bk_wifi_scan_free_result(&result);
}

static bk_err_t wifi_event_cb(void *arg, event_module_t event_module, int event_id, void *event_data)
{
    (void)arg;
    (void)event_data;
    if (event_module != EVENT_MOD_WIFI) {
        return BK_OK;
    }

    switch (event_id) {
    case EVENT_WIFI_SCAN_DONE:
        emit_scan_results();
        if (s_state == BK_EMBED_WIFI_STATE_SCANNING) {
            s_state = s_started ? BK_EMBED_WIFI_STATE_CONNECTED : BK_EMBED_WIFI_STATE_IDLE;
        }
        break;
    case EVENT_WIFI_STA_CONNECTED:
        s_state = BK_EMBED_WIFI_STATE_CONNECTED;
        emit_link_event(BK_EMBED_WIFI_EVENT_CONNECTED);
        break;
    case EVENT_WIFI_STA_DISCONNECTED: {
        wifi_event_sta_disconnected_t *disconnected = (wifi_event_sta_disconnected_t *)event_data;
        bk_embed_wifi_sta_event_t event = {0};
        s_state = BK_EMBED_WIFI_STATE_IDLE;
        event.event = BK_EMBED_WIFI_EVENT_DISCONNECTED;
        if (disconnected != NULL) {
            event.reason = (uint16_t)disconnected->disconnect_reason;
        }
        emit_event(&event);
        break;
    }
    default:
        break;
    }
    return BK_OK;
}

static bk_err_t netif_event_cb(void *arg, event_module_t event_module, int event_id, void *event_data)
{
    (void)arg;
    if (event_module != EVENT_MOD_NETIF) {
        return BK_OK;
    }

    switch (event_id) {
    case EVENT_NETIF_GOT_IP4: {
        netif_event_got_ip4_t *got_ip = (netif_event_got_ip4_t *)event_data;
        if (got_ip != NULL && got_ip->netif_if != NETIF_IF_STA) {
            break;
        }
        bk_embed_wifi_sta_event_t event = {0};
        event.event = BK_EMBED_WIFI_EVENT_GOT_IP;
        if (fill_ip_info(&event)) {
            emit_event(&event);
        }
        break;
    }
    case EVENT_NETIF_DHCP_TIMEOUT: {
        bk_embed_wifi_sta_event_t event = {0};
        event.event = BK_EMBED_WIFI_EVENT_LOST_IP;
        emit_event(&event);
        break;
    }
    default:
        break;
    }
    return BK_OK;
}

int bk_embed_wifi_sta_init(void)
{
    if (!s_registered) {
        bk_err_t rc = bk_event_register_cb(EVENT_MOD_WIFI, EVENT_ID_ALL, wifi_event_cb, NULL);
        if (rc != BK_OK && rc != BK_ERR_EVENT_CB_EXIST) {
            return map_rc(rc);
        }
        rc = bk_event_register_cb(EVENT_MOD_NETIF, EVENT_ID_ALL, netif_event_cb, NULL);
        if (rc != BK_OK && rc != BK_ERR_EVENT_CB_EXIST) {
            return map_rc(rc);
        }
        s_registered = true;
    }
    return BK_EMBED_WIFI_OK;
}

void bk_embed_wifi_sta_set_event_handler(void *ctx, bk_embed_wifi_sta_event_cb_t cb)
{
    s_event_ctx = ctx;
    s_event_cb = cb;
}

int bk_embed_wifi_sta_start_scan(const uint8_t *ssid_ptr, size_t ssid_len, uint8_t channel, bool active, uint32_t timeout_ms)
{
    if (ssid_len > 32) {
        return BK_EMBED_WIFI_INVALID_ARG;
    }

    wifi_scan_config_t config = {0};
    if (ssid_len > 0) {
        memcpy(config.ssid, ssid_ptr, ssid_len);
    }
    config.scan_type = active ? 0 : 1;
    if (channel != 0) {
        config.chan_cnt = 1;
        config.chan_nb[0] = channel;
    }
    config.duration = timeout_ms;

    s_state = BK_EMBED_WIFI_STATE_SCANNING;
    int rc = map_rc(bk_wifi_scan_start(&config));
    if (rc != BK_EMBED_WIFI_OK) {
        s_state = s_started ? BK_EMBED_WIFI_STATE_CONNECTED : BK_EMBED_WIFI_STATE_IDLE;
    }
    return rc;
}

void bk_embed_wifi_sta_stop_scan(void)
{
    (void)bk_wifi_scan_stop();
    if (s_state == BK_EMBED_WIFI_STATE_SCANNING) {
        s_state = s_started ? BK_EMBED_WIFI_STATE_CONNECTED : BK_EMBED_WIFI_STATE_IDLE;
    }
}

int bk_embed_wifi_sta_connect(
    const uint8_t *ssid_ptr,
    size_t ssid_len,
    const uint8_t *password_ptr,
    size_t password_len,
    const uint8_t (*bssid_ptr)[6],
    uint8_t channel)
{
    if (ssid_len == 0 || ssid_len > 32 || password_len > 64) {
        return BK_EMBED_WIFI_INVALID_ARG;
    }

    wifi_sta_config_t config = {0};
    memcpy(config.ssid, ssid_ptr, ssid_len);
    memcpy(config.password, password_ptr, password_len);
    if (bssid_ptr != NULL) {
        memcpy(config.bssid, *bssid_ptr, sizeof(config.bssid));
    }
    config.channel = channel;
    config.security = password_len == 0 ? WIFI_SECURITY_NONE : WIFI_SECURITY_AUTO;

    int rc = map_rc(bk_wifi_sta_set_config(&config));
    if (rc != BK_EMBED_WIFI_OK) {
        return rc;
    }

    s_state = BK_EMBED_WIFI_STATE_CONNECTING;
    if (!s_started) {
        rc = map_rc(bk_wifi_sta_start());
        if (rc == BK_EMBED_WIFI_OK) {
            s_started = true;
        }
    } else {
        rc = map_rc(bk_wifi_sta_connect());
    }
    if (rc != BK_EMBED_WIFI_OK) {
        s_state = BK_EMBED_WIFI_STATE_IDLE;
    }
    return rc;
}

void bk_embed_wifi_sta_disconnect(void)
{
    (void)bk_wifi_sta_disconnect();
    s_state = BK_EMBED_WIFI_STATE_IDLE;
}

int bk_embed_wifi_sta_state(void)
{
    return s_state;
}

int bk_embed_wifi_sta_set_power_save(int mode, uint16_t listen_interval)
{
    bk_err_t rc = BK_OK;
    switch (mode) {
    case BK_EMBED_WIFI_POWER_SAVE_NONE:
        rc = bk_wifi_sta_pm_disable();
        break;
    case BK_EMBED_WIFI_POWER_SAVE_DEFAULT:
        rc = bk_wifi_sta_pm_enable();
        break;
    case BK_EMBED_WIFI_POWER_SAVE_LISTEN_INTERVAL:
        if (listen_interval == 0 || listen_interval > UINT8_MAX) {
            return BK_EMBED_WIFI_INVALID_ARG;
        }
        rc = bk_wifi_sta_pm_enable();
        if (rc == BK_OK) {
            rc = bk_wifi_send_listen_interval_req((uint8_t)listen_interval);
        }
        break;
    default:
        return BK_EMBED_WIFI_INVALID_ARG;
    }

    if (rc != BK_OK) {
        return map_rc(rc);
    }
    s_power_save = mode;
    s_listen_interval = listen_interval;
    return BK_EMBED_WIFI_OK;
}

int bk_embed_wifi_sta_get_power_save(int *mode, uint16_t *listen_interval)
{
    if (mode == NULL || listen_interval == NULL) {
        return BK_EMBED_WIFI_INVALID_ARG;
    }
    *mode = s_power_save;
    *listen_interval = s_listen_interval;
    return BK_EMBED_WIFI_OK;
}

int bk_embed_wifi_sta_get_mac(uint8_t (*mac)[6])
{
    if (mac == NULL) {
        return BK_EMBED_WIFI_INVALID_ARG;
    }
    return map_rc(bk_wifi_sta_get_mac(*mac));
}

int bk_embed_wifi_sta_get_ip_info(uint8_t (*ip)[4], uint8_t (*gateway)[4], uint8_t (*netmask)[4], uint8_t (*dns1)[4])
{
    if (ip == NULL || gateway == NULL || netmask == NULL || dns1 == NULL) {
        return BK_EMBED_WIFI_INVALID_ARG;
    }
    bk_embed_wifi_sta_event_t event = {0};
    if (!fill_ip_info(&event)) {
        return BK_EMBED_WIFI_UNEXPECTED;
    }
    memcpy(*ip, event.ip, 4);
    memcpy(*gateway, event.gateway, 4);
    memcpy(*netmask, event.netmask, 4);
    memcpy(*dns1, event.dns1, 4);
    return BK_EMBED_WIFI_OK;
}

__attribute__((weak)) void wifi_netif_call_status_cb_when_sta_dhcp_timeout(void)
{
}

__attribute__((weak)) void wifi_netif_notify_sta_disconnect(void)
{
    netif_event_got_ip4_t event_data = {0};
    event_data.netif_if = NETIF_IF_STA;
    (void)bk_event_post(EVENT_MOD_NETIF, EVENT_NETIF_DHCP_TIMEOUT,
                        &event_data, sizeof(event_data), BEKEN_NEVER_TIMEOUT);
    (void)bk_wifi_sta_disconnect();
}
