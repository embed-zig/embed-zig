#ifndef LV_CONF_H
#define LV_CONF_H

/*
 * Default LVGL configuration shipped by embed-zig.
 *
 * Override the entire header with:
 *   -Dlvgl=true -Dlvgl_config_header=path/to/lv_conf.h
 *
 * Anything not defined here falls back to LVGL's internal defaults.
 *
 * `build/pkg/lvgl.zig` injects the fixed OS contract separately:
 *   LV_USE_OS = LV_OS_CUSTOM
 *   LV_OS_CUSTOM_INCLUDE = "lv_os_custom.h"
 *
 * This header intentionally does not define those macros, because the
 * bundled `lvgl_osal` adapter requires that ABI and the build wrapper
 * enforces it for both default and custom `lv_conf.h` inputs.
 */

/*====================
 * Color settings
 *====================*/

#define LV_COLOR_DEPTH 16

/*=========================
 * Stdlib wrapper settings
 *=========================*/

#define LV_USE_STDLIB_MALLOC LV_STDLIB_BUILTIN
#define LV_USE_STDLIB_STRING LV_STDLIB_BUILTIN
#define LV_USE_STDLIB_SPRINTF LV_STDLIB_BUILTIN
#define LV_MEM_SIZE (64U * 1024U)

/*=================
 * Core features
 *=================*/

#define LV_USE_FLOAT 0
#define LV_USE_MATRIX 0
#define LV_USE_OBSERVER 1

#endif /* LV_CONF_H */
