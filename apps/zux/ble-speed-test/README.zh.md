# ble-speed-test User Story

## Transport

- 默认 transport 为 `raw-gatt`，client 通过 GATT write without response 发送测速包，server 通过 notification 发送测速包。
- 可通过构建参数 `-Dble_speed_transport=kcp-stream` 启用 KCP stream transport。该模式仍使用同一组 BLE service/characteristic，但先在 GATT packet stream 上建立 KCP session，再通过 stream 发送测速包。
- `kcp-stream` 需要协商后的 ATT payload 能承载 KCP segment；默认 ATT MTU 23 不满足要求，运行时会拒绝低 MTU 配置，避免生成超过 GATT payload 的 KCP segment。

## Server

### 基准用户故事

- 在应用以 `server` 角色启动的情况下，BLE 链路状态进入广播中，`Display` 组件通过 LVGL 显示当前角色、广播状态、连接状态和初始速度。
- 在 server 被 client 连接后，`ble_link.connected` 变为 true，链路阶段进入可传输状态，屏幕从等待连接更新为已连接。
- 在 server 收到 MTU 协商结果后，应用根据 ATT MTU 计算 `ble_link.payload_len`，后续通知或写入数据包不超过该 payload 长度。
- 在速度测试开始后，server 周期性产生 BLE 传输数据 custom event，reducer 根据事件更新 `tx_stats.running`、发送序号、发送字节数、发送包数、`tx_bps` 和 `tx_pps`。
- 在 server 收到 client 写入的数据后，server 产生 BLE 接收 custom event，reducer 根据事件更新接收字节数、接收包数、期望序号、丢包数、乱序包数、重复包数、`rx_bps` 和 `rx_pps`。
- 在 `tx_stats.tx_bps` 或 `tx_stats.rx_bps` 变化后，server 的 app render hook 根据 state 变化触发 LVGL 重绘，`Display` 组件显示最新 TX/RX 速度和包速率。
- 在 BLE 传输持续进行时，server 屏幕按统计窗口刷新速度，累计字节数和累计包数持续增加，连接状态保持已连接。
- 在 client 断开连接后，server 将 `ble_link.connected` 与 `tx_stats.running` 置为 false，链路阶段回到广播状态，屏幕显示断开状态并保留最后一次统计值或清晰地显示当前速度为 0。
- 在 server 侧 BLE 操作失败时，`ble_link.phase` 进入 failed，`ble_link.last_error_code` 记录错误码，屏幕显示失败状态和错误码，便于定位链路或传输问题。

### 覆盖用户故事

