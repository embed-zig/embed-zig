#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "esp_check.h"
#include "esp_err.h"
#include "esp_event.h"
#include "esp_mac.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "esp_wifi_default.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "nvs_flash.h"

#define ESP_EMBED_WIFI_STATE_IDLE 0
#define ESP_EMBED_WIFI_STATE_CONNECTING 1
#define ESP_EMBED_WIFI_STATE_CONNECTED 2
#define ESP_EMBED_WIFI_STATE_SCANNING 3

#define ESP_EMBED_WIFI_EVENT_CONNECTED 1
#define ESP_EMBED_WIFI_EVENT_DISCONNECTED 2
#define ESP_EMBED_WIFI_EVENT_GOT_IP 3
#define ESP_EMBED_WIFI_EVENT_LOST_IP 4
#define ESP_EMBED_WIFI_EVENT_SCAN_RESULT 5
#define ESP_EMBED_WIFI_EVENT_SCAN_DONE_INTERNAL 100

#define ESP_EMBED_WIFI_SECURITY_UNKNOWN 0
#define ESP_EMBED_WIFI_SECURITY_OPEN 1
#define ESP_EMBED_WIFI_SECURITY_WEP 2
#define ESP_EMBED_WIFI_SECURITY_WPA 3
#define ESP_EMBED_WIFI_SECURITY_WPA2 4
#define ESP_EMBED_WIFI_SECURITY_WPA3 5

#define ESP_EMBED_WIFI_POWER_SAVE_NONE 0
#define ESP_EMBED_WIFI_POWER_SAVE_DEFAULT 1
#define ESP_EMBED_WIFI_POWER_SAVE_LISTEN_INTERVAL 2

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
} esp_embed_wifi_sta_event_t;

typedef void (*esp_embed_wifi_sta_event_cb_t)(void *ctx, const esp_embed_wifi_sta_event_t *event);

static const char *TAG = "esp_embed_wifi_sta";
static esp_netif_t *s_wifi_netif;
static esp_event_handler_instance_t s_instance_any_id;
static esp_event_handler_instance_t s_instance_got_ip;
static esp_event_handler_instance_t s_instance_lost_ip;
static bool s_wifi_initialized;
static int s_wifi_state = ESP_EMBED_WIFI_STATE_IDLE;
static esp_embed_wifi_sta_event_cb_t s_event_cb;
static void *s_event_ctx;
static uint8_t s_scan_ssid[33];
static QueueHandle_t s_event_queue;
static TaskHandle_t s_event_task;
static wifi_ps_type_t s_power_save_type = WIFI_PS_MIN_MODEM;
static uint16_t s_power_save_listen_interval;
static bool s_wifi_started;

static int map_security(wifi_auth_mode_t authmode)
{
    switch (authmode) {
    case WIFI_AUTH_OPEN:
        return ESP_EMBED_WIFI_SECURITY_OPEN;
    case WIFI_AUTH_WEP:
        return ESP_EMBED_WIFI_SECURITY_WEP;
    case WIFI_AUTH_WPA_PSK:
        return ESP_EMBED_WIFI_SECURITY_WPA;
    case WIFI_AUTH_WPA2_PSK:
    case WIFI_AUTH_WPA_WPA2_PSK:
    case WIFI_AUTH_WPA2_ENTERPRISE:
        return ESP_EMBED_WIFI_SECURITY_WPA2;
    case WIFI_AUTH_WPA3_PSK:
    case WIFI_AUTH_WPA2_WPA3_PSK:
        return ESP_EMBED_WIFI_SECURITY_WPA3;
    default:
        return ESP_EMBED_WIFI_SECURITY_UNKNOWN;
    }
}

static const char *power_save_name(wifi_ps_type_t type)
{
    switch (type) {
    case WIFI_PS_NONE:
        return "none";
    case WIFI_PS_MIN_MODEM:
        return "min_modem";
    case WIFI_PS_MAX_MODEM:
        return "max_modem";
    default:
        return "unknown";
    }
}

