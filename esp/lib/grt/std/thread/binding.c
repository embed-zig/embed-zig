#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "sdkconfig.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "freertos/idf_additions.h"

static portMUX_TYPE espz_global_critical_lock = portMUX_INITIALIZER_UNLOCKED;

typedef struct {
    char name[16];
    uint64_t runtime;
} espz_task_runtime_entry_t;

static uint32_t espz_stack_words_from_bytes(uint32_t bytes)
{
    const uint32_t word = (uint32_t)sizeof(StackType_t);
    if (bytes == 0 || word == 0) {
        return 0;
    }
    return (bytes + word - 1U) / word;
}

SemaphoreHandle_t espz_semaphore_create_mutex(void)
{
    return xSemaphoreCreateMutex();
}

SemaphoreHandle_t espz_semaphore_create_binary(void)
{
    return xSemaphoreCreateBinary();
}

SemaphoreHandle_t espz_semaphore_create_counting(uint32_t max_count, uint32_t initial_count)
{
    return xSemaphoreCreateCounting((UBaseType_t)max_count, (UBaseType_t)initial_count);
}

int32_t espz_semaphore_take(SemaphoreHandle_t handle, uint32_t ticks)
{
    return (int32_t)xSemaphoreTake(handle, (TickType_t)ticks);
}

int32_t espz_semaphore_give(SemaphoreHandle_t handle)
{
    return (int32_t)xSemaphoreGive(handle);
}

void espz_semaphore_delete(SemaphoreHandle_t handle)
{
    vSemaphoreDelete(handle);
}

QueueHandle_t espz_queue_create(uint32_t length, uint32_t item_size)
{
    return xQueueCreate((UBaseType_t)length, (UBaseType_t)item_size);
}

int32_t espz_queue_send(QueueHandle_t q, const void *item, uint32_t ticks)
{
    return (int32_t)xQueueSend(q, item, (TickType_t)ticks);
}

int32_t espz_queue_receive(QueueHandle_t q, void *buffer, uint32_t ticks)
{
    return (int32_t)xQueueReceive(q, buffer, (TickType_t)ticks);
}

uint32_t espz_queue_messages_waiting(QueueHandle_t q)
{
    return (uint32_t)uxQueueMessagesWaiting(q);
}

void espz_queue_delete(QueueHandle_t q)
{
    vQueueDelete(q);
}

QueueSetHandle_t espz_queue_create_set(uint32_t length)
{
    return xQueueCreateSet((UBaseType_t)length);
}

int32_t espz_queue_add_to_set(QueueSetMemberHandle_t member, QueueSetHandle_t set)
{
    return (int32_t)xQueueAddToSet(member, set);
}

int32_t espz_queue_remove_from_set(QueueSetMemberHandle_t member, QueueSetHandle_t set)
{
    return (int32_t)xQueueRemoveFromSet(member, set);
}

QueueSetMemberHandle_t espz_queue_select_from_set(QueueSetHandle_t set, uint32_t ticks)
{
    return xQueueSelectFromSet(set, (TickType_t)ticks);
}

uint32_t espz_freertos_align_stack_size_bytes(uint32_t bytes)
{
    return espz_stack_words_from_bytes(bytes) * (uint32_t)sizeof(StackType_t);
}

uint32_t espz_freertos_static_task_size_bytes(void)
{
    return (uint32_t)sizeof(StaticTask_t);
}

uint32_t espz_freertos_static_task_align_bytes(void)
{
    return (uint32_t)__alignof__(StaticTask_t);
}

uint32_t espz_freertos_stack_type_align_bytes(void)
{
    return (uint32_t)__alignof__(StackType_t);
}

uint32_t espz_freertos_stack_align_bytes(void)
{
    return (uint32_t)portBYTE_ALIGNMENT;
}

int32_t espz_freertos_thread_spawn(
    TaskFunction_t task_fn,
    const char *name,
    uint32_t stack_size_bytes,
    void *ctx,
    uint32_t priority,
    TaskHandle_t *out_handle,
    int32_t core_id)
{
    return (int32_t)xTaskCreatePinnedToCore(
        task_fn,
        name,
        espz_stack_words_from_bytes(stack_size_bytes),
        ctx,
        (UBaseType_t)priority,
        out_handle,
        (BaseType_t)core_id);
}

int32_t espz_freertos_thread_spawn_static(
    TaskFunction_t task_fn,
    const char *name,
    uint32_t stack_size_bytes,
    void *ctx,
    uint32_t priority,
    void *stack_buffer,
    void *task_buffer,
    TaskHandle_t *out_handle,
    int32_t core_id)
{
    TaskHandle_t handle = xTaskCreateStaticPinnedToCore(
        task_fn,
        name,
        espz_stack_words_from_bytes(stack_size_bytes),
        ctx,
        (UBaseType_t)priority,
        (StackType_t *)stack_buffer,
        (StaticTask_t *)task_buffer,
        (BaseType_t)core_id);
    if (handle == NULL) {
        return 0;
    }
    *out_handle = handle;
    return (int32_t)pdTRUE;
}