- `server_starts_advertising`：正向：以 `server` 角色启动时，`ble_link.role` 为 `server`，`ble_link.phase` 为 `advertising`，并触发 `Display` render 显示广播中。
- `server_initial_stats_are_zero`：正向：server 刚启动时，`tx_stats.running` 为 false，TX/RX 累计字节、累计包数、速度和包速率都为 0。
- `server_display_component_is_present`：正向：server spec 包含 `Display` 组件，运行时初始化时能够通过 LVGL adapter 绑定并绘制到该组件。
- `server_connected_enters_running_phase`：正向：server 收到连接事件后，`ble_link.connected` 变为 true，`ble_link.phase` 进入 `running` 或后续可传输阶段，并触发屏幕更新为已连接。
- `server_mtu_exchange_updates_payload_len`：正向：server 收到 MTU 协商结果后，`ble_link.att_mtu` 更新为协商值，`ble_link.payload_len` 更新为 `att_mtu - 3`。
- `server_payload_len_never_exceeds_protocol_max`：负向：即使协商 MTU 大于目标 MTU，server 的 `ble_link.payload_len` 也不会超过协议允许的最大 payload 长度。
- `server_start_transfer_sets_running`：正向：server 速度测试开始事件进入 reducer 后，`tx_stats.running` 变为 true，统计窗口保持为配置值。
- `server_tx_packet_event_advances_tx_stats`：正向：server 产生 BLE 传输数据 custom event 后，reducer 增加 `tx_stats.tx_seq`、`tx_bytes_total`、`tx_packets_total`，并更新 `tx_bps` 与 `tx_pps`。
- `server_tx_packet_event_does_not_advance_rx_stats`：负向：server BLE 传输数据 custom event 只更新 TX 统计，不改变 RX 累计字节、累计包数和接收序号。
- `server_rx_packet_event_advances_rx_stats`：正向：server 产生 BLE 接收 custom event 后，reducer 增加 `rx_bytes_total`、`rx_packets_total`，推进 `rx_expected_seq`，并更新 `rx_bps` 与 `rx_pps`。
- `server_rx_in_order_packet_keeps_error_counters`：负向：server 收到按序数据包时，`rx_lost_packets`、`rx_reordered_packets` 和 `rx_duplicate_packets` 不增加。
- `server_rx_gap_counts_lost_packets`：正向：server 收到序号跳跃的数据包时，reducer 按缺口增加 `rx_lost_packets`，并推进 `rx_expected_seq`。
- `server_rx_old_packet_counts_reordered_or_duplicate`：正向：server 收到低于期望序号的数据包时，reducer 将其计入乱序或重复包统计，不回退 `rx_expected_seq`。
- `server_stats_window_recomputes_rates`：正向：server 统计窗口到期后，reducer 基于窗口内 TX/RX 字节数和包数重新计算 `tx_bps`、`rx_bps`、`tx_pps`、`rx_pps`。
- `server_stats_change_triggers_display_render`：正向：server 的 `tx_stats.tx_bps`、`tx_stats.rx_bps`、`tx_pps` 或 `rx_pps` 变化时，app render hook 触发 LVGL 重绘并显示最新速度。
- `server_link_change_triggers_display_render`：正向：server 的 `ble_link.phase`、`connected`、`att_mtu` 或 `payload_len` 变化时，app render hook 触发 LVGL 重绘并显示最新链路状态。
- `server_disconnect_stops_transfer`：正向：server 收到断开事件后，`ble_link.connected` 变为 false，`tx_stats.running` 变为 false，屏幕显示断开状态。
- `server_disconnect_returns_to_advertising`：正向：server 断开连接后回到 `advertising`，等待下一次 client 连接。
- `server_ble_error_records_error_code`：正向：server 侧 BLE 操作失败事件进入 reducer 后，`ble_link.phase` 变为 `failed`，`ble_link.last_error_code` 写入错误码，并触发屏幕显示错误。
- `server_failed_state_does_not_keep_running`：负向：server 进入 BLE 失败状态后，`tx_stats.running` 不会继续保持 true，速度显示不会继续按传输中状态刷新。

## Client

### 基准用户故事

- 在应用以 `client` 角色启动的情况下，BLE 链路状态进入扫描中，`Display` 组件通过 LVGL 显示当前角色、扫描状态、连接状态和初始速度。
- 在 client 发现目标 server 后，client 进入连接流程，屏幕从扫描中更新为连接中。
- 在 client 连接 server 成功后，`ble_link.connected` 变为 true，client 完成服务发现、订阅通知和 MTU 协商，`ble_link.subscribed` 变为 true，屏幕显示连接已就绪。
- 在 MTU 协商完成后，client 根据 ATT MTU 计算 `ble_link.payload_len`，后续写入或通知数据包不超过该 payload 长度。
- 在速度测试开始后，client 周期性产生 BLE 传输数据 custom event，reducer 根据事件更新 `tx_stats.running`、发送序号、发送字节数、发送包数、`tx_bps` 和 `tx_pps`。
- 在 client 收到 server 通知数据后，client 产生 BLE 接收 custom event，reducer 根据事件更新接收字节数、接收包数、期望序号、丢包数、乱序包数、重复包数、`rx_bps` 和 `rx_pps`。
- 在 `tx_stats.tx_bps` 或 `tx_stats.rx_bps` 变化后，client 的 app render hook 根据 state 变化触发 LVGL 重绘，`Display` 组件显示最新 TX/RX 速度和包速率。
- 在 BLE 传输持续进行时，client 屏幕按统计窗口刷新速度，累计字节数和累计包数持续增加，连接状态保持已连接。
- 在连接断开后，client 将 `ble_link.connected`、`ble_link.subscribed` 与 `tx_stats.running` 置为 false，链路阶段回到扫描状态，屏幕显示断开状态并保留最后一次统计值或清晰地显示当前速度为 0。
- 在 client 侧 BLE 操作失败时，`ble_link.phase` 进入 failed，`ble_link.last_error_code` 记录错误码，屏幕显示失败状态和错误码，便于定位链路或传输问题。

### 覆盖用户故事

