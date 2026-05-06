#include "szp_board.h"

int szp_i2c_init(void);
int szp_pca9557_init(void);

int szp_board_init(void)
{
    int rc = szp_i2c_init();
    if (rc != 0) return rc;

    rc = szp_pca9557_init();
    if (rc != 0) return rc;

    rc = szp_button_init();
    if (rc != 0) return rc;

    rc = szp_audio_init();
    if (rc != 0) return rc;

    return szp_display_init();
}