static esp_err_t map_power_save(int mode, wifi_ps_type_t *out)
{
    ESP_RETURN_ON_FALSE(out != NULL, ESP_ERR_INVALID_ARG, TAG, "wifi power save output is null");
    switch (mode) {
    case ESP_EMBED_WIFI_POWER_SAVE_NONE:
        *out = WIFI_PS_NONE;
        return ESP_OK;
    case ESP_EMBED_WIFI_POWER_SAVE_DEFAULT:
        *out = WIFI_PS_MIN_MODEM;
        return ESP_OK;
    case ESP_EMBED_WIFI_POWER_SAVE_LISTEN_INTERVAL:
        *out = WIFI_PS_MAX_MODEM;
        return ESP_OK;
    default:
        return ESP_ERR_INVALID_ARG;
    }
}

static int unmap_power_save(wifi_ps_type_t type)
{
    switch (type) {
    case WIFI_PS_NONE:
        return ESP_EMBED_WIFI_POWER_SAVE_NONE;
    case WIFI_PS_MIN_MODEM:
        return ESP_EMBED_WIFI_POWER_SAVE_DEFAULT;
    case WIFI_PS_MAX_MODEM:
        return ESP_EMBED_WIFI_POWER_SAVE_LISTEN_INTERVAL;
    default:
        return -1;
    }
}

static const char *state_name(int state)
{
    switch (state) {
    case ESP_EMBED_WIFI_STATE_IDLE:
        return "idle";
    case ESP_EMBED_WIFI_STATE_CONNECTING:
        return "connecting";
    case ESP_EMBED_WIFI_STATE_CONNECTED:
        return "connected";
    case ESP_EMBED_WIFI_STATE_SCANNING:
        return "scanning";
    default:
        return "unknown";
    }
}

static void fill_ip4(uint8_t out[4], esp_ip4_addr_t addr)
{
    out[0] = esp_ip4_addr1(&addr);
    out[1] = esp_ip4_addr2(&addr);
    out[2] = esp_ip4_addr3(&addr);
    out[3] = esp_ip4_addr4(&addr);
}

static const char *dhcp_status_name(esp_netif_dhcp_status_t status)
{
    switch (status) {
    case ESP_NETIF_DHCP_INIT:
        return "init";
    case ESP_NETIF_DHCP_STARTED:
        return "started";
    case ESP_NETIF_DHCP_STOPPED:
        return "stopped";
    default:
        return "unknown";
    }
}

static const char *authmode_name(wifi_auth_mode_t authmode)
{
    switch (authmode) {
    case WIFI_AUTH_OPEN:
        return "open";
    case WIFI_AUTH_WEP:
        return "wep";
    case WIFI_AUTH_WPA_PSK:
        return "wpa_psk";
    case WIFI_AUTH_WPA2_PSK:
        return "wpa2_psk";
    case WIFI_AUTH_WPA_WPA2_PSK:
        return "wpa_wpa2_psk";
    case WIFI_AUTH_WPA2_ENTERPRISE:
        return "wpa2_enterprise";
    case WIFI_AUTH_WPA3_PSK:
        return "wpa3_psk";
    case WIFI_AUTH_WPA2_WPA3_PSK:
        return "wpa2_wpa3_psk";
    default:
        return "unknown";
    }
}

static const char *disconnect_reason_name(uint16_t reason)
{
    switch (reason) {
    case 1:
        return "unspecified";
    case 2:
        return "auth_expire";
    case 3:
        return "auth_leave";
    case 4:
        return "assoc_expire";
    case 5:
        return "assoc_toomany";
    case 6:
        return "not_authed";
    case 7:
        return "not_assoced";
    case 8:
        return "assoc_leave";
    case 9:
        return "assoc_not_authed";
    case 15:
        return "4way_handshake_timeout";
    case 16:
        return "group_key_update_timeout";
    case 23:
        return "802_1x_auth_failed";
    case 200:
        return "beacon_timeout";
    case 201:
        return "no_ap_found";
    case 202:
        return "auth_fail";
    case 203:
        return "assoc_fail";
    case 204:
        return "handshake_timeout";
    case 205:
        return "connection_fail";
    case 206:
        return "ap_tsf_reset";
    case 207:
        return "roaming";
    case 208:
        return "assoc_comeback_time_too_long";
    case 209:
        return "sa_query_timeout";
    case 210:
        return "no_ap_found_compatible_security";
    case 211:
        return "no_ap_found_authmode_threshold";
    case 212:
        return "no_ap_found_rssi_threshold";
    default:
        return "unknown";
    }
}

