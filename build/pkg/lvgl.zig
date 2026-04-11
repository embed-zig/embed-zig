const std = @import("std");
const GitRepo = @import("../GitRepo.zig");

var library: ?*std.Build.Step.Compile = null;
var osal_library: ?*std.Build.Step.Compile = null;
var osal_module: ?*std.Build.Module = null;
var resolved_target: ?std.Build.ResolvedTarget = null;
var resolved_optimize: ?std.builtin.OptimizeMode = null;
var has_custom_config_header: bool = false;

const upstream_repo = "https://github.com/lvgl/lvgl.git";
const upstream_commit = "85aa60d18b3d5e5588d7b247abf90198f07c8a63";
const bundled_custom_include = "lv_os_custom.h";

const c_sources: []const []const u8 = &.{
    "src/core/lv_group.c",
    "src/core/lv_obj.c",
    "src/core/lv_obj_class.c",
    "src/core/lv_obj_draw.c",
    "src/core/lv_obj_event.c",
    "src/core/lv_obj_id_builtin.c",
    "src/core/lv_obj_pos.c",
    "src/core/lv_obj_property.c",
    "src/core/lv_obj_scroll.c",
    "src/core/lv_obj_style.c",
    "src/core/lv_obj_style_gen.c",
    "src/core/lv_obj_tree.c",
    "src/core/lv_observer.c",
    "src/core/lv_refr.c",
    "src/debugging/monkey/lv_monkey.c",
    "src/debugging/sysmon/lv_sysmon.c",
    "src/debugging/test/lv_test_display.c",
    "src/debugging/test/lv_test_fs.c",
    "src/debugging/test/lv_test_helpers.c",
    "src/debugging/test/lv_test_indev.c",
    "src/debugging/test/lv_test_indev_gesture.c",
    "src/debugging/test/lv_test_screenshot_compare.c",
    "src/debugging/vg_lite_tvg/vg_lite_matrix.c",
    "src/display/lv_display.c",
    "src/draw/convert/helium/lv_draw_buf_convert_helium.c",
    "src/draw/convert/lv_draw_buf_convert.c",
    "src/draw/convert/neon/lv_draw_buf_convert_neon.c",
    "src/draw/dma2d/lv_draw_dma2d.c",
    "src/draw/dma2d/lv_draw_dma2d_fill.c",
    "src/draw/dma2d/lv_draw_dma2d_img.c",
    "src/draw/espressif/ppa/lv_draw_ppa.c",
    "src/draw/espressif/ppa/lv_draw_ppa_buf.c",
    "src/draw/espressif/ppa/lv_draw_ppa_fill.c",
    "src/draw/espressif/ppa/lv_draw_ppa_img.c",
    "src/draw/eve/lv_draw_eve.c",
    "src/draw/eve/lv_draw_eve_arc.c",
    "src/draw/eve/lv_draw_eve_fill.c",
    "src/draw/eve/lv_draw_eve_image.c",
    "src/draw/eve/lv_draw_eve_letter.c",
    "src/draw/eve/lv_draw_eve_line.c",
    "src/draw/eve/lv_draw_eve_ram_g.c",
    "src/draw/eve/lv_draw_eve_triangle.c",
    "src/draw/eve/lv_eve.c",
    "src/draw/lv_draw.c",
    "src/draw/lv_draw_3d.c",
    "src/draw/lv_draw_arc.c",
    "src/draw/lv_draw_blur.c",
    "src/draw/lv_draw_buf.c",
    "src/draw/lv_draw_image.c",
    "src/draw/lv_draw_label.c",
    "src/draw/lv_draw_line.c",
    "src/draw/lv_draw_mask.c",
    "src/draw/lv_draw_rect.c",
    "src/draw/lv_draw_triangle.c",
    "src/draw/lv_draw_vector.c",
    "src/draw/lv_image_decoder.c",
    "src/draw/nanovg/lv_draw_nanovg.c",
    "src/draw/nanovg/lv_draw_nanovg_3d.c",
    "src/draw/nanovg/lv_draw_nanovg_arc.c",
    "src/draw/nanovg/lv_draw_nanovg_border.c",
    "src/draw/nanovg/lv_draw_nanovg_box_shadow.c",
    "src/draw/nanovg/lv_draw_nanovg_fill.c",
    "src/draw/nanovg/lv_draw_nanovg_grad.c",
    "src/draw/nanovg/lv_draw_nanovg_image.c",
    "src/draw/nanovg/lv_draw_nanovg_label.c",
    "src/draw/nanovg/lv_draw_nanovg_layer.c",
    "src/draw/nanovg/lv_draw_nanovg_line.c",
    "src/draw/nanovg/lv_draw_nanovg_mask_rect.c",
    "src/draw/nanovg/lv_draw_nanovg_triangle.c",
    "src/draw/nanovg/lv_draw_nanovg_vector.c",
    "src/draw/nanovg/lv_nanovg_fbo_cache.c",
    "src/draw/nanovg/lv_nanovg_image_cache.c",
    "src/draw/nanovg/lv_nanovg_utils.c",
    "src/draw/nema_gfx/lv_draw_nema_gfx.c",
    "src/draw/nema_gfx/lv_draw_nema_gfx_arc.c",
    "src/draw/nema_gfx/lv_draw_nema_gfx_border.c",
    "src/draw/nema_gfx/lv_draw_nema_gfx_fill.c",
    "src/draw/nema_gfx/lv_draw_nema_gfx_img.c",
    "src/draw/nema_gfx/lv_draw_nema_gfx_label.c",
    "src/draw/nema_gfx/lv_draw_nema_gfx_layer.c",
    "src/draw/nema_gfx/lv_draw_nema_gfx_line.c",
    "src/draw/nema_gfx/lv_draw_nema_gfx_stm32_hal.c",
    "src/draw/nema_gfx/lv_draw_nema_gfx_triangle.c",
    "src/draw/nema_gfx/lv_draw_nema_gfx_utils.c",
    "src/draw/nema_gfx/lv_draw_nema_gfx_vector.c",
    "src/draw/nema_gfx/lv_nema_gfx_path.c",
    "src/draw/nxp/g2d/lv_draw_buf_g2d.c",
    "src/draw/nxp/g2d/lv_draw_g2d.c",
    "src/draw/nxp/g2d/lv_draw_g2d_fill.c",
    "src/draw/nxp/g2d/lv_draw_g2d_img.c",
    "src/draw/nxp/g2d/lv_g2d_buf_map.c",
    "src/draw/nxp/g2d/lv_g2d_utils.c",
    "src/draw/nxp/pxp/lv_draw_buf_pxp.c",
    "src/draw/nxp/pxp/lv_draw_pxp.c",
    "src/draw/nxp/pxp/lv_draw_pxp_fill.c",
    "src/draw/nxp/pxp/lv_draw_pxp_img.c",
    "src/draw/nxp/pxp/lv_draw_pxp_layer.c",
    "src/draw/nxp/pxp/lv_pxp_cfg.c",
    "src/draw/nxp/pxp/lv_pxp_osa.c",
    "src/draw/nxp/pxp/lv_pxp_utils.c",
    "src/draw/opengles/lv_draw_opengles.c",
    "src/draw/renesas/dave2d/lv_draw_dave2d.c",
    "src/draw/renesas/dave2d/lv_draw_dave2d_arc.c",
    "src/draw/renesas/dave2d/lv_draw_dave2d_border.c",
    "src/draw/renesas/dave2d/lv_draw_dave2d_fill.c",
    "src/draw/renesas/dave2d/lv_draw_dave2d_image.c",
    "src/draw/renesas/dave2d/lv_draw_dave2d_label.c",
    "src/draw/renesas/dave2d/lv_draw_dave2d_line.c",
    "src/draw/renesas/dave2d/lv_draw_dave2d_mask_rectangle.c",
    "src/draw/renesas/dave2d/lv_draw_dave2d_triangle.c",
    "src/draw/renesas/dave2d/lv_draw_dave2d_utils.c",
    "src/draw/sdl/lv_draw_sdl.c",
    "src/draw/snapshot/lv_snapshot.c",
    "src/draw/sw/blend/lv_draw_sw_blend.c",
    "src/draw/sw/blend/lv_draw_sw_blend_to_a8.c",
    "src/draw/sw/blend/lv_draw_sw_blend_to_al88.c",
    "src/draw/sw/blend/lv_draw_sw_blend_to_argb8888.c",
    "src/draw/sw/blend/lv_draw_sw_blend_to_argb8888_premultiplied.c",
    "src/draw/sw/blend/lv_draw_sw_blend_to_i1.c",
    "src/draw/sw/blend/lv_draw_sw_blend_to_l8.c",
    "src/draw/sw/blend/lv_draw_sw_blend_to_rgb565.c",
    "src/draw/sw/blend/lv_draw_sw_blend_to_rgb565_swapped.c",
    "src/draw/sw/blend/lv_draw_sw_blend_to_rgb888.c",
    "src/draw/sw/blend/neon/lv_draw_sw_blend_neon_to_rgb565.c",
    "src/draw/sw/blend/neon/lv_draw_sw_blend_neon_to_rgb888.c",
    "src/draw/sw/blend/riscv_v/lv_draw_sw_blend_riscv_v_to_rgb888.c",
    "src/draw/sw/lv_draw_sw.c",
    "src/draw/sw/lv_draw_sw_arc.c",
    "src/draw/sw/lv_draw_sw_blur.c",
    "src/draw/sw/lv_draw_sw_border.c",
    "src/draw/sw/lv_draw_sw_box_shadow.c",
    "src/draw/sw/lv_draw_sw_fill.c",
    "src/draw/sw/lv_draw_sw_grad.c",
    "src/draw/sw/lv_draw_sw_img.c",
    "src/draw/sw/lv_draw_sw_letter.c",
    "src/draw/sw/lv_draw_sw_line.c",
    "src/draw/sw/lv_draw_sw_mask.c",
    "src/draw/sw/lv_draw_sw_mask_rect.c",
    "src/draw/sw/lv_draw_sw_transform.c",
    "src/draw/sw/lv_draw_sw_triangle.c",
    "src/draw/sw/lv_draw_sw_utils.c",
    "src/draw/sw/lv_draw_sw_vector.c",
    "src/draw/vg_lite/lv_draw_buf_vg_lite.c",
    "src/draw/vg_lite/lv_draw_vg_lite.c",
    "src/draw/vg_lite/lv_draw_vg_lite_arc.c",
    "src/draw/vg_lite/lv_draw_vg_lite_border.c",
    "src/draw/vg_lite/lv_draw_vg_lite_box_shadow.c",
    "src/draw/vg_lite/lv_draw_vg_lite_fill.c",
    "src/draw/vg_lite/lv_draw_vg_lite_img.c",
    "src/draw/vg_lite/lv_draw_vg_lite_label.c",
    "src/draw/vg_lite/lv_draw_vg_lite_layer.c",
    "src/draw/vg_lite/lv_draw_vg_lite_line.c",
    "src/draw/vg_lite/lv_draw_vg_lite_mask_rect.c",
    "src/draw/vg_lite/lv_draw_vg_lite_triangle.c",
    "src/draw/vg_lite/lv_draw_vg_lite_vector.c",
    "src/draw/vg_lite/lv_vg_lite_bitmap_font_cache.c",
    "src/draw/vg_lite/lv_vg_lite_decoder.c",
    "src/draw/vg_lite/lv_vg_lite_grad.c",
    "src/draw/vg_lite/lv_vg_lite_math.c",
    "src/draw/vg_lite/lv_vg_lite_path.c",
    "src/draw/vg_lite/lv_vg_lite_pending.c",
    "src/draw/vg_lite/lv_vg_lite_stroke.c",
    "src/draw/vg_lite/lv_vg_lite_utils.c",
    "src/drivers/display/drm/lv_linux_drm.c",
    "src/drivers/display/drm/lv_linux_drm_common.c",
    "src/drivers/display/drm/lv_linux_drm_egl.c",
    "src/drivers/display/fb/lv_linux_fbdev.c",
    "src/drivers/display/ft81x/lv_ft81x.c",
    "src/drivers/display/ili9341/lv_ili9341.c",
    "src/drivers/display/lcd/lv_lcd_generic_mipi.c",
    "src/drivers/display/nv3007/lv_nv3007.c",
    "src/drivers/display/nxp_elcdif/lv_nxp_elcdif.c",
    "src/drivers/display/renesas_glcdc/lv_renesas_glcdc.c",
    "src/drivers/display/st7735/lv_st7735.c",
    "src/drivers/display/st7789/lv_st7789.c",
    "src/drivers/display/st7796/lv_st7796.c",
    "src/drivers/display/st_ltdc/lv_st_ltdc.c",
    "src/drivers/draw/eve/lv_draw_eve_display.c",
    "src/drivers/evdev/lv_evdev.c",
    "src/drivers/libinput/lv_libinput.c",
    "src/drivers/libinput/lv_xkb.c",
    "src/drivers/nuttx/lv_nuttx_cache.c",
    "src/drivers/nuttx/lv_nuttx_entry.c",
    "src/drivers/nuttx/lv_nuttx_fbdev.c",
    "src/drivers/nuttx/lv_nuttx_image_cache.c",
    "src/drivers/nuttx/lv_nuttx_lcd.c",
    "src/drivers/nuttx/lv_nuttx_libuv.c",
    "src/drivers/nuttx/lv_nuttx_mouse.c",
    "src/drivers/nuttx/lv_nuttx_profiler.c",
    "src/drivers/nuttx/lv_nuttx_touchscreen.c",
    "src/drivers/opengles/assets/lv_opengles_shader.c",
    "src/drivers/opengles/glad/src/egl.c",
    "src/drivers/opengles/glad/src/gl.c",
    "src/drivers/opengles/glad/src/gles2.c",
    "src/drivers/opengles/lv_opengles_debug.c",
    "src/drivers/opengles/lv_opengles_driver.c",
    "src/drivers/opengles/lv_opengles_egl.c",
    "src/drivers/opengles/lv_opengles_glfw.c",
    "src/drivers/opengles/lv_opengles_texture.c",
    "src/drivers/opengles/opengl_shader/lv_opengl_shader_manager.c",
    "src/drivers/opengles/opengl_shader/lv_opengl_shader_program.c",
    "src/drivers/qnx/lv_qnx.c",
    "src/drivers/sdl/lv_sdl_egl.c",
    "src/drivers/sdl/lv_sdl_keyboard.c",
    "src/drivers/sdl/lv_sdl_mouse.c",
    "src/drivers/sdl/lv_sdl_mousewheel.c",
    "src/drivers/sdl/lv_sdl_sw.c",
    "src/drivers/sdl/lv_sdl_texture.c",
    "src/drivers/sdl/lv_sdl_window.c",
    "src/drivers/uefi/lv_uefi_context.c",
    "src/drivers/uefi/lv_uefi_display.c",
    "src/drivers/uefi/lv_uefi_indev_keyboard.c",
    "src/drivers/uefi/lv_uefi_indev_pointer.c",
    "src/drivers/uefi/lv_uefi_indev_touch.c",
    "src/drivers/uefi/lv_uefi_private.c",
    "src/drivers/wayland/lv_wayland.c",
    "src/drivers/wayland/lv_wl_egl_backend.c",
    "src/drivers/wayland/lv_wl_g2d_backend.c",
    "src/drivers/wayland/lv_wl_keyboard.c",
    "src/drivers/wayland/lv_wl_pointer.c",
    "src/drivers/wayland/lv_wl_seat.c",
    "src/drivers/wayland/lv_wl_shm_backend.c",
    "src/drivers/wayland/lv_wl_touch.c",
    "src/drivers/wayland/lv_wl_window.c",
    "src/drivers/wayland/lv_wl_xdg_shell.c",
    "src/drivers/windows/lv_windows_context.c",
    "src/drivers/windows/lv_windows_display.c",
    "src/drivers/windows/lv_windows_input.c",
    "src/drivers/x11/lv_x11_display.c",
    "src/drivers/x11/lv_x11_input.c",
    "src/font/binfont_loader/lv_binfont_loader.c",
    "src/font/fmt_txt/lv_font_fmt_txt.c",
    "src/font/font_manager/lv_font_manager.c",
    "src/font/font_manager/lv_font_manager_recycle.c",
    "src/font/imgfont/lv_imgfont.c",
    "src/font/lv_font.c",
    "src/font/lv_font_dejavu_16_persian_hebrew.c",
    "src/font/lv_font_montserrat_10.c",
    "src/font/lv_font_montserrat_12.c",
    "src/font/lv_font_montserrat_14.c",
    "src/font/lv_font_montserrat_14_aligned.c",
    "src/font/lv_font_montserrat_16.c",
    "src/font/lv_font_montserrat_18.c",
    "src/font/lv_font_montserrat_20.c",
    "src/font/lv_font_montserrat_22.c",
    "src/font/lv_font_montserrat_24.c",
    "src/font/lv_font_montserrat_26.c",
    "src/font/lv_font_montserrat_28.c",
    "src/font/lv_font_montserrat_28_compressed.c",
    "src/font/lv_font_montserrat_30.c",
    "src/font/lv_font_montserrat_32.c",
    "src/font/lv_font_montserrat_34.c",
    "src/font/lv_font_montserrat_36.c",
    "src/font/lv_font_montserrat_38.c",
    "src/font/lv_font_montserrat_40.c",
    "src/font/lv_font_montserrat_42.c",
    "src/font/lv_font_montserrat_44.c",
    "src/font/lv_font_montserrat_46.c",
    "src/font/lv_font_montserrat_48.c",
    "src/font/lv_font_montserrat_8.c",
    "src/font/lv_font_source_han_sans_sc_14_cjk.c",
    "src/font/lv_font_source_han_sans_sc_16_cjk.c",
    "src/font/lv_font_unscii_16.c",
    "src/font/lv_font_unscii_8.c",
    "src/indev/lv_gridnav.c",
    "src/indev/lv_indev.c",
    "src/indev/lv_indev_gesture.c",
    "src/indev/lv_indev_scroll.c",
    "src/layouts/flex/lv_flex.c",
    "src/layouts/grid/lv_grid.c",
    "src/layouts/lv_layout.c",
    "src/libs/FT800-FT813/EVE_commands.c",
    "src/libs/FT800-FT813/EVE_supplemental.c",
    "src/libs/barcode/code128.c",
    "src/libs/barcode/lv_barcode.c",
    "src/libs/bin_decoder/lv_bin_decoder.c",
    "src/libs/bmp/lv_bmp.c",
    "src/libs/ffmpeg/lv_ffmpeg.c",
    "src/libs/freetype/lv_freetype.c",
    "src/libs/freetype/lv_freetype_glyph.c",
    "src/libs/freetype/lv_freetype_image.c",
    "src/libs/freetype/lv_freetype_outline.c",
    "src/libs/freetype/lv_ftsystem.c",
    "src/libs/frogfs/src/decomp_raw.c",
    "src/libs/frogfs/src/frogfs.c",
    "src/libs/fsdrv/lv_fs_cbfs.c",
    "src/libs/fsdrv/lv_fs_fatfs.c",
    "src/libs/fsdrv/lv_fs_frogfs.c",
    "src/libs/fsdrv/lv_fs_littlefs.c",
    "src/libs/fsdrv/lv_fs_memfs.c",
    "src/libs/fsdrv/lv_fs_posix.c",
    "src/libs/fsdrv/lv_fs_stdio.c",
    "src/libs/fsdrv/lv_fs_uefi.c",
    "src/libs/fsdrv/lv_fs_win32.c",
    "src/libs/gif/gif.c",
    "src/libs/gltf/gltf_environment/lv_gltf_ibl_sampler.c",
    "src/libs/gltf/gltf_view/assets/chromatic.c",
    "src/libs/gltf/gltf_view/assets/lv_gltf_view_shader.c",
    "src/libs/gltf/math/lv_3dmath.c",
    "src/libs/gstreamer/lv_gstreamer.c",
    "src/libs/libjpeg_turbo/lv_libjpeg_turbo.c",
    "src/libs/libpng/lv_libpng.c",
    "src/libs/libwebp/lv_libwebp.c",
    "src/libs/lodepng/lodepng.c",
    "src/libs/lodepng/lv_lodepng.c",
    "src/libs/lz4/lz4.c",
    "src/libs/nanovg/nanovg.c",
    "src/libs/qrcode/lv_qrcode.c",
    "src/libs/qrcode/qrcodegen.c",
    "src/libs/rle/lv_rle.c",
    "src/libs/rlottie/lv_rlottie.c",
    "src/libs/svg/lv_svg.c",
    "src/libs/svg/lv_svg_decoder.c",
    "src/libs/svg/lv_svg_parser.c",
    "src/libs/svg/lv_svg_render.c",
    "src/libs/svg/lv_svg_token.c",
    "src/libs/tiny_ttf/lv_tiny_ttf.c",
    "src/libs/tjpgd/lv_tjpgd.c",
    "src/libs/tjpgd/tjpgd.c",
    "src/libs/vg_lite_driver/VGLite/vg_lite.c",
    "src/libs/vg_lite_driver/VGLite/vg_lite_image.c",
    "src/libs/vg_lite_driver/VGLite/vg_lite_matrix.c",
    "src/libs/vg_lite_driver/VGLite/vg_lite_path.c",
    "src/libs/vg_lite_driver/VGLite/vg_lite_stroke.c",
    "src/libs/vg_lite_driver/VGLiteKernel/vg_lite_kernel.c",
    "src/libs/vg_lite_driver/lv_vg_lite_hal/lv_vg_lite_hal.c",
    "src/libs/vg_lite_driver/lv_vg_lite_hal/vg_lite_os.c",
    "src/lv_init.c",
    "src/misc/cache/class/lv_cache_lru_ll.c",
    "src/misc/cache/class/lv_cache_lru_rb.c",
    "src/misc/cache/class/lv_cache_sc_da.c",
    "src/misc/cache/instance/lv_image_cache.c",
    "src/misc/cache/instance/lv_image_header_cache.c",
    "src/misc/cache/lv_cache.c",
    "src/misc/cache/lv_cache_entry.c",
    "src/misc/lv_anim.c",
    "src/misc/lv_anim_timeline.c",
    "src/misc/lv_area.c",
    "src/misc/lv_array.c",
    "src/misc/lv_async.c",
    "src/misc/lv_bidi.c",
    "src/misc/lv_circle_buf.c",
    "src/misc/lv_color.c",
    "src/misc/lv_color_op.c",
    "src/misc/lv_event.c",
    "src/misc/lv_fs.c",
    "src/misc/lv_grad.c",
    "src/misc/lv_iter.c",
    "src/misc/lv_ll.c",
    "src/misc/lv_log.c",
    "src/misc/lv_lru.c",
    "src/misc/lv_math.c",
    "src/misc/lv_matrix.c",
    "src/misc/lv_palette.c",
    "src/misc/lv_pending.c",
    "src/misc/lv_profiler_builtin.c",
    "src/misc/lv_profiler_builtin_posix.c",
    "src/misc/lv_rb.c",
    "src/misc/lv_style.c",
    "src/misc/lv_style_gen.c",
    "src/misc/lv_templ.c",
    "src/misc/lv_text.c",
    "src/misc/lv_text_ap.c",
    "src/misc/lv_timer.c",
    "src/misc/lv_tree.c",
    "src/misc/lv_utils.c",
    "src/osal/lv_cmsis_rtos2.c",
    "src/osal/lv_freertos.c",
    "src/osal/lv_linux.c",
    "src/osal/lv_mqx.c",
    "src/osal/lv_os.c",
    "src/osal/lv_os_none.c",
    "src/osal/lv_pthread.c",
    "src/osal/lv_rtthread.c",
    "src/osal/lv_sdl2.c",
    "src/osal/lv_windows.c",
    "src/others/file_explorer/lv_file_explorer.c",
    "src/others/fragment/lv_fragment.c",
    "src/others/fragment/lv_fragment_manager.c",
    "src/others/translation/lv_translation.c",
    "src/stdlib/builtin/lv_mem_core_builtin.c",
    "src/stdlib/builtin/lv_sprintf_builtin.c",
    "src/stdlib/builtin/lv_string_builtin.c",
    "src/stdlib/builtin/lv_tlsf.c",
    "src/stdlib/clib/lv_mem_core_clib.c",
    "src/stdlib/clib/lv_sprintf_clib.c",
    "src/stdlib/clib/lv_string_clib.c",
    "src/stdlib/lv_mem.c",
    "src/stdlib/micropython/lv_mem_core_micropython.c",
    "src/stdlib/rtthread/lv_mem_core_rtthread.c",
    "src/stdlib/rtthread/lv_sprintf_rtthread.c",
    "src/stdlib/rtthread/lv_string_rtthread.c",
    "src/stdlib/uefi/lv_mem_core_uefi.c",
    "src/themes/default/lv_theme_default.c",
    "src/themes/lv_theme.c",
    "src/themes/mono/lv_theme_mono.c",
    "src/themes/simple/lv_theme_simple.c",
    "src/tick/lv_tick.c",
    "src/widgets/3dtexture/lv_3dtexture.c",
    "src/widgets/animimage/lv_animimage.c",
    "src/widgets/arc/lv_arc.c",
    "src/widgets/arclabel/lv_arclabel.c",
    "src/widgets/bar/lv_bar.c",
    "src/widgets/button/lv_button.c",
    "src/widgets/buttonmatrix/lv_buttonmatrix.c",
    "src/widgets/calendar/lv_calendar.c",
    "src/widgets/calendar/lv_calendar_chinese.c",
    "src/widgets/calendar/lv_calendar_header_arrow.c",
    "src/widgets/calendar/lv_calendar_header_dropdown.c",
    "src/widgets/canvas/lv_canvas.c",
    "src/widgets/chart/lv_chart.c",
    "src/widgets/checkbox/lv_checkbox.c",
    "src/widgets/dropdown/lv_dropdown.c",
    "src/widgets/gif/lv_gif.c",
    "src/widgets/image/lv_image.c",
    "src/widgets/imagebutton/lv_imagebutton.c",
    "src/widgets/ime/lv_ime_pinyin.c",
    "src/widgets/keyboard/lv_keyboard.c",
    "src/widgets/label/lv_label.c",
    "src/widgets/led/lv_led.c",
    "src/widgets/line/lv_line.c",
    "src/widgets/list/lv_list.c",
    "src/widgets/lottie/lv_lottie.c",
    "src/widgets/menu/lv_menu.c",
    "src/widgets/msgbox/lv_msgbox.c",
    "src/widgets/objx_templ/lv_objx_templ.c",
    "src/widgets/property/lv_animimage_properties.c",
    "src/widgets/property/lv_arc_properties.c",
    "src/widgets/property/lv_bar_properties.c",
    "src/widgets/property/lv_buttonmatrix_properties.c",
    "src/widgets/property/lv_chart_properties.c",
    "src/widgets/property/lv_checkbox_properties.c",
    "src/widgets/property/lv_dropdown_properties.c",
    "src/widgets/property/lv_image_properties.c",
    "src/widgets/property/lv_keyboard_properties.c",
    "src/widgets/property/lv_label_properties.c",
    "src/widgets/property/lv_led_properties.c",
    "src/widgets/property/lv_line_properties.c",
    "src/widgets/property/lv_menu_properties.c",
    "src/widgets/property/lv_obj_properties.c",
    "src/widgets/property/lv_roller_properties.c",
    "src/widgets/property/lv_scale_properties.c",
    "src/widgets/property/lv_slider_properties.c",
    "src/widgets/property/lv_span_properties.c",
    "src/widgets/property/lv_spinbox_properties.c",
    "src/widgets/property/lv_spinner_properties.c",
    "src/widgets/property/lv_style_properties.c",
    "src/widgets/property/lv_switch_properties.c",
    "src/widgets/property/lv_table_properties.c",
    "src/widgets/property/lv_tabview_properties.c",
    "src/widgets/property/lv_textarea_properties.c",
    "src/widgets/roller/lv_roller.c",
    "src/widgets/scale/lv_scale.c",
    "src/widgets/slider/lv_slider.c",
    "src/widgets/span/lv_span.c",
    "src/widgets/spinbox/lv_spinbox.c",
    "src/widgets/spinner/lv_spinner.c",
    "src/widgets/switch/lv_switch.c",
    "src/widgets/table/lv_table.c",
    "src/widgets/tabview/lv_tabview.c",
    "src/widgets/textarea/lv_textarea.c",
    "src/widgets/tileview/lv_tileview.c",
    "src/widgets/win/lv_win.c",
};

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    resolved_target = target;
    resolved_optimize = optimize;

    const repo = GitRepo.addGitRepo(b, .{
        .git_repo = upstream_repo,
        .commit = upstream_commit,
    });
    const custom_config_header = b.option(
        std.Build.LazyPath,
        "lvgl_config_header",
        "Optional path to a complete LVGL config header; otherwise embed-zig includes pkg/lvgl/config.default.h",
    );
    has_custom_config_header = custom_config_header != null;
    const config_header = createConfigHeader(
        b,
        custom_config_header orelse b.path("pkg/lvgl/config.default.h"),
    );

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "lvgl",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_c = .off,
        }),
    });
    lib.root_module.addConfigHeader(config_header);
    lib.root_module.addIncludePath(repo.includePath("."));
    lib.root_module.addIncludePath(b.path("pkg/lvgl/include"));
    if (b.sysroot) |sysroot| {
        lib.root_module.addSystemIncludePath(.{
            .cwd_relative = b.pathJoin(&.{ sysroot, "include" }),
        });
    }
    lib.root_module.addCSourceFiles(.{
        .root = repo.root(),
        .files = c_sources,
    });
    lib.root_module.addCSourceFile(.{ .file = b.path("pkg/lvgl/src/binding.c") });
    repo.dependOn(&lib.step);

    const mod = b.createModule(.{
        .root_source_file = b.path("pkg/lvgl.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addConfigHeader(config_header);
    mod.addIncludePath(repo.includePath("."));
    mod.addIncludePath(b.path("pkg/lvgl/include"));
    if (b.sysroot) |sysroot| {
        mod.addSystemIncludePath(.{
            .cwd_relative = b.pathJoin(&.{ sysroot, "include" }),
        });
    }
    b.modules.put("lvgl", mod) catch @panic("OOM");

    const osal_mod = b.createModule(.{
        .root_source_file = b.path("pkg/lvgl_osal.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    osal_mod.addConfigHeader(config_header);
    osal_mod.addIncludePath(repo.includePath("."));
    osal_mod.addIncludePath(b.path("pkg/lvgl/include"));
    if (b.sysroot) |sysroot| {
        osal_mod.addSystemIncludePath(.{
            .cwd_relative = b.pathJoin(&.{ sysroot, "include" }),
        });
    }
    b.modules.put("lvgl_osal", osal_mod) catch @panic("OOM");

    b.installArtifact(lib);
    library = lib;
    osal_module = osal_mod;
}

pub fn link(b: *std.Build) void {
    const drivers = b.modules.get("drivers") orelse @panic("lvgl requires drivers");
    const lib = library orelse @panic("lvgl library missing");
    const mod = b.modules.get("lvgl") orelse @panic("lvgl module missing");
    mod.addImport("drivers", drivers);
    mod.linkLibrary(lib);
}

pub fn linkTest(_: *std.Build, compile: *std.Build.Step.Compile) void {
    const embed = compile.step.owner.modules.get("embed") orelse @panic("lvgl tests require embed");
    const drivers = compile.step.owner.modules.get("drivers") orelse @panic("lvgl tests require drivers");
    const testing = compile.step.owner.modules.get("testing") orelse @panic("lvgl tests require testing");
    compile.root_module.addImport("embed", embed);
    compile.root_module.addImport("drivers", drivers);
    compile.root_module.addImport("testing", testing);
    if (!has_custom_config_header) {
        const osal = osal_library orelse createOsalLibrary(compile.step.owner);
        compile.linkLibrary(osal);
    }
}

fn createOsalLibrary(b: *std.Build) *std.Build.Step.Compile {
    if (osal_library) |osal| return osal;

    const target = resolved_target orelse @panic("lvgl target missing");
    const optimize = resolved_optimize orelse @panic("lvgl optimize missing");
    const repo = GitRepo.addGitRepo(b, .{
        .git_repo = upstream_repo,
        .commit = upstream_commit,
    });
    const embed = b.modules.get("embed") orelse @panic("lvgl osal impl requires embed");
    const impl_mod = b.createModule(.{
        .root_source_file = b.path("lib/embed_std/embed.zig"),
        .target = target,
        .optimize = optimize,
    });
    impl_mod.addImport("embed", embed);
    const osal_mod = osal_module orelse @panic("lvgl_osal module missing");
    const write_files = b.addWriteFiles();
    const root_source = write_files.add("lvgl_osal_root.zig",
        \\const std = @import("std");
        \\const embed = @import("embed");
        \\const lvgl_osal = @import("lvgl_osal");
        \\const runtime = embed.make(@import("lvgl_osal_impl"));
        \\
        \\comptime {
        \\    _ = lvgl_osal.make(runtime, std.heap.page_allocator);
        \\}
        \\
    );

    const osal = b.addLibrary(.{
        .linkage = .static,
        .name = "lvgl_osal",
        .root_module = b.createModule(.{
            .root_source_file = root_source,
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_c = .off,
        }),
    });
    osal.root_module.addImport("embed", embed);
    osal.root_module.addImport("lvgl_osal_impl", impl_mod);
    osal.root_module.addImport("lvgl_osal", osal_mod);
    repo.dependOn(&osal.step);

    osal_library = osal;
    return osal;
}

fn createConfigHeader(
    b: *std.Build,
    selected_header: std.Build.LazyPath,
) *std.Build.Step.ConfigHeader {
    const write_files = b.addWriteFiles();
    const template = write_files.add("lvgl_config_header.template",
        \\#ifndef EMBED_ZIG_LV_CONF_WRAPPER_H
        \\#define EMBED_ZIG_LV_CONF_WRAPPER_H
        \\
        \\/* embed-zig fixes LVGL to the custom OS ABI used by lvgl_osal. */
        \\#define LV_USE_OS LV_OS_CUSTOM
        \\#define LV_OS_CUSTOM_INCLUDE "@LVGL_OS_CUSTOM_INCLUDE@"
        \\
        \\#include "@LVGL_SELECTED_CONFIG_HEADER@"
        \\
        \\#undef LV_USE_OS
        \\#define LV_USE_OS LV_OS_CUSTOM
        \\#undef LV_OS_CUSTOM_INCLUDE
        \\#define LV_OS_CUSTOM_INCLUDE "@LVGL_OS_CUSTOM_INCLUDE@"
        \\#endif
        \\
    );
    return b.addConfigHeader(.{
        .style = .{ .autoconf_at = template },
        .include_path = "lv_conf.h",
    }, .{
        .LVGL_SELECTED_CONFIG_HEADER = normalizeIncludePath(b, selected_header),
        .LVGL_OS_CUSTOM_INCLUDE = bundled_custom_include,
    });
}

fn normalizeIncludePath(b: *std.Build, header: std.Build.LazyPath) []const u8 {
    const raw = header.getPath(b);
    const resolved = if (std.fs.path.isAbsolute(raw))
        raw
    else
        b.pathFromRoot(raw);
    return std.mem.replaceOwned(u8, b.allocator, resolved, "\\", "/") catch @panic("OOM");
}

