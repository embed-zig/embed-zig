#include "lvgl.h"

void embed_lv_obj_set_style_bg_color_rgb(lv_obj_t *obj, uint8_t red, uint8_t green, uint8_t blue, lv_style_selector_t selector)
{
    lv_obj_set_style_bg_color(obj, lv_color_make(red, green, blue), selector);
}

void embed_lv_obj_set_style_text_color_rgb(lv_obj_t *obj, uint8_t red, uint8_t green, uint8_t blue, lv_style_selector_t selector)
{
    lv_obj_set_style_text_color(obj, lv_color_make(red, green, blue), selector);
}