static void log_sta_ap_info(const char *where)
{
    wifi_ap_record_t ap = { 0 };
    esp_err_t rc = esp_wifi_sta_get_ap_info(&ap);
    if (rc != ESP_OK) {
        ESP_LOGI(TAG, "%s ap_info rc=%d state=%s", where, (int)rc, state_name(s_wifi_state));
        return;
    }

    size_t ssid_len = strnlen((const char *)ap.ssid, sizeof(ap.ssid));
    ESP_LOGI(
        TAG,
        "%s ap_info ssid='%.*s' bssid=" MACSTR " channel=%u rssi=%d auth=%s(%d)",
        where,
        (int)ssid_len,
        (const char *)ap.ssid,
        MAC2STR(ap.bssid),
        (unsigned)ap.primary,
        (int)ap.rssi,
        authmode_name(ap.authmode),
        (int)ap.authmode);
}

static void log_dhcp_status(const char *where)
{
    if (s_wifi_netif == NULL) {
        ESP_LOGW(TAG, "%s dhcp status unavailable: missing netif", where);
        return;
    }
    esp_netif_dhcp_status_t status = ESP_NETIF_DHCP_INIT;
    esp_err_t status_rc = esp_netif_dhcpc_get_status(s_wifi_netif, &status);
    esp_netif_ip_info_t ip = { 0 };
    esp_err_t ip_rc = esp_netif_get_ip_info(s_wifi_netif, &ip);
    ESP_LOGI(
        TAG,
        "%s dhcp_status rc=%d status=%s ip_rc=%d ip=" IPSTR " gw=" IPSTR " netmask=" IPSTR,
        where,
        (int)status_rc,
        status_rc == ESP_OK ? dhcp_status_name(status) : "error",
        (int)ip_rc,
        IP2STR(&ip.ip),
        IP2STR(&ip.gw),
        IP2STR(&ip.netmask));
}

static void emit_event(const esp_embed_wifi_sta_event_t *event)
{
    if (s_event_queue == NULL) {
        ESP_LOGW(TAG, "event queue missing drop event=%d", event == NULL ? 0 : event->event);
        return;
    }
    if (xQueueSend(s_event_queue, event, 0) != pdTRUE) {
        ESP_LOGW(TAG, "event queue full drop event=%d", event == NULL ? 0 : event->event);
    }
}

static void emit_scan_results(void);

static void event_task(void *arg)
{
    (void)arg;

    esp_embed_wifi_sta_event_t event;
    while (true) {
        if (xQueueReceive(s_event_queue, &event, portMAX_DELAY) == pdTRUE) {
            if (event.event == ESP_EMBED_WIFI_EVENT_SCAN_DONE_INTERNAL) {
                emit_scan_results();
                if (s_wifi_state == ESP_EMBED_WIFI_STATE_SCANNING) {
                    s_wifi_state = ESP_EMBED_WIFI_STATE_IDLE;
                }
                continue;
            }
            if (s_event_cb != NULL) {
                ESP_LOGI(TAG, "dispatch event=%d", event.event);
                s_event_cb(s_event_ctx, &event);
            } else {
                ESP_LOGW(TAG, "event callback missing drop event=%d", event.event);
            }
        }
    }
}

