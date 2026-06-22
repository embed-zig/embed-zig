#include <stdint.h>

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

SemaphoreHandle_t espz_channel_semaphore_create_mutex(void)
{
    return xSemaphoreCreateMutex();
}

SemaphoreHandle_t espz_channel_semaphore_create_mutex_static(void *storage)
{
    return xSemaphoreCreateMutexStatic((StaticSemaphore_t *)storage);
}

SemaphoreHandle_t espz_channel_semaphore_create_binary(void)
{
    return xSemaphoreCreateBinary();
}

SemaphoreHandle_t espz_channel_semaphore_create_binary_static(void *storage)
{
    return xSemaphoreCreateBinaryStatic((StaticSemaphore_t *)storage);
}

int32_t espz_channel_semaphore_take(SemaphoreHandle_t handle, uint32_t ticks)
{
    return (int32_t)xSemaphoreTake(handle, (TickType_t)ticks);
}

int32_t espz_channel_semaphore_give(SemaphoreHandle_t handle)
{
    return (int32_t)xSemaphoreGive(handle);
}

void espz_channel_semaphore_delete(SemaphoreHandle_t handle)
{
    vSemaphoreDelete(handle);
}

QueueHandle_t espz_channel_queue_create(uint32_t length, uint32_t item_size)
{
    return xQueueCreate((UBaseType_t)length, (UBaseType_t)item_size);
}

QueueHandle_t espz_channel_queue_create_static(uint32_t length, uint32_t item_size, uint8_t *queue_storage, void *queue_control)
{
    return xQueueCreateStatic(
        (UBaseType_t)length,
        (UBaseType_t)item_size,
        queue_storage,
        (StaticQueue_t *)queue_control
    );
}

int32_t espz_channel_queue_send(QueueHandle_t q, const void *item, uint32_t ticks)
{
    return (int32_t)xQueueSend(q, item, (TickType_t)ticks);
}

int32_t espz_channel_queue_receive(QueueHandle_t q, void *buffer, uint32_t ticks)
{
    return (int32_t)xQueueReceive(q, buffer, (TickType_t)ticks);
}

uint32_t espz_channel_queue_messages_waiting(QueueHandle_t q)
{
    return (uint32_t)uxQueueMessagesWaiting(q);
}

void espz_channel_queue_delete(QueueHandle_t q)
{
    vQueueDelete(q);
}

void espz_channel_task_yield(void)
{
    taskYIELD();
}

void espz_channel_task_delay(uint32_t ticks)
{
    vTaskDelay((TickType_t)ticks);
}

uint32_t espz_channel_tick_rate_hz(void)
{
    return (uint32_t)configTICK_RATE_HZ;
}

uint32_t espz_channel_static_queue_size(void)
{
    return (uint32_t)sizeof(StaticQueue_t);
}

uint32_t espz_channel_static_queue_align(void)
{
    return (uint32_t)_Alignof(StaticQueue_t);
}

uint32_t espz_channel_static_semaphore_size(void)
{
    return (uint32_t)sizeof(StaticSemaphore_t);
}

uint32_t espz_channel_static_semaphore_align(void)
{
    return (uint32_t)_Alignof(StaticSemaphore_t);
}
