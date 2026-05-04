#include <stdint.h>
#include <time.h>

#include "esp_timer.h"

int64_t espz_grt_time_uptime_us(void)
{
    return esp_timer_get_time();
}

int espz_newlib_clock_gettime_monotonic(struct timespec *ts)
{
    return clock_gettime(CLOCK_MONOTONIC, ts);
}

int espz_newlib_clock_gettime_realtime(struct timespec *ts)
{
    return clock_gettime(CLOCK_REALTIME, ts);
}