static void emit_scan_results(void)
{
    uint16_t count = 16;
    wifi_ap_record_t records[16] = { 0 };

    esp_err_t records_err = esp_wifi_scan_get_ap_records(&count, records);
    if (records_err != ESP_OK) {
        ESP_LOGW(TAG, "scan_get_ap_records failed rc=%d", (int)records_err);
        return;
    }

    ESP_LOGI(TAG, "scan results count=%u", (unsigned)count);

    for (uint16_t i = 0; i < count; i++) {
        esp_embed_wifi_sta_event_t report = { 0 };
        report.event = ESP_EMBED_WIFI_EVENT_SCAN_RESULT;
        size_t ssid_len = strnlen((const char *)records[i].ssid, sizeof(records[i].ssid));
        report.ssid_len = ssid_len > sizeof(report.ssid) ? sizeof(report.ssid) : ssid_len;
        memcpy(report.ssid, records[i].ssid, report.ssid_len);
        memcpy(report.bssid, records[i].bssid, sizeof(report.bssid));
        report.channel = records[i].primary;
        report.rssi = records[i].rssi;
        report.security = map_security(records[i].authmode);
        ESP_LOGI(
            TAG,
            "scan result ssid='%.*s' bssid=" MACSTR " channel=%u rssi=%d auth=%s(%d)",
            (int)report.ssid_len,
            (const char *)report.ssid,
            MAC2STR(report.bssid),
            (unsigned)report.channel,
            (int)report.rssi,
            authmode_name(records[i].authmode),
            (int)records[i].authmode);
        emit_event(&report);
    }
}

static void wifi_event_handler(void *arg, esp_event_base_t event_base, int32_t event_id, void *event_data)
{
    (void)arg;

    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_SCAN_DONE) {
        ESP_LOGI(TAG, "wifi event scan_done state=%s", state_name(s_wifi_state));
        esp_embed_wifi_sta_event_t event = { 0 };
        event.event = ESP_EMBED_WIFI_EVENT_SCAN_DONE_INTERNAL;
        emit_event(&event);
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_CONNECTED) {
        const wifi_event_sta_connected_t *event = (const wifi_event_sta_connected_t *)event_data;
        ESP_LOGI(
            TAG,
            "wifi event sta_connected prev_state=%s ssid='%.*s' bssid=" MACSTR " channel=%u auth=%s(%d)",
            state_name(s_wifi_state),
            event == NULL ? 0 : (int)event->ssid_len,
            event == NULL ? "" : (const char *)event->ssid,
            MAC2STR(event == NULL ? (uint8_t[6]){ 0 } : event->bssid),
            event == NULL ? 0U : (unsigned)event->channel,
            event == NULL ? "unknown" : authmode_name(event->authmode),
            event == NULL ? -1 : (int)event->authmode);
        log_dhcp_status("sta_connected before app event");
        log_sta_ap_info("sta_connected before app event");
        s_wifi_state = ESP_EMBED_WIFI_STATE_CONNECTED;
        ESP_LOGI(TAG, "station connected");

        esp_embed_wifi_sta_event_t report = { 0 };
        report.event = ESP_EMBED_WIFI_EVENT_CONNECTED;
        if (event != NULL) {
            report.ssid_len = event->ssid_len > sizeof(report.ssid) ? sizeof(report.ssid) : event->ssid_len;
            memcpy(report.ssid, event->ssid, report.ssid_len);
            memcpy(report.bssid, event->bssid, sizeof(report.bssid));
            report.channel = event->channel;
            report.security = map_security(event->authmode);
        }
        wifi_ap_record_t ap = { 0 };
        if (esp_wifi_sta_get_ap_info(&ap) == ESP_OK) {
            report.rssi = ap.rssi;
        }
        emit_event(&report);
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
        const wifi_event_sta_disconnected_t *event = (const wifi_event_sta_disconnected_t *)event_data;
        ESP_LOGW(
            TAG,
            "wifi event sta_disconnected prev_state=%s reason=%u(%s) ssid='%.*s' bssid=" MACSTR " rssi=%d",
            state_name(s_wifi_state),
            event == NULL ? 0U : (unsigned)event->reason,
            event == NULL ? "missing_event" : disconnect_reason_name(event->reason),
            event == NULL ? 0 : (int)event->ssid_len,
            event == NULL ? "" : (const char *)event->ssid,
            MAC2STR(event == NULL ? (uint8_t[6]){ 0 } : event->bssid),
            event == NULL ? 0 : (int)event->rssi);
        log_dhcp_status("sta_disconnected before app event");
        log_sta_ap_info("sta_disconnected before app event");
        s_wifi_state = ESP_EMBED_WIFI_STATE_IDLE;
        ESP_LOGW(
            TAG,
            "station disconnected reason=%u(%s)",
            event == NULL ? 0U : (unsigned)event->reason,
            event == NULL ? "missing_event" : disconnect_reason_name(event->reason));

        esp_embed_wifi_sta_event_t report = { 0 };
        report.event = ESP_EMBED_WIFI_EVENT_DISCONNECTED;
        report.reason = event == NULL ? 0 : event->reason;
        emit_event(&report);
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        const ip_event_got_ip_t *event = (const ip_event_got_ip_t *)event_data;
        ESP_LOGI(TAG, "ip event got_ip prev_state=%s", state_name(s_wifi_state));
        log_dhcp_status("got_ip event");
        s_wifi_state = ESP_EMBED_WIFI_STATE_CONNECTED;
        ESP_LOGI(TAG, "station got ip");

        esp_embed_wifi_sta_event_t report = { 0 };
        report.event = ESP_EMBED_WIFI_EVENT_GOT_IP;
        if (event != NULL) {
            fill_ip4(report.ip, event->ip_info.ip);
            fill_ip4(report.gateway, event->ip_info.gw);
            fill_ip4(report.netmask, event->ip_info.netmask);
        }
        emit_event(&report);
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_LOST_IP) {
        ESP_LOGW(TAG, "ip event lost_ip state=%s", state_name(s_wifi_state));
        esp_embed_wifi_sta_event_t report = { 0 };
        report.event = ESP_EMBED_WIFI_EVENT_LOST_IP;
        emit_event(&report);
    }
}

