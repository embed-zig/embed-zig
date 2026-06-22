# colorbar User Story

## 代码目录结构

```text
apps/zux/colorbar/
|-- build.zig                  # 注册 zux_colorbar module
|-- README.zh.md               # user story 文档
`-- src/
    |-- app.zig                # 组装 spec、ZuxApp、初始状态、hooks、runtime
    |-- consts.zig             # 定义颜色顺序和 RGB 常量
    |-- reducers.zig           # 聚合 reducers
    |-- renders.zig            # 聚合 renders
    |-- runtime.zig            # 聚合 runtime
    |-- reducers/
    |   `-- scene.zig          # boot click 后切换 scene.current
    |-- renders/
    |   `-- scene.zig          # scene 变化后请求 UI 重绘
    |-- runtime/
    |   |-- ui.zig             # 选择 LVGL UI runtime
    |   `-- ui/
    |       |-- Lvgl.zig       # LVGL 线程和刷新入口
    |       `-- Screen.zig     # 绘制纯色或 7 色分屏
    `-- spec/
        |-- component.json     # boot/display 组件定义
        |-- hooks.json         # reducer/render hook 定义
        |-- state.json         # scene state 定义
        `-- user_stories/      # 具体 user story JSON
```

## 基准用户故事

- 在应用刚启动的情况下，`scene` 为 `split_7_colors`，屏幕显示红、橙、黄、绿、青、蓝、紫 7 色分屏。
- 在屏幕当前显示 7 色分屏的情况下，用户按一下 `boot`，`scene` 切换为 `red`，屏幕显示纯红色。
- 在屏幕当前显示纯红色的情况下，用户按一下 `boot`，`scene` 切换为 `orange`，屏幕显示纯橙色。
- 在屏幕当前显示纯橙色的情况下，用户按一下 `boot`，`scene` 切换为 `yellow`，屏幕显示纯黄色。
- 在屏幕当前显示纯黄色的情况下，用户按一下 `boot`，`scene` 切换为 `green`，屏幕显示纯绿色。
- 在屏幕当前显示纯绿色的情况下，用户按一下 `boot`，`scene` 切换为 `cyan`，屏幕显示纯青色。
- 在屏幕当前显示纯青色的情况下，用户按一下 `boot`，`scene` 切换为 `blue`，屏幕显示纯蓝色。
- 在屏幕当前显示纯蓝色的情况下，用户按一下 `boot`，`scene` 切换为 `violet`，屏幕显示纯紫色。
- 在屏幕当前显示纯紫色的情况下，用户按一下 `boot`，`scene` 循环切换回 `split_7_colors`，屏幕显示 7 色分屏。
- 在 `scene` 变化的情况下，render hook 会重新渲染 `Display` 组件；在 `scene` 没有变化的情况下，屏幕保持当前场景不变。

## 覆盖用户故事

- `boot_shows_split_7_colors`：正向：应用启动时 `scene` 为 `split_7_colors`，并触发 `Display` render 显示 7 色分屏。
- `split_click_targets_red`：正向：`scene` 为 `split_7_colors` 时，`boot` click 将 `scene` 切换为 `red`，并触发 `Display` render。
- `red_click_targets_orange`：正向：`scene` 为 `red` 时，`boot` click 将 `scene` 切换为 `orange`，并触发 `Display` render。
- `orange_click_targets_yellow`：正向：`scene` 为 `orange` 时，`boot` click 将 `scene` 切换为 `yellow`，并触发 `Display` render。
- `yellow_click_targets_green`：正向：`scene` 为 `yellow` 时，`boot` click 将 `scene` 切换为 `green`，并触发 `Display` render。
- `green_click_targets_cyan`：正向：`scene` 为 `green` 时，`boot` click 将 `scene` 切换为 `cyan`，并触发 `Display` render。
- `cyan_click_targets_blue`：正向：`scene` 为 `cyan` 时，`boot` click 将 `scene` 切换为 `blue`，并触发 `Display` render。
- `blue_click_targets_violet`：正向：`scene` 为 `blue` 时，`boot` click 将 `scene` 切换为 `violet`，并触发 `Display` render。
- `violet_click_wraps_split_7_colors`：正向：`scene` 为 `violet` 时，`boot` click 将 `scene` 循环切换回 `split_7_colors`，并触发 `Display` render。
- `idle_keeps_current_scene`：负向：在任意当前 `scene` 下，如果用户没有按 `boot`，`scene` 不会切换到下一个场景，也不会触发新的 `Display` render。
- `single_click_advances_once`：负向：一次 `boot` click 只推进一个场景，不会跳过中间颜色。
- `rapid_two_clicks_advance_two_scenes`：正向：用户连续按两下 `boot`，`scene` 按固定顺序推进两次。
