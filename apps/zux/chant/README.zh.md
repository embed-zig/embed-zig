# chant User Story

## 基准用户故事

- 在应用刚启动的情况下，`player.selected` 选中 `twinkle`，播放器处于播放状态，`player.loop` 为 true，`audio.gain_db` 使用默认值。
- 在播放器当前处于播放状态的情况下，用户按一下 `play_pause`，播放器暂停播放，当前曲目、循环状态、录音状态和 `audio.gain_db` 不变。
- 在播放器当前处于暂停状态的情况下，用户按一下 `play_pause`，播放器继续播放，当前曲目、循环状态、录音状态和 `audio.gain_db` 不变。
- 在播放器当前处于播放状态的情况下，播放进度会推进；用户按下 `play_pause` 暂停后播放进度停止推进；再次按下 `play_pause` 恢复后播放进度继续推进。
- 在 `player.selected` 当前选中 `twinkle` 的情况下，用户按一下 `next`，`player.selected` 切换到 `happy_birthday`，并重置播放进度。
- 在 `player.selected` 当前选中 `happy_birthday` 的情况下，用户按一下 `next`，`player.selected` 切换到 `doll_bear`，并重置播放进度。
- 在 `player.selected` 当前选中 `doll_bear` 的情况下，用户按一下 `next`，`player.selected` 循环切换回 `twinkle`，并重置播放进度。
- 在 `player.selected` 当前选中 `twinkle` 的情况下，用户按一下 `previous`，`player.selected` 循环切换到 `doll_bear`，并重置播放进度。
- 在 `player.selected` 当前选中 `doll_bear` 的情况下，用户按一下 `previous`，`player.selected` 切换到 `happy_birthday`，并重置播放进度。
- 在 `player.selected` 当前选中 `happy_birthday` 的情况下，用户按一下 `previous`，`player.selected` 切换到 `twinkle`，并重置播放进度。
- 在 `audio.gain_db` 没有达到最大值的情况下，用户按一下 `volume_up`，`audio.gain_db` 提高一级，播放器状态不变。
- 在 `audio.gain_db` 已经达到最大值的情况下，用户按一下 `volume_up`，`audio.gain_db` 保持最大值。
- 在 `audio.gain_db` 没有达到最小值的情况下，用户按一下 `volume_down`，`audio.gain_db` 降低一级，播放器状态不变。
- 在 `audio.gain_db` 已经达到最小值的情况下，用户按一下 `volume_down`，`audio.gain_db` 保持最小值。
- 在用户按住实体 `boot` button 的情况下，应用进入录音状态，播放状态、`audio.gain_db`、循环状态和选曲状态不变。
- 在用户松开实体 `boot` button 的情况下，应用停止录音，播放状态、`audio.gain_db`、循环状态和选曲状态不变。
- 在应用当前处于录音状态的情况下，`play_pause`、`next`、`previous`、`volume_up`、`volume_down` 仍然只更新各自负责的状态。
- 在播放器状态、选曲状态、播放进度、录音状态或 `audio.gain_db` 变化的情况下，render hook 会重新渲染 `Display` 组件。

## 覆盖用户故事

- `app_starts_with_track_state`：正向：初始 reducer 状态选中 `twinkle`、开始播放，开启 loop，并使用默认 `audio.gain_db`。
- `playing_play_pause_pauses`：正向：播放状态下 `play_pause` 只暂停播放，不改变 `player.selected`、`player.loop`、`player.recording` 和 `audio.gain_db`，并触发 `Display` render。
- `paused_play_pause_resumes`：正向：暂停状态下 `play_pause` 只恢复播放，不改变 `player.selected`、`player.loop`、`player.recording` 和 `audio.gain_db`，并触发 `Display` render。
- `play_pause_pause_then_resume`：正向：连续的 `play_pause` 暂停再恢复流程会在播放时推进 `playback.progress_pct`，暂停时保持不变，恢复后继续推进。
- `twinkle_next_selects_happy_birthday`：正向：`next` 将 `player.selected` 从 `twinkle` 切换到 `happy_birthday`，并触发 `Display` render。
- `happy_birthday_next_selects_doll_bear`：正向：`next` 将 `player.selected` 从 `happy_birthday` 切换到 `doll_bear`，并触发 `Display` render。
- `doll_bear_next_wraps_twinkle`：正向：`next` 将 `player.selected` 从 `doll_bear` 循环切换回 `twinkle`，并触发 `Display` render。
- `next_resets_track_progress`：正向：`next` 切换到下一首，并重置 `playback.progress_pct`。
- `twinkle_previous_wraps_doll_bear`：正向：`previous` 将 `player.selected` 从 `twinkle` 循环切换到 `doll_bear`，并触发 `Display` render。
- `doll_bear_previous_selects_happy_birthday`：正向：`previous` 将 `player.selected` 从 `doll_bear` 切换到 `happy_birthday`，并触发 `Display` render。
- `happy_birthday_previous_selects_twinkle`：正向：`previous` 将 `player.selected` 从 `happy_birthday` 切换到 `twinkle`，并触发 `Display` render。
- `previous_resets_track_progress`：正向：`previous` 切换到上一首，并重置 `playback.progress_pct`。
- `volume_up_increments`：正向：`volume_up` 只把 `audio.gain_db` 提高一级，不改变播放、录音、循环或选曲状态，并触发 `Display` render。
- `volume_up_clamps_at_max`：负向：`audio.gain_db` 已经达到最大值时，`volume_up` 保持最大值不变。
- `volume_down_decrements`：正向：`volume_down` 只把 `audio.gain_db` 降低一级，不改变播放、录音、循环或选曲状态，并触发 `Display` render。
- `volume_down_clamps_at_min`：负向：`audio.gain_db` 已经达到最小值时，`volume_down` 保持最小值不变。
- `mic_press_starts_recording`：正向：实体 `boot` 原始 press 只开启 `player.recording`，不改变播放、`audio.gain_db`、循环或选曲状态，并触发 `Display` render。
- `mic_release_stops_recording`：正向：实体 `boot` 原始 release 只关闭 `player.recording`，不改变播放、`audio.gain_db`、循环或选曲状态，并触发 `Display` render。
- `recording_play_pause_toggles_player`：正向：录音中 `play_pause` 仍然只切换播放状态，并触发 `Display` render。
- `recording_next_selects_next_track`：正向：录音中 `next` 仍然更新 `player.selected` 到下一首，并触发 `Display` render。
- `recording_previous_selects_previous_track`：正向：录音中 `previous` 仍然更新 `player.selected` 到上一首，并触发 `Display` render。
- `recording_volume_up_increments`：正向：录音中 `volume_up` 仍然提高 `audio.gain_db`，并触发 `Display` render。
- `recording_volume_down_decrements`：正向：录音中 `volume_down` 仍然降低 `audio.gain_db`，并触发 `Display` render。
- `playback_progress_event_advances_state`：正向：player runtime 周期性上报播放进度时，`playback.progress_pct` 推进，播放器其他状态保持不变，并触发 `Display` render。
- `render_player_state_change_updates_display`：正向：播放、录音或音量状态变化会触发 render，并通过 LVGL adapter 绘制到 `Display` 组件。
- `render_track_state_change_updates_display`：正向：`player.selected` 或 `playback.progress_pct` 变化会触发 render，并通过 LVGL adapter 绘制到 `Display` 组件。