static esp_err_t init_nvs(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    return err;
}

static esp_err_t ok_if_already_initialized(esp_err_t err)
{
    return err == ESP_ERR_INVALID_STATE ? ESP_OK : err;
}

static esp_err_t apply_power_save(void)
{
    esp_err_t err = esp_wifi_set_ps(s_power_save_type);
    ESP_LOGI(
        TAG,
        "apply power save mode=%s(%d) listen_interval=%u rc=%d",
        power_save_name(s_power_save_type),
        (int)s_power_save_type,
        (unsigned)s_power_save_listen_interval,
        (int)err);
    return err;
}

static esp_err_t ensure_wifi_started(void)
{
    if (s_wifi_started) {
        return ESP_OK;
    }

    ESP_LOGI(TAG, "wifi start request");
    esp_err_t err = esp_wifi_start();
    ESP_LOGI(TAG, "esp_wifi_start rc=%d", (int)err);
    if (err != ESP_OK) {
        return err;
    }
    s_wifi_started = true;
    return apply_power_save();
}

static esp_err_t copy_wifi_text(char *dst, size_t dst_len, const uint8_t *src, size_t src_len)
{
    ESP_RETURN_ON_FALSE(src != NULL || src_len == 0, ESP_ERR_INVALID_ARG, TAG, "wifi text source is null");
    ESP_RETURN_ON_FALSE(src_len < dst_len, ESP_ERR_INVALID_ARG, TAG, "wifi text too long");
    if (src_len != 0) {
        memcpy(dst, src, src_len);
    }
    dst[src_len] = '\0';
    return ESP_OK;
}

