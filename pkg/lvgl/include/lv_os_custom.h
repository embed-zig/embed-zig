#ifndef EMBED_ZIG_LV_OS_CUSTOM_H
#define EMBED_ZIG_LV_OS_CUSTOM_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct embed_lvgl_mutex_impl embed_lvgl_mutex_impl_t;
typedef struct embed_lvgl_thread_impl embed_lvgl_thread_impl_t;
typedef struct embed_lvgl_thread_sync_impl embed_lvgl_thread_sync_impl_t;

typedef struct {
    embed_lvgl_mutex_impl_t *impl;
} lv_mutex_t;

typedef struct {
    embed_lvgl_thread_impl_t *impl;
} lv_thread_t;

typedef struct {
    embed_lvgl_thread_sync_impl_t *impl;
} lv_thread_sync_t;

#ifdef __cplusplus
}
#endif

#endif /* EMBED_ZIG_LV_OS_CUSTOM_H */
