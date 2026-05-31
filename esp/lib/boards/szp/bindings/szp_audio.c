#include <stdbool.h>

#include "szp_board.h"

int szp_pca9557_set_pa(bool enabled);

int szp_audio_set_pa(bool enabled)
{
    return szp_pca9557_set_pa(enabled);
}