int esp_embed_wifi_sta_init(void)
{
    if (s_wifi_initialized) {
        return ESP_OK;
    }

    ESP_RETURN_ON_ERROR(init_nvs(), TAG, "init nvs");
    ESP_RETURN_ON_ERROR(ok_if_already_initialized(esp_netif_init()), TAG, "esp_netif_init");
    ESP_RETURN_ON_ERROR(ok_if_already_initialized(esp_event_loop_create_default()), TAG, "esp_event_loop_create_default");
    s_event_queue = xQueueCreate(16, sizeof(esp_embed_wifi_sta_event_t));
    ESP_RETURN_ON_FALSE(s_event_queue != NULL, ESP_ERR_NO_MEM, TAG, "create wifi sta event queue");
    BaseType_t task_rc = xTaskCreate(event_task, "wifi_sta_evt", 8192, NULL, 5, &s_event_task);
    ESP_RETURN_ON_FALSE(task_rc == pdPASS, ESP_ERR_NO_MEM, TAG, "create wifi sta event task");
    s_wifi_netif = esp_netif_create_default_wifi_sta();
    ESP_RETURN_ON_FALSE(s_wifi_netif != NULL, ESP_ERR_NO_MEM, TAG, "create default wifi sta");

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_RETURN_ON_ERROR(esp_wifi_init(&cfg), TAG, "esp_wifi_init");
    ESP_RETURN_ON_ERROR(
        esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID, &wifi_event_handler, NULL, &s_instance_any_id),
        TAG,
        "register wifi handler");
    ESP_RETURN_ON_ERROR(
        esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP, &wifi_event_handler, NULL, &s_instance_got_ip),
        TAG,
        "register got ip handler");
    ESP_RETURN_ON_ERROR(
        esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_LOST_IP, &wifi_event_handler, NULL, &s_instance_lost_ip),
        TAG,
        "register lost ip handler");
    ESP_RETURN_ON_ERROR(esp_wifi_set_mode(WIFI_MODE_STA), TAG, "esp_wifi_set_mode");
    ESP_RETURN_ON_ERROR(esp_wifi_start(), TAG, "esp_wifi_start");
    s_wifi_started = true;
    ESP_RETURN_ON_ERROR(apply_power_save(), TAG, "apply power save");

    s_wifi_initialized = true;
    s_wifi_state = ESP_EMBED_WIFI_STATE_IDLE;
    return ESP_OK;
}

void esp_embed_wifi_sta_set_event_handler(void *ctx, esp_embed_wifi_sta_event_cb_t cb)
{
    s_event_ctx = ctx;
    s_event_cb = cb;
}

int esp_embed_wifi_sta_start_scan(const uint8_t *ssid_ptr, size_t ssid_len, uint8_t channel, bool show_hidden, bool active)
{
    if (!s_wifi_initialized || s_wifi_state == ESP_EMBED_WIFI_STATE_CONNECTING) {
        return ESP_ERR_INVALID_STATE;
    }
    esp_err_t start_err = ensure_wifi_started();
    if (start_err != ESP_OK) {
        return start_err;
    }

    wifi_scan_config_t config = { 0 };
    if (ssid_len != 0) {
        if (copy_wifi_text((char *)s_scan_ssid, sizeof(s_scan_ssid), ssid_ptr, ssid_len) != ESP_OK) {
            return ESP_ERR_INVALID_ARG;
        }
        config.ssid = s_scan_ssid;
    }
    config.channel = channel;
    config.show_hidden = show_hidden;
    config.scan_type = active ? WIFI_SCAN_TYPE_ACTIVE : WIFI_SCAN_TYPE_PASSIVE;

    s_wifi_state = ESP_EMBED_WIFI_STATE_IDLE;
    esp_err_t err = esp_wifi_scan_start(&config, false);
    if (err == ESP_OK) {
        s_wifi_state = ESP_EMBED_WIFI_STATE_SCANNING;
    }
    return err;
}

void esp_embed_wifi_sta_stop_scan(void)
{
    if (!s_wifi_initialized) {
        return;
    }
    if (!s_wifi_started) {
        return;
    }
    esp_wifi_scan_stop();
    if (s_wifi_state == ESP_EMBED_WIFI_STATE_SCANNING) {
        s_wifi_state = ESP_EMBED_WIFI_STATE_IDLE;
    }
}

