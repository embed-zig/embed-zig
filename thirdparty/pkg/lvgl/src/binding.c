#include "lvgl.h"

void embed_lv_obj_set_style_bg_color_rgb(lv_obj_t * obj, uint8_t red, uint8_t green, uint8_t blue, lv_style_selector_t selector) {
    lv_obj_set_style_bg_color(obj, lv_color_make(red, green, blue), selector);
}

void embed_lv_obj_set_style_text_color_rgb(lv_obj_t * obj, uint8_t red, uint8_t green, uint8_t blue, lv_style_selector_t selector) {
    lv_obj_set_style_text_color(obj, lv_color_make(red, green, blue), selector);
}

lv_anim_t * embed_lv_anim_create(void) {
    lv_anim_t * anim = (lv_anim_t *)lv_malloc(sizeof(lv_anim_t));
    if(anim == NULL) return NULL;
    lv_anim_init(anim);
    return anim;
}

void embed_lv_anim_destroy(lv_anim_t * anim) {
    lv_free(anim);
}

int32_t embed_lv_anim_get_start_value(const lv_anim_t * anim) {
    return anim->start_value;
}

int32_t embed_lv_anim_get_end_value(const lv_anim_t * anim) {
    return anim->end_value;
}

int32_t embed_lv_anim_get_duration(const lv_anim_t * anim) {
    return anim->duration;
}

int32_t embed_lv_anim_get_act_time(const lv_anim_t * anim) {
    return anim->act_time;
}

uint32_t embed_lv_anim_get_reverse_delay(const lv_anim_t * anim) {
    return anim->reverse_delay;
}

uint32_t embed_lv_anim_get_reverse_duration(const lv_anim_t * anim) {
    return anim->reverse_duration;
}

uint32_t embed_lv_anim_get_repeat_delay(const lv_anim_t * anim) {
    return anim->repeat_delay;
}

uint32_t embed_lv_anim_get_repeat_count(const lv_anim_t * anim) {
    return anim->repeat_cnt;
}

uint8_t embed_lv_anim_get_early_apply(const lv_anim_t * anim) {
    return anim->early_apply;
}

lv_subject_t * embed_lv_subject_create(void) {
    return (lv_subject_t *)lv_malloc(sizeof(lv_subject_t));
}

void embed_lv_subject_destroy(lv_subject_t * subject) {
    lv_free(subject);
}