- `client_starts_scanning`：正向：以 `client` 角色启动时，`ble_link.role` 为 `client`，`ble_link.phase` 为 `scanning`，并触发 `Display` render 显示扫描中。
- `client_initial_stats_are_zero`：正向：client 刚启动时，`tx_stats.running` 为 false，TX/RX 累计字节、累计包数、速度和包速率都为 0。
- `client_display_component_is_present`：正向：client spec 包含 `Display` 组件，运行时初始化时能够通过 LVGL adapter 绑定并绘制到该组件。
- `client_scan_result_enters_connecting`：正向：client 发现目标 server 后，`ble_link.phase` 从 `scanning` 进入 `connecting`，并触发屏幕显示连接中。
- `client_connects_after_scan_result`：正向：client 发现目标 server 后进入连接流程，连接成功后 `ble_link.connected` 变为 true，屏幕显示已连接。
- `client_discovery_subscribes_notifications`：正向：client 连接后完成服务发现和通知订阅，`ble_link.subscribed` 变为 true，屏幕显示订阅已就绪。
- `client_mtu_exchange_updates_payload_len`：正向：client MTU 协商成功后，`ble_link.att_mtu` 更新为协商值，`ble_link.payload_len` 更新为 `att_mtu - 3`。
- `client_payload_len_never_exceeds_protocol_max`：负向：即使协商 MTU 大于目标 MTU，client 的 `ble_link.payload_len` 也不会超过协议允许的最大 payload 长度。
- `client_start_transfer_sets_running`：正向：client 速度测试开始事件进入 reducer 后，`tx_stats.running` 变为 true，统计窗口保持为配置值。
- `client_tx_packet_event_advances_tx_stats`：正向：client 产生 BLE 传输数据 custom event 后，reducer 增加 `tx_stats.tx_seq`、`tx_bytes_total`、`tx_packets_total`，并更新 `tx_bps` 与 `tx_pps`。
- `client_tx_packet_event_does_not_advance_rx_stats`：负向：client BLE 传输数据 custom event 只更新 TX 统计，不改变 RX 累计字节、累计包数和接收序号。
- `client_rx_packet_event_advances_rx_stats`：正向：client 产生 BLE 接收 custom event 后，reducer 增加 `rx_bytes_total`、`rx_packets_total`，推进 `rx_expected_seq`，并更新 `rx_bps` 与 `rx_pps`。
- `client_rx_in_order_packet_keeps_error_counters`：负向：client 收到按序数据包时，`rx_lost_packets`、`rx_reordered_packets` 和 `rx_duplicate_packets` 不增加。
- `client_rx_gap_counts_lost_packets`：正向：client 收到序号跳跃的数据包时，reducer 按缺口增加 `rx_lost_packets`，并推进 `rx_expected_seq`。
- `client_rx_old_packet_counts_reordered_or_duplicate`：正向：client 收到低于期望序号的数据包时，reducer 将其计入乱序或重复包统计，不回退 `rx_expected_seq`。
- `client_stats_window_recomputes_rates`：正向：client 统计窗口到期后，reducer 基于窗口内 TX/RX 字节数和包数重新计算 `tx_bps`、`rx_bps`、`tx_pps`、`rx_pps`。
- `client_stats_change_triggers_display_render`：正向：client 的 `tx_stats.tx_bps`、`tx_stats.rx_bps`、`tx_pps` 或 `rx_pps` 变化时，app render hook 触发 LVGL 重绘并显示最新速度。
- `client_link_change_triggers_display_render`：正向：client 的 `ble_link.phase`、`connected`、`subscribed`、`att_mtu` 或 `payload_len` 变化时，app render hook 触发 LVGL 重绘并显示最新链路状态。
- `client_disconnect_stops_transfer`：正向：client 收到断开事件后，`ble_link.connected` 与 `ble_link.subscribed` 变为 false，`tx_stats.running` 变为 false，屏幕显示断开状态。
- `client_disconnect_returns_to_scanning`：正向：client 断开连接后回到 `scanning`，重新寻找 server。
- `client_ble_error_records_error_code`：正向：client 侧 BLE 操作失败事件进入 reducer 后，`ble_link.phase` 变为 `failed`，`ble_link.last_error_code` 写入错误码，并触发屏幕显示错误。
- `client_failed_state_does_not_keep_running`：负向：client 进入 BLE 失败状态后，`tx_stats.running` 不会继续保持 true，速度显示不会继续按传输中状态刷新。