int esp_embed_wifi_sta_connect(
    const uint8_t *ssid_ptr,
    size_t ssid_len,
    const uint8_t *password_ptr,
    size_t password_len)
{
    ESP_LOGI(
        TAG,
        "connect request state=%s ssid_len=%u password_len=%u",
        state_name(s_wifi_state),
        (unsigned)ssid_len,
        (unsigned)password_len);
    if (!s_wifi_initialized || s_wifi_state == ESP_EMBED_WIFI_STATE_CONNECTING) {
        ESP_LOGW(
            TAG,
            "connect rejected initialized=%d state=%s",
            s_wifi_initialized ? 1 : 0,
            state_name(s_wifi_state));
        return ESP_ERR_INVALID_STATE;
    }

    wifi_config_t wifi_config = { 0 };
    if (copy_wifi_text((char *)wifi_config.sta.ssid, sizeof(wifi_config.sta.ssid), ssid_ptr, ssid_len) != ESP_OK) {
        return ESP_ERR_INVALID_ARG;
    }
    if (copy_wifi_text((char *)wifi_config.sta.password, sizeof(wifi_config.sta.password), password_ptr, password_len) != ESP_OK) {
        return ESP_ERR_INVALID_ARG;
    }
    wifi_config.sta.threshold.authmode = password_len == 0 ? WIFI_AUTH_OPEN : WIFI_AUTH_WPA2_PSK;
    wifi_config.sta.failure_retry_cnt = 0;
    if (s_power_save_type == WIFI_PS_MAX_MODEM) {
        wifi_config.sta.listen_interval = s_power_save_listen_interval;
    }
    ESP_LOGI(
        TAG,
        "connect config ssid='%.*s' threshold_auth=%s(%d) failure_retry_cnt=%u power_save=%s(%d) listen_interval=%u",
        (int)ssid_len,
        (const char *)wifi_config.sta.ssid,
        authmode_name(wifi_config.sta.threshold.authmode),
        (int)wifi_config.sta.threshold.authmode,
        (unsigned)wifi_config.sta.failure_retry_cnt,
        power_save_name(s_power_save_type),
        (int)s_power_save_type,
        (unsigned)wifi_config.sta.listen_interval);

    if (s_wifi_state == ESP_EMBED_WIFI_STATE_SCANNING) {
        ESP_LOGI(TAG, "connect stopping active scan");
        esp_wifi_scan_stop();
    }
    if (s_wifi_state == ESP_EMBED_WIFI_STATE_CONNECTED) {
        ESP_LOGI(TAG, "connect disconnecting and stopping previous station");
        esp_err_t disconnect_err = esp_wifi_disconnect();
        ESP_LOGI(TAG, "esp_wifi_disconnect rc=%d", (int)disconnect_err);
        esp_err_t stop_err = esp_wifi_stop();
        ESP_LOGI(TAG, "esp_wifi_stop rc=%d", (int)stop_err);
        if (stop_err == ESP_OK || stop_err == ESP_ERR_WIFI_NOT_STARTED) {
            s_wifi_started = false;
        } else {
            s_wifi_state = ESP_EMBED_WIFI_STATE_IDLE;
            return stop_err;
        }
    }

    esp_err_t start_err = ensure_wifi_started();
    if (start_err != ESP_OK) {
        s_wifi_state = ESP_EMBED_WIFI_STATE_IDLE;
        return start_err;
    }

    s_wifi_state = ESP_EMBED_WIFI_STATE_CONNECTING;
    esp_err_t err = esp_wifi_set_config(WIFI_IF_STA, &wifi_config);
    ESP_LOGI(TAG, "esp_wifi_set_config rc=%d state=%s", (int)err, state_name(s_wifi_state));
    if (err != ESP_OK) {
        s_wifi_state = ESP_EMBED_WIFI_STATE_IDLE;
        return err;
    }
    err = esp_wifi_connect();
    ESP_LOGI(TAG, "esp_wifi_connect rc=%d state=%s", (int)err, state_name(s_wifi_state));
    if (err != ESP_OK) {
        s_wifi_state = ESP_EMBED_WIFI_STATE_IDLE;
        return err;
    }
    return ESP_OK;
}

