#include <stddef.h>
#include <stdint.h>

#include "esp_heap_caps.h"
#include "freertos/FreeRTOS.h"

static uint32_t espz_stack_words_from_bytes(uint32_t bytes)
{
    const uint32_t word = (uint32_t)sizeof(StackType_t);
    if (bytes == 0 || word == 0) {
        return 0;
    }
    return (bytes + word - 1U) / word;
}

const uint32_t espz_heap_cap_32bit = (uint32_t)MALLOC_CAP_32BIT;
const uint32_t espz_heap_cap_8bit = (uint32_t)MALLOC_CAP_8BIT;
const uint32_t espz_heap_cap_dma = (uint32_t)MALLOC_CAP_DMA;
const uint32_t espz_heap_cap_pid2 = (uint32_t)MALLOC_CAP_PID2;
const uint32_t espz_heap_cap_pid3 = (uint32_t)MALLOC_CAP_PID3;
const uint32_t espz_heap_cap_pid4 = (uint32_t)MALLOC_CAP_PID4;
const uint32_t espz_heap_cap_pid5 = (uint32_t)MALLOC_CAP_PID5;
const uint32_t espz_heap_cap_pid6 = (uint32_t)MALLOC_CAP_PID6;
const uint32_t espz_heap_cap_pid7 = (uint32_t)MALLOC_CAP_PID7;
const uint32_t espz_heap_cap_spiram = (uint32_t)MALLOC_CAP_SPIRAM;
const uint32_t espz_heap_cap_internal = (uint32_t)MALLOC_CAP_INTERNAL;
const uint32_t espz_heap_cap_default = (uint32_t)MALLOC_CAP_DEFAULT;
const uint32_t espz_heap_cap_iram_8bit = (uint32_t)MALLOC_CAP_IRAM_8BIT;
const uint32_t espz_heap_cap_retention = (uint32_t)MALLOC_CAP_RETENTION;
const uint32_t espz_heap_cap_rtcram = (uint32_t)MALLOC_CAP_RTCRAM;
const uint32_t espz_heap_cap_tcm = (uint32_t)MALLOC_CAP_TCM;
const uint32_t espz_heap_cap_dma_desc_ahb = (uint32_t)MALLOC_CAP_DMA_DESC_AHB;
const uint32_t espz_heap_cap_dma_desc_axi = (uint32_t)MALLOC_CAP_DMA_DESC_AXI;
const uint32_t espz_heap_cap_cache_aligned = (uint32_t)MALLOC_CAP_CACHE_ALIGNED;
const uint32_t espz_heap_cap_invalid = (uint32_t)MALLOC_CAP_INVALID;

uint32_t espz_heap_align_freertos_stack_size_bytes(uint32_t bytes)
{
    return espz_stack_words_from_bytes(bytes) * (uint32_t)sizeof(StackType_t);
}

void *espz_heap_caps_malloc(size_t size, uint32_t caps)
{
    return heap_caps_malloc(size, (uint32_t)caps);
}

void *espz_heap_caps_aligned_alloc(size_t alignment, size_t size, uint32_t caps)
{
    return heap_caps_aligned_alloc(alignment, size, (uint32_t)caps);
}

void espz_heap_caps_free(void *ptr)
{
    heap_caps_free(ptr);
}

uint32_t espz_heap_malloc_cap_spiram(void)
{
    return (uint32_t)MALLOC_CAP_SPIRAM;
}

uint32_t espz_heap_malloc_cap_internal(void)
{
    return (uint32_t)MALLOC_CAP_INTERNAL;
}

uint32_t espz_heap_malloc_cap_8bit(void)
{
    return (uint32_t)MALLOC_CAP_8BIT;
}
