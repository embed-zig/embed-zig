#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "esp_check.h"
#include "esp_err.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "esp_wifi_default.h"
#include "nvs_flash.h"

#define DEVKIT_WIFI_CONNECTED_BIT BIT0
#define DEVKIT_WIFI_FAILED_BIT BIT1

#define DEVKIT_WIFI_CONNECT_FAILED 0
#define DEVKIT_WIFI_CONNECT_SUCCESS 1
#define DEVKIT_WIFI_CONNECT_TIMEOUT 2
#define DEVKIT_WIFI_CONNECT_INVALID_CONFIG 3

#define DEVKIT_WIFI_STATE_IDLE 0
#define DEVKIT_WIFI_STATE_CONNECTING 1
#define DEVKIT_WIFI_STATE_CONNECTED 2
#define DEVKIT_WIFI_STATE_SCANNING 3

#define DEVKIT_WIFI_EVENT_CONNECTED 1
#define DEVKIT_WIFI_EVENT_DISCONNECTED 2
#define DEVKIT_WIFI_EVENT_GOT_IP 3
#define DEVKIT_WIFI_EVENT_LOST_IP 4
#define DEVKIT_WIFI_EVENT_SCAN_RESULT 5

#define DEVKIT_WIFI_SECURITY_UNKNOWN 0
#define DEVKIT_WIFI_SECURITY_OPEN 1
#define DEVKIT_WIFI_SECURITY_WEP 2
#define DEVKIT_WIFI_SECURITY_WPA 3
#define DEVKIT_WIFI_SECURITY_WPA2 4
#define DEVKIT_WIFI_SECURITY_WPA3 5

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
} devkit_wifi_sta_event_t;

typedef void (*devkit_wifi_sta_event_cb_t)(void *ctx, const devkit_wifi_sta_event_t *event);

static const char *TAG = "devkit_wifi_sta";
static esp_netif_t *s_wifi_netif;
static EventGroupHandle_t s_wifi_event_group;
static esp_event_handler_instance_t s_instance_any_id;
static esp_event_handler_instance_t s_instance_got_ip;
static esp_event_handler_instance_t s_instance_lost_ip;
static bool s_wifi_initialized;
static int s_wifi_state = DEVKIT_WIFI_STATE_IDLE;
static devkit_wifi_sta_event_cb_t s_event_cb;
static void *s_event_ctx;
static uint8_t s_scan_ssid[33];

static int map_security(wifi_auth_mode_t authmode)
{
    switch (authmode) {
    case WIFI_AUTH_OPEN:
        return DEVKIT_WIFI_SECURITY_OPEN;
    case WIFI_AUTH_WEP:
        return DEVKIT_WIFI_SECURITY_WEP;
    case WIFI_AUTH_WPA_PSK:
        return DEVKIT_WIFI_SECURITY_WPA;
    case WIFI_AUTH_WPA2_PSK:
    case WIFI_AUTH_WPA_WPA2_PSK:
    case WIFI_AUTH_WPA2_ENTERPRISE:
        return DEVKIT_WIFI_SECURITY_WPA2;
    case WIFI_AUTH_WPA3_PSK:
    case WIFI_AUTH_WPA2_WPA3_PSK:
        return DEVKIT_WIFI_SECURITY_WPA3;
    default:
        return DEVKIT_WIFI_SECURITY_UNKNOWN;
    }
}

static void fill_ip4(uint8_t out[4], esp_ip4_addr_t addr)
{
    out[0] = esp_ip4_addr1(&addr);
    out[1] = esp_ip4_addr2(&addr);
    out[2] = esp_ip4_addr3(&addr);
    out[3] = esp_ip4_addr4(&addr);
}

static void emit_event(const devkit_wifi_sta_event_t *event)
{
    if (s_event_cb != NULL) {
        s_event_cb(s_event_ctx, event);
    }
}