void esp_embed_wifi_sta_disconnect(void)
{
    if (!s_wifi_initialized) {
        ESP_LOGW(TAG, "disconnect ignored initialized=0");
        return;
    }
    ESP_LOGI(TAG, "disconnect request state=%s", state_name(s_wifi_state));
    esp_err_t disconnect_err = esp_wifi_disconnect();
    ESP_LOGI(TAG, "esp_wifi_disconnect rc=%d", (int)disconnect_err);
    if (s_wifi_started) {
        esp_err_t stop_err = esp_wifi_stop();
        ESP_LOGI(TAG, "esp_wifi_stop rc=%d", (int)stop_err);
        if (stop_err == ESP_OK || stop_err == ESP_ERR_WIFI_NOT_STARTED) {
            s_wifi_started = false;
        }
    }
    s_wifi_state = ESP_EMBED_WIFI_STATE_IDLE;
    ESP_LOGI(TAG, "disconnect requested state=%s", state_name(s_wifi_state));
}

int esp_embed_wifi_sta_state(void)
{
    return s_wifi_state;
}

int esp_embed_wifi_sta_set_power_save(int mode, uint16_t listen_interval)
{
    wifi_ps_type_t type = WIFI_PS_MIN_MODEM;
    esp_err_t err = map_power_save(mode, &type);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "set power save invalid mode=%d", mode);
        return err;
    }
    if (type == WIFI_PS_MAX_MODEM && listen_interval == 0) {
        ESP_LOGW(TAG, "set power save invalid listen_interval=0");
        return ESP_ERR_INVALID_ARG;
    }
    s_power_save_type = type;
    s_power_save_listen_interval = type == WIFI_PS_MAX_MODEM ? listen_interval : 0;
    if (!s_wifi_started) {
        ESP_LOGI(
            TAG,
            "set power save deferred mode=%s(%d) listen_interval=%u",
            power_save_name(type),
            (int)type,
            (unsigned)listen_interval);
        return ESP_OK;
    }
    err = apply_power_save();
    if (err == ESP_OK) {
        return ESP_OK;
    }
    return err;
}

int esp_embed_wifi_sta_get_power_save(int *mode, uint16_t *listen_interval)
{
    ESP_RETURN_ON_FALSE(mode != NULL, ESP_ERR_INVALID_ARG, TAG, "get power save output is null");
    ESP_RETURN_ON_FALSE(listen_interval != NULL, ESP_ERR_INVALID_ARG, TAG, "get power save listen interval output is null");
    if (!s_wifi_started) {
        int mapped = unmap_power_save(s_power_save_type);
        if (mapped < 0) {
            ESP_LOGW(TAG, "get cached power save unknown mode=%d", (int)s_power_save_type);
            return ESP_ERR_INVALID_ARG;
        }
        *mode = mapped;
        *listen_interval = s_power_save_type == WIFI_PS_MAX_MODEM ? s_power_save_listen_interval : 0;
        ESP_LOGI(
            TAG,
            "get cached power save mode=%s(%d) listen_interval=%u",
            power_save_name(s_power_save_type),
            (int)s_power_save_type,
            (unsigned)*listen_interval);
        return ESP_OK;
    }
    wifi_ps_type_t type = WIFI_PS_MIN_MODEM;
    esp_err_t err = esp_wifi_get_ps(&type);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "get power save failed rc=%d", (int)err);
        return err;
    }
    int mapped = unmap_power_save(type);
    if (mapped < 0) {
        ESP_LOGW(TAG, "get power save unknown mode=%d", (int)type);
        return ESP_ERR_INVALID_ARG;
    }
    *mode = mapped;
    *listen_interval = type == WIFI_PS_MAX_MODEM ? s_power_save_listen_interval : 0;
    ESP_LOGI(
        TAG,
        "get power save mode=%s(%d) listen_interval=%u",
        power_save_name(type),
        (int)type,
        (unsigned)*listen_interval);
    return ESP_OK;
}
