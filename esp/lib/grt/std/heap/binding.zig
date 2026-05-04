pub extern fn espz_heap_align_freertos_stack_size_bytes(size: u32) u32;
pub extern fn espz_heap_caps_malloc(size: usize, caps: u32) ?*anyopaque;
pub extern fn espz_heap_caps_aligned_alloc(alignment: usize, size: usize, caps: u32) ?*anyopaque;
pub extern fn espz_heap_caps_free(ptr: ?*anyopaque) void;

pub extern const espz_heap_cap_32bit: u32;
pub extern const espz_heap_cap_8bit: u32;
pub extern const espz_heap_cap_dma: u32;
pub extern const espz_heap_cap_pid2: u32;
pub extern const espz_heap_cap_pid3: u32;
pub extern const espz_heap_cap_pid4: u32;
pub extern const espz_heap_cap_pid5: u32;
pub extern const espz_heap_cap_pid6: u32;
pub extern const espz_heap_cap_pid7: u32;
pub extern const espz_heap_cap_spiram: u32;
pub extern const espz_heap_cap_internal: u32;
pub extern const espz_heap_cap_default: u32;
pub extern const espz_heap_cap_iram_8bit: u32;
pub extern const espz_heap_cap_retention: u32;
pub extern const espz_heap_cap_rtcram: u32;
pub extern const espz_heap_cap_tcm: u32;
pub extern const espz_heap_cap_dma_desc_ahb: u32;
pub extern const espz_heap_cap_dma_desc_axi: u32;
pub extern const espz_heap_cap_cache_aligned: u32;
pub extern const espz_heap_cap_invalid: u32;

pub extern fn espz_heap_malloc_cap_spiram() u32;
pub extern fn espz_heap_malloc_cap_internal() u32;
pub extern fn espz_heap_malloc_cap_8bit() u32;
