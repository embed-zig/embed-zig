#include "components/bluetooth/bk_dm_bluetooth.h"
#include "bt_ipc_core.h"
#include "os/mem.h"
#include "os/os.h"
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#define BK_EMBED_BT_OK 0
#define BK_EMBED_BT_TIMEOUT 1
#define BK_EMBED_BT_FAIL -1

#define BK_EMBED_BT_PACKET_MAX 1024
#define BK_EMBED_BT_RX_QUEUE_LEN 16

#define HCI_COMMAND_PKT 0x01
#define HCI_ACL_DATA_PKT 0x02
#define HCI_SCO_DATA_PKT 0x03

typedef struct {
    uint16_t len;
    uint8_t data[BK_EMBED_BT_PACKET_MAX];
} bk_embed_bt_packet_t;

typedef struct __attribute__((packed)) {
    uint16_t opcode;
    uint8_t param_len;
    uint8_t param[];
} bk_embed_bt_cmd_hdr_t;

typedef struct __attribute__((packed)) {
    uint16_t hdl_flags;
    uint16_t datalen;
    uint8_t param[];
} bk_embed_bt_acl_hdr_t;

typedef struct __attribute__((packed)) {
    uint16_t conhdl_psf;
    uint8_t datalen;
    uint8_t param[];
} bk_embed_bt_sco_hdr_t;

static beken_queue_t s_rx_queue;
static bool s_initialized;

static void bk_embed_bt_notify_host_recv(uint8_t *data, uint16_t len)
{
    if (s_rx_queue == NULL || data == NULL || len > BK_EMBED_BT_PACKET_MAX) {
        return;
    }

    bk_embed_bt_packet_t packet = {0};
    packet.len = len;
    os_memcpy(packet.data, data, len);
    (void)rtos_push_to_queue(&s_rx_queue, &packet, BEKEN_NO_WAIT);
}

int bk_embed_bt_local_hci_init(void)
{
    if (s_initialized) {
        return BK_EMBED_BT_OK;
    }

    if (rtos_init_queue(&s_rx_queue, "bk_embed_bt_rx", sizeof(bk_embed_bt_packet_t), BK_EMBED_BT_RX_QUEUE_LEN) != BK_OK) {
        return BK_EMBED_BT_FAIL;
    }

    bt_ipc_register_hci_send_callback(bk_embed_bt_notify_host_recv);

    if (bk_bluetooth_init() != BK_OK) {
        bt_ipc_register_hci_send_callback(NULL);
        rtos_deinit_queue(&s_rx_queue);
        s_rx_queue = NULL;
        return BK_EMBED_BT_FAIL;
    }

    s_initialized = true;
    return BK_EMBED_BT_OK;
}

void bk_embed_bt_local_hci_deinit(void)
{
    if (!s_initialized) {
        return;
    }

    bt_ipc_register_hci_send_callback(NULL);
    (void)bk_bluetooth_deinit();

    if (s_rx_queue != NULL) {
        rtos_deinit_queue(&s_rx_queue);
        s_rx_queue = NULL;
    }

    s_initialized = false;
}

int bk_embed_bt_local_hci_send(const uint8_t *data, size_t len, uint32_t timeout_ms)
{
    (void)timeout_ms;

    if (!s_initialized || data == NULL || len < 1 || len > UINT16_MAX) {
        return BK_EMBED_BT_FAIL;
    }

    const uint8_t type = data[0];
    const uint8_t *payload = data + 1;
    const uint16_t payload_len = (uint16_t)(len - 1);

    switch (type) {
    case HCI_COMMAND_PKT: {
        if (payload_len < sizeof(bk_embed_bt_cmd_hdr_t)) {
            return BK_EMBED_BT_FAIL;
        }
        const bk_embed_bt_cmd_hdr_t *cmd = (const bk_embed_bt_cmd_hdr_t *)payload;
        if ((uint16_t)(sizeof(bk_embed_bt_cmd_hdr_t) + cmd->param_len) > payload_len) {
            return BK_EMBED_BT_FAIL;
        }
        bt_ipc_hci_send_cmd(cmd->opcode, (uint8_t *)cmd->param, cmd->param_len);
        return BK_EMBED_BT_OK;
    }
    case HCI_ACL_DATA_PKT: {
        if (payload_len < sizeof(bk_embed_bt_acl_hdr_t)) {
            return BK_EMBED_BT_FAIL;
        }
        const bk_embed_bt_acl_hdr_t *acl = (const bk_embed_bt_acl_hdr_t *)payload;
        if ((uint16_t)(sizeof(bk_embed_bt_acl_hdr_t) + acl->datalen) > payload_len) {
            return BK_EMBED_BT_FAIL;
        }
        bt_ipc_hci_send_acl_data(acl->hdl_flags, (uint8_t *)acl->param, acl->datalen);
        return BK_EMBED_BT_OK;
    }
    case HCI_SCO_DATA_PKT: {
        if (payload_len < sizeof(bk_embed_bt_sco_hdr_t)) {
            return BK_EMBED_BT_FAIL;
        }
        const bk_embed_bt_sco_hdr_t *sco = (const bk_embed_bt_sco_hdr_t *)payload;
        if ((uint16_t)(sizeof(bk_embed_bt_sco_hdr_t) + sco->datalen) > payload_len) {
            return BK_EMBED_BT_FAIL;
        }
        bt_ipc_hci_send_sco_data(sco->conhdl_psf, (uint8_t *)sco->param, sco->datalen);
        return BK_EMBED_BT_OK;
    }
    default:
        return BK_EMBED_BT_FAIL;
    }
}

int bk_embed_bt_local_hci_recv(uint8_t *out, size_t cap, size_t *out_len, uint32_t timeout_ms)
{
    if (!s_initialized || out == NULL || out_len == NULL) {
        return BK_EMBED_BT_FAIL;
    }

    bk_embed_bt_packet_t packet = {0};
    const uint32_t wait_ms = timeout_ms == UINT32_MAX ? BEKEN_WAIT_FOREVER : timeout_ms;
    if (rtos_pop_from_queue(&s_rx_queue, &packet, wait_ms) != BK_OK) {
        return BK_EMBED_BT_TIMEOUT;
    }

    if (packet.len > cap) {
        return BK_EMBED_BT_FAIL;
    }

    os_memcpy(out, packet.data, packet.len);
    *out_len = packet.len;
    return BK_EMBED_BT_OK;
}
