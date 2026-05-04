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
#include "led_strip.h"
#include "nvs_flash.h"

#define WIFI_CONNECTED_BIT BIT0
#define WIFI_FAILED_BIT BIT1

#define WIFI_CONNECT_FAILED 0
#define WIFI_CONNECT_SUCCESS 1

static const char *TAG = "wifi_led_platform";
static const int EXAMPLE_LED_STRIP_GPIO = 48;
static led_strip_handle_t s_led_strip;
static esp_netif_t *s_wifi_netif;

static EventGroupHandle_t s_wifi_event_group;
static esp_event_handler_instance_t s_instance_any_id;
static esp_event_handler_instance_t s_instance_got_ip;
static bool s_platform_initialized;
static char s_wifi_ssid[33];
static char s_wifi_password[65];

static void cleanup_init_failure(void)
{
    if (s_instance_any_id != NULL) {
        esp_event_handler_instance_unregister(WIFI_EVENT, ESP_EVENT_ANY_ID, s_instance_any_id);
        s_instance_any_id = NULL;
    }
    if (s_instance_got_ip != NULL) {
        esp_event_handler_instance_unregister(IP_EVENT, IP_EVENT_STA_GOT_IP, s_instance_got_ip);
        s_instance_got_ip = NULL;
    }
    if (s_wifi_netif != NULL) {
        esp_err_t err = esp_wifi_stop();
        if (err != ESP_OK && err != ESP_ERR_WIFI_NOT_INIT && err != ESP_ERR_WIFI_NOT_STARTED) {
            ESP_LOGW(TAG, "esp_wifi_stop cleanup failed: %s", esp_err_to_name(err));
        }
        err = esp_wifi_deinit();
        if (err != ESP_OK && err != ESP_ERR_WIFI_NOT_INIT) {
            ESP_LOGW(TAG, "esp_wifi_deinit cleanup failed: %s", esp_err_to_name(err));
        }
        err = esp_wifi_clear_default_wifi_driver_and_handlers(s_wifi_netif);
        if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
            ESP_LOGW(TAG, "esp_wifi_clear_default_wifi_driver_and_handlers cleanup failed: %s", esp_err_to_name(err));
        }
        esp_netif_destroy_default_wifi(s_wifi_netif);
        s_wifi_netif = NULL;
    }
    esp_err_t err = esp_event_loop_delete_default();
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
        ESP_LOGW(TAG, "esp_event_loop_delete_default cleanup failed: %s", esp_err_to_name(err));
    }
    err = esp_netif_deinit();
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
        ESP_LOGW(TAG, "esp_netif_deinit cleanup failed: %s", esp_err_to_name(err));
    }
    if (s_wifi_event_group != NULL) {
        vEventGroupDelete(s_wifi_event_group);
        s_wifi_event_group = NULL;
    }
}