static void emit_scan_results(void)
{
    uint16_t count = 16;
    wifi_ap_record_t records[16] = { 0 };

    if (esp_wifi_scan_get_ap_records(&count, records) != ESP_OK) {
        return;
    }

    for (uint16_t i = 0; i < count; i++) {
        devkit_wifi_sta_event_t report = { 0 };
        report.event = DEVKIT_WIFI_EVENT_SCAN_RESULT;
        size_t ssid_len = strnlen((const char *)records[i].ssid, sizeof(records[i].ssid));
        report.ssid_len = ssid_len > sizeof(report.ssid) ? sizeof(report.ssid) : ssid_len;
        memcpy(report.ssid, records[i].ssid, report.ssid_len);
        memcpy(report.bssid, records[i].bssid, sizeof(report.bssid));
        report.channel = records[i].primary;
        report.rssi = records[i].rssi;
        report.security = map_security(records[i].authmode);
        emit_event(&report);
    }
}

static void wifi_event_handler(void *arg, esp_event_base_t event_base, int32_t event_id, void *event_data)
{
    (void)arg;

    if (s_wifi_event_group == NULL) {
        return;
    }

    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_SCAN_DONE) {
        emit_scan_results();
        s_wifi_state = DEVKIT_WIFI_STATE_IDLE;
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_CONNECTED) {
        const wifi_event_sta_connected_t *event = (const wifi_event_sta_connected_t *)event_data;
        devkit_wifi_sta_event_t report = { 0 };
        report.event = DEVKIT_WIFI_EVENT_CONNECTED;
        if (event != NULL) {
            report.ssid_len = event->ssid_len > sizeof(report.ssid) ? sizeof(report.ssid) : event->ssid_len;
            memcpy(report.ssid, event->ssid, report.ssid_len);
            memcpy(report.bssid, event->bssid, sizeof(report.bssid));
            report.channel = event->channel;
            report.security = map_security(event->authmode);
        }
        emit_event(&report);
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
        const wifi_event_sta_disconnected_t *event = (const wifi_event_sta_disconnected_t *)event_data;
        s_wifi_state = DEVKIT_WIFI_STATE_IDLE;
        xEventGroupClearBits(s_wifi_event_group, DEVKIT_WIFI_CONNECTED_BIT);
        ESP_LOGW(TAG, "station disconnected reason=%u", event == NULL ? 0U : (unsigned)event->reason);
        devkit_wifi_sta_event_t report = { 0 };
        report.event = DEVKIT_WIFI_EVENT_DISCONNECTED;
        report.reason = event == NULL ? 0 : event->reason;
        emit_event(&report);
        xEventGroupSetBits(s_wifi_event_group, DEVKIT_WIFI_FAILED_BIT);
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        const ip_event_got_ip_t *event = (const ip_event_got_ip_t *)event_data;
        s_wifi_state = DEVKIT_WIFI_STATE_CONNECTED;
        xEventGroupClearBits(s_wifi_event_group, DEVKIT_WIFI_FAILED_BIT);
        ESP_LOGI(TAG, "station got ip");
        devkit_wifi_sta_event_t report = { 0 };
        report.event = DEVKIT_WIFI_EVENT_GOT_IP;
        if (event != NULL) {
            fill_ip4(report.ip, event->ip_info.ip);
            fill_ip4(report.gateway, event->ip_info.gw);
            fill_ip4(report.netmask, event->ip_info.netmask);
        }
        emit_event(&report);
        xEventGroupSetBits(s_wifi_event_group, DEVKIT_WIFI_CONNECTED_BIT);
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_LOST_IP) {
        devkit_wifi_sta_event_t report = { 0 };
        report.event = DEVKIT_WIFI_EVENT_LOST_IP;
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

int devkit_wifi_sta_init(void)
{
    if (s_wifi_initialized) {
        return ESP_OK;
    }

    s_wifi_event_group = xEventGroupCreate();
    if (s_wifi_event_group == NULL) {
        return ESP_ERR_NO_MEM;
    }

    ESP_RETURN_ON_ERROR(init_nvs(), TAG, "init nvs");
    ESP_RETURN_ON_ERROR(ok_if_already_initialized(esp_netif_init()), TAG, "esp_netif_init");
    ESP_RETURN_ON_ERROR(ok_if_already_initialized(esp_event_loop_create_default()), TAG, "esp_event_loop_create_default");
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

    s_wifi_initialized = true;
    s_wifi_state = DEVKIT_WIFI_STATE_IDLE;
    return ESP_OK;
}

void devkit_wifi_sta_set_event_handler(void *ctx, devkit_wifi_sta_event_cb_t cb)
{
    s_event_ctx = ctx;
    s_event_cb = cb;
}

int devkit_wifi_sta_start_scan(const uint8_t *ssid_ptr, size_t ssid_len, uint8_t channel, bool show_hidden, bool active)
{
    if (!s_wifi_initialized) {
        return ESP_ERR_INVALID_STATE;
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

    s_wifi_state = DEVKIT_WIFI_STATE_IDLE;
    esp_err_t err = esp_wifi_scan_start(&config, false);
    if (err == ESP_OK) {
        s_wifi_state = DEVKIT_WIFI_STATE_SCANNING;
    }
    return err;
}

void devkit_wifi_sta_stop_scan(void)
{
    if (!s_wifi_initialized) {
        return;
    }
    esp_wifi_scan_stop();
    if (s_wifi_state == DEVKIT_WIFI_STATE_SCANNING) {
        s_wifi_state = DEVKIT_WIFI_STATE_IDLE;
    }
}

int devkit_wifi_sta_connect_blocking(
    const uint8_t *ssid_ptr,
    size_t ssid_len,
    const uint8_t *password_ptr,
    size_t password_len,
    uint32_t timeout_ms)
{
    if (!s_wifi_initialized) {
        return DEVKIT_WIFI_CONNECT_INVALID_CONFIG;
    }

    wifi_config_t wifi_config = { 0 };
    if (copy_wifi_text((char *)wifi_config.sta.ssid, sizeof(wifi_config.sta.ssid), ssid_ptr, ssid_len) != ESP_OK) {
        return DEVKIT_WIFI_CONNECT_INVALID_CONFIG;
    }
    if (copy_wifi_text((char *)wifi_config.sta.password, sizeof(wifi_config.sta.password), password_ptr, password_len) != ESP_OK) {
        return DEVKIT_WIFI_CONNECT_INVALID_CONFIG;
    }
    wifi_config.sta.threshold.authmode = password_len == 0 ? WIFI_AUTH_OPEN : WIFI_AUTH_WPA2_PSK;
    wifi_config.sta.failure_retry_cnt = 0;

    xEventGroupClearBits(s_wifi_event_group, DEVKIT_WIFI_CONNECTED_BIT | DEVKIT_WIFI_FAILED_BIT);
    s_wifi_state = DEVKIT_WIFI_STATE_CONNECTING;

    if (esp_wifi_set_config(WIFI_IF_STA, &wifi_config) != ESP_OK) {
        s_wifi_state = DEVKIT_WIFI_STATE_IDLE;
        return DEVKIT_WIFI_CONNECT_INVALID_CONFIG;
    }
    if (esp_wifi_connect() != ESP_OK) {
        s_wifi_state = DEVKIT_WIFI_STATE_IDLE;
        return DEVKIT_WIFI_CONNECT_FAILED;
    }

    TickType_t timeout_ticks = pdMS_TO_TICKS(timeout_ms);
    if (timeout_ticks == 0) {
        timeout_ticks = 1;
    }

    EventBits_t bits = xEventGroupWaitBits(
        s_wifi_event_group,
        DEVKIT_WIFI_CONNECTED_BIT | DEVKIT_WIFI_FAILED_BIT,
        pdTRUE,
        pdFALSE,
        timeout_ticks);
    if ((bits & DEVKIT_WIFI_CONNECTED_BIT) != 0) {
        s_wifi_state = DEVKIT_WIFI_STATE_CONNECTED;
        return DEVKIT_WIFI_CONNECT_SUCCESS;
    }

    s_wifi_state = DEVKIT_WIFI_STATE_IDLE;
    esp_wifi_disconnect();
    if ((bits & DEVKIT_WIFI_FAILED_BIT) != 0) {
        return DEVKIT_WIFI_CONNECT_FAILED;
    }
    return DEVKIT_WIFI_CONNECT_TIMEOUT;
}

void devkit_wifi_sta_disconnect(void)
{
    if (!s_wifi_initialized) {
        return;
    }
    esp_wifi_disconnect();
    s_wifi_state = DEVKIT_WIFI_STATE_IDLE;
}

int devkit_wifi_sta_state(void)
{
    return s_wifi_state;
}