int32_t espz_freertos_thread_spawn_with_caps(
    TaskFunction_t task_fn,
    const char *name,
    uint32_t stack_size_bytes,
    void *ctx,
    uint32_t priority,
    TaskHandle_t *out_handle,
    int32_t core_id,
    uint32_t memory_caps)
{
    return (int32_t)xTaskCreatePinnedToCoreWithCaps(
        task_fn,
        name,
        stack_size_bytes,
        ctx,
        (UBaseType_t)priority,
        out_handle,
        (BaseType_t)core_id,
        (UBaseType_t)memory_caps);
}

void espz_freertos_task_delay(uint32_t ticks)
{
    vTaskDelay((TickType_t)ticks);
}

void espz_freertos_task_delete(TaskHandle_t task)
{
    vTaskDelete(task);
}

void espz_freertos_task_delete_with_caps(TaskHandle_t task)
{
    vTaskDeleteWithCaps(task);
}

void espz_freertos_task_suspend(TaskHandle_t task)
{
    vTaskSuspend(task);
}

void espz_freertos_global_critical_enter(void)
{
    portENTER_CRITICAL(&espz_global_critical_lock);
}

void espz_freertos_global_critical_exit(void)
{
    portEXIT_CRITICAL(&espz_global_critical_lock);
}

void espz_freertos_thread_yield(void)
{
    taskYIELD();
}

uint32_t espz_freertos_tick_rate_hz(void)
{
    return (uint32_t)configTICK_RATE_HZ;
}

uint32_t espz_freertos_cpu_count(void)
{
    return (uint32_t)portNUM_PROCESSORS;
}

uint32_t espz_freertos_task_count(void)
{
    return (uint32_t)uxTaskGetNumberOfTasks();
}

bool espz_freertos_idle_runtime_counter_supported(void)
{
#if (!CONFIG_FREERTOS_SMP && CONFIG_FREERTOS_GENERATE_RUN_TIME_STATS == 1 && INCLUDE_xTaskGetIdleTaskHandle == 1)
    return true;
#else
    return false;
#endif
}

uint64_t espz_freertos_idle_runtime_counter_for_core(uint32_t core_id)
{
#if (!CONFIG_FREERTOS_SMP && CONFIG_FREERTOS_GENERATE_RUN_TIME_STATS == 1 && INCLUDE_xTaskGetIdleTaskHandle == 1)
    if (core_id >= (uint32_t)portNUM_PROCESSORS) {
        return 0;
    }
    return (uint64_t)ulTaskGetIdleRunTimeCounterForCore((BaseType_t)core_id);
#else
    (void)core_id;
    return 0;
#endif
}

TaskHandle_t espz_freertos_current_task_handle(void)
{
    return xTaskGetCurrentTaskHandle();
}

const char *espz_freertos_current_task_name(void)
{
    return pcTaskGetName(NULL);
}

uint32_t espz_freertos_task_runtime_snapshot(espz_task_runtime_entry_t *entries, uint32_t max_entries)
{
#if (CONFIG_FREERTOS_USE_TRACE_FACILITY == 1 && CONFIG_FREERTOS_GENERATE_RUN_TIME_STATS == 1)
    if (entries == NULL || max_entries == 0) {
        return 0;
    }

    UBaseType_t task_capacity = uxTaskGetNumberOfTasks();
    if (task_capacity == 0) {
        return 0;
    }

    TaskStatus_t *tasks = pvPortMalloc(task_capacity * sizeof(TaskStatus_t));
    if (tasks == NULL) {
        return 0;
    }

    configRUN_TIME_COUNTER_TYPE total_runtime = 0;
    const UBaseType_t count = uxTaskGetSystemState(tasks, task_capacity, &total_runtime);
    const UBaseType_t copied = count > (UBaseType_t)max_entries ? (UBaseType_t)max_entries : count;
    for (UBaseType_t i = 0; i < copied; ++i) {
        memset(entries[i].name, 0, sizeof(entries[i].name));
        if (tasks[i].pcTaskName != NULL) {
            strncpy(entries[i].name, tasks[i].pcTaskName, sizeof(entries[i].name) - 1);
        }
        entries[i].runtime = (uint64_t)tasks[i].ulRunTimeCounter;
    }
    vPortFree(tasks);
    return (uint32_t)copied;
#else
    (void)entries;
    (void)max_entries;
    return 0;
#endif
}
