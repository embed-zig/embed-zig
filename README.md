# embed-zig

[English](./README.en.md) | 中文

`embed-zig` 是一套面向设备应用的 Zig 基础设施。它用 `comptime` 组织 `hal` 和 `runtime` 适配层，屏蔽不同硬件平台与宿主环境的差异，并在其上提供可复用的跨平台能力。

## TOC

- [项目定位](#项目定位)
- [项目目标](#项目目标)
- [开发闭环](#开发闭环)
- [核心能力](#核心能力)
- [目录结构](#目录结构)
- [构建与测试](#构建与测试)
- [依赖接入](#依赖接入)

## 项目定位

`embed-zig` 的核心不是单一平台 SDK，而是一层基于 `comptime` 的抽象与组合机制：

- `hal`：面向 GPIO、I2C、SPI、UART、Wi-Fi、显示、音频等设备能力的硬件抽象
- `runtime`：面向线程、时间、IO、网络、文件系统、随机数等宿主能力的运行时抽象
- `pkg`：构建在 `hal` / `runtime` 之上的跨平台功能模块
- `websim`：用于开发联调、自动化测试和远程模拟的 Web 仿真能力

适配目标包括 ESP、BK 和主机环境等不同平台。

## 项目目标

这个项目希望让开发者：

1. focus on 应用本身，而不是平台差异
2. 用一套代码路径覆盖固件开发、仿真测试和多平台适配
3. 在 Agentic Coding 场景下实现快速开发和快速测试

## 开发闭环

目标工作流是：

1. 开发固件或应用逻辑
2. 在 `websim` 中完成联调与测试
3. 自动适配到多种硬件平台
4. 产出 release

## 核心能力

目前向上提供的跨平台能力包括：

- 事件总线
- App stage management
- Flux / reducer
- UI 渲染引擎
- 音频处理
- BLE、网络、异步执行等通用组件

这些能力的目标是让上层应用尽量复用，而把平台差异收敛到 `comptime` 的适配层。

## 目录结构

```text
src/
  mod.zig             # 顶层导出，模块名为 embed
  runtime/            # runtime 抽象与标准实现
  hal/                # HAL 抽象
  pkg/                # 事件、音频、BLE、网络、UI、app 等高层模块
  websim/             # Web 仿真、测试执行与远程 HAL
  third_party/        # 三方库与字体等资源
cmd/
  audio_engine/       # 主机侧音频示例
  bleterm/            # 主机侧 BLE 终端工具
test/
  firmware/           # 平台无关的固件/应用测试资产
  websim/             # 基于 websim 的测试用例
  esp/                # ESP 平台构建与适配示例
assets/
  embed-zig-icon-omgflux.jpg
```

## 构建与测试

要求：

- Zig `0.15.0` 或更高版本

仓库根目录常用命令：

```bash
zig build test
zig build test-audio
zig build test-ble
zig build test-ui
zig build test-event
```

如果只想验证单个文件，也可以直接运行：

```bash
zig test src/mod.zig
zig test src/runtime/std.zig
```

主机侧示例程序在各自目录下执行：

```bash
zig build run
```

## 依赖接入

`embed-zig` 默认导出模块名为 `embed`，但具体接入方式依赖目标平台和构建系统。

- 主机环境通常可以按普通 Zig dependency 接入
- `esp-zig` 等平台的模块导入、链接方式和构建配置会不同
- 上层应用应尽量依赖统一的 `hal` / `runtime` 接口，而不是直接写死平台实现

主机环境下，一种典型写法是：

```zig
const embed_dep = b.dependency("embed_zig", .{});
const embed_mod = embed_dep.module("embed");
```

如果需要 `portaudio`、`speexdsp`、`opus`、`ogg`、`stb_truetype` 等额外能力，也需要按目标平台分别配置依赖与链接方式。