static void wifi_event_handler(void *arg, esp_event_base_t event_base, int32_t event_id, void *event_data)
{
    (void)arg;

    if (s_wifi_event_group == NULL) {
        return;
    }

    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
        const wifi_event_sta_disconnected_t *event = (const wifi_event_sta_disconnected_t *)event_data;
        xEventGroupClearBits(s_wifi_event_group, WIFI_CONNECTED_BIT);
        xEventGroupSetBits(s_wifi_event_group, WIFI_FAILED_BIT);
        ESP_LOGW(TAG, "station disconnected reason=%u", event == NULL ? 0U : (unsigned)event->reason);
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        xEventGroupClearBits(s_wifi_event_group, WIFI_FAILED_BIT);
        xEventGroupSetBits(s_wifi_event_group, WIFI_CONNECTED_BIT);
        ESP_LOGI(TAG, "station got ip");
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

static esp_err_t init_led_strip(void)
{
    led_strip_handle_t led_strip = NULL;
    led_strip_config_t strip_config = {
        .strip_gpio_num = EXAMPLE_LED_STRIP_GPIO,
        .max_leds = 1,
    };
    led_strip_rmt_config_t rmt_config = {
        .resolution_hz = 10 * 1000 * 1000,
        .flags.with_dma = false,
    };

    ESP_RETURN_ON_ERROR(led_strip_new_rmt_device(&strip_config, &rmt_config, &led_strip), TAG, "create led strip");
    ESP_RETURN_ON_ERROR(led_strip_clear(led_strip), TAG, "clear led strip");
    s_led_strip = led_strip;
    return ESP_OK;
}

static esp_err_t init_wifi_station(const char *ssid, const char *password)
{
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    wifi_config_t wifi_config = { 0 };

    strlcpy((char *)s_wifi_ssid, ssid, sizeof(s_wifi_ssid));
    strlcpy((char *)s_wifi_password, password, sizeof(s_wifi_password));
    strlcpy((char *)wifi_config.sta.ssid, s_wifi_ssid, sizeof(wifi_config.sta.ssid));
    strlcpy((char *)wifi_config.sta.password, s_wifi_password, sizeof(wifi_config.sta.password));
    wifi_config.sta.threshold.authmode = strlen(s_wifi_password) == 0 ? WIFI_AUTH_OPEN : WIFI_AUTH_WPA2_PSK;
    wifi_config.sta.failure_retry_cnt = 0;

    ESP_RETURN_ON_ERROR(esp_netif_init(), TAG, "esp_netif_init");
    ESP_RETURN_ON_ERROR(esp_event_loop_create_default(), TAG, "esp_event_loop_create_default");
    s_wifi_netif = esp_netif_create_default_wifi_sta();
    ESP_RETURN_ON_FALSE(s_wifi_netif != NULL, ESP_ERR_NO_MEM, TAG, "create default wifi sta");
    ESP_RETURN_ON_ERROR(esp_wifi_init(&cfg), TAG, "esp_wifi_init");
    ESP_RETURN_ON_ERROR(
        esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID, &wifi_event_handler, NULL, &s_instance_any_id),
        TAG,
        "register wifi handler");
    ESP_RETURN_ON_ERROR(
        esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP, &wifi_event_handler, NULL, &s_instance_got_ip),
        TAG,
        "register got_ip handler");
    ESP_RETURN_ON_ERROR(esp_wifi_set_mode(WIFI_MODE_STA), TAG, "esp_wifi_set_mode");
    ESP_RETURN_ON_ERROR(esp_wifi_set_config(WIFI_IF_STA, &wifi_config), TAG, "esp_wifi_set_config");
    return esp_wifi_start();
}

int esp_example_wifi_led_platform_init(const char *ssid, const char *password)
{
    if (s_platform_initialized) {
        return ESP_OK;
    }
    if (ssid == NULL || password == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    s_wifi_event_group = xEventGroupCreate();
    if (s_wifi_event_group == NULL) {
        return ESP_ERR_NO_MEM;
    }

    esp_err_t err = init_nvs();
    if (err != ESP_OK) {
        cleanup_init_failure();
        return err;
    }
    err = init_wifi_station(ssid, password);
    if (err != ESP_OK) {
        cleanup_init_failure();
        return err;
    }
    err = init_led_strip();
    if (err != ESP_OK) {
        cleanup_init_failure();
        return err;
    }

    s_platform_initialized = true;
    return ESP_OK;
}

int esp_example_wifi_led_platform_connect_blocking(uint32_t timeout_ms)
{
    if (!s_platform_initialized) {
        return ESP_ERR_INVALID_STATE;
    }

    xEventGroupClearBits(s_wifi_event_group, WIFI_CONNECTED_BIT | WIFI_FAILED_BIT);

    if (esp_wifi_connect() != ESP_OK) {
        return WIFI_CONNECT_FAILED;
    }

    TickType_t timeout_ticks = pdMS_TO_TICKS(timeout_ms);
    if (timeout_ticks == 0) {
        timeout_ticks = 1;
    }

    EventBits_t bits = xEventGroupWaitBits(
        s_wifi_event_group,
        WIFI_CONNECTED_BIT | WIFI_FAILED_BIT,
        pdTRUE,
        pdFALSE,
        timeout_ticks);
    if ((bits & WIFI_CONNECTED_BIT) != 0) {
        return WIFI_CONNECT_SUCCESS;
    }
    return WIFI_CONNECT_FAILED;
}

int esp_example_wifi_led_platform_set_rgb(uint8_t r, uint8_t g, uint8_t b)
{
    if (!s_platform_initialized) {
        return ESP_ERR_INVALID_STATE;
    }

    ESP_RETURN_ON_FALSE(s_led_strip != NULL, ESP_ERR_INVALID_STATE, TAG, "led strip not initialized");
    ESP_RETURN_ON_ERROR(led_strip_set_pixel(s_led_strip, 0, r, g, b), TAG, "set led pixel");
    return led_strip_refresh(s_led_strip);
}
