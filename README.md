# MacBook Duo Screen

MacBook Duo Screen 是一个利用 MacBook **Lid Angle Sensor（LAS，屏幕转轴角度传感器）**驱动 macOS 窗口布局的菜单栏工具。项目最初用于验证 `MacBookPro16,1`（MacBook Pro 16-inch, 2019）的 LAS；现在 V1 已经把实时角度变成实际交互：合上或打开屏幕可以进入 Duo 双窗口布局、连续改变左右占比，并在退出 Duo 区间时恢复窗口原来的位置。

## V1 功能

- 原生 Swift + IOKit 读取 LAS，不依赖 Python、Homebrew 或 CMake。
- Finder 双击 `Run.command` 即可编译并启动 `.app` 菜单栏程序。
- 菜单栏实时显示当前屏幕角度，例如 `113°`；Duo 布局生效时显示 `D113°`。
- 30 Hz 采样，并对角度与角速度做平滑，减少转轴轻微抖动。
- **角度驱动 Duo 布局**：默认触发角度 `≤ 100°`，恢复角度 `≥ 108°`，8° 回差避免临界点反复切换。
- Duo 进入时自动选择当前最前面的两个可移动应用窗口，并铺到 MacBook 内置屏幕。
- 可让转轴角度连续控制左右窗口占比：约 `65° → 35/65`，`100° → 65/35`；比例被限制在 30%–70%，避免一侧不可用。
- 退出 Duo 时恢复这两个窗口进入 Duo 前的位置和尺寸。
- 可在菜单中手动执行一次 50/50 平铺、恢复窗口、重新连接 LAS、调整触发角度。
- 窗口移动只在你主动开启 Duo 功能后发生；默认不会擅自重排窗口。

## 使用

1. Clone 或下载本仓库。
2. Finder 打开项目目录，双击 **`Run.command`**。
3. 首次运行如果 macOS 要求 Apple Command Line Tools，安装完成后再次双击。
4. 编译结束后会启动 **MacBook Duo Screen** 菜单栏应用，菜单栏数字就是实时转轴角度。
5. 点击菜单栏角度 → 勾选 **“启用角度驱动 Duo 布局”**。
6. 第一次启用窗口控制时，macOS 会要求“辅助功能”权限。到“系统设置 → 隐私与安全性 → 辅助功能”允许 MacBook Duo Screen；允许后重新点一次 Duo 开关即可。
7. 准备两个位于最前面的普通应用窗口，将 MacBook 屏幕合到触发角度以下。两个窗口会进入 Duo 布局；继续开合屏幕会改变左右比例。
8. 把屏幕重新打开到恢复阈值以上，程序会恢复窗口原来的位置。

> `Run.command` 只负责本地编译和启动。正常运行时程序在菜单栏后台工作，不需要一直保留终端窗口。

## 菜单说明

菜单中可以看到传感器状态、当前角度、Duo 状态和阈值。主要操作包括：

- **启用角度驱动 Duo 布局**：总开关。默认关闭。
- **用转轴角度控制左右比例**：关闭后 Duo 始终保持 50/50。
- **触发角度**：可选择 80° / 90° / 100° / 110°，恢复阈值自动设为触发值 + 8°。
- **立即把最前面的两个窗口设为 50/50**：不需要等角度达到阈值，用来快速测试窗口控制。
- **恢复窗口原位置**：撤销当前由本程序管理的布局。
- **辅助功能权限**：查看/打开系统权限设置。
- **重新连接转轴传感器**：LAS 暂时异常时手动重连。

## 双击启动如何工作

`Run.command` 会在项目目录生成：

```text
.build/MacBook Duo Screen.app
```

它会检查 `Sources/*.swift` 是否比已编译程序更新；只有源码变化时才重新编译，因此日常双击启动不会每次都重新编译。生成的 App 使用固定 Bundle ID：

```text
com.oboahs.MacBookDuoScreen
```

为了避免普通 Dock 图标，`Info.plist` 使用 `LSUIElement = true`，应用只显示在菜单栏。

## 命令行诊断

除了正常双击，还保留了底层 LAS 诊断：

```bash
./Run.command --once
```

读取一次角度；或者：

```bash
./Run.command --watch
```

在终端持续显示角度、方向和角速度。按 `Control + C` 退出。

## 技术实现

LAS 通过 `IOKit.hid` 直接读取：

- Apple Vendor ID: `0x05AC`
- Product ID: `0x8104`
- Usage Page: `0x0020`（Sensor）
- Usage: `0x008A`（Orientation）
- Feature Report ID: `1`

窗口管理使用 macOS Accessibility API（AXUIElement）。程序从 CoreGraphics 的前台窗口顺序找到最前面的两个应用，再通过 Accessibility API 修改窗口的 `AXPosition` / `AXSize`。因此只有 **Duo 窗口布局**需要辅助功能权限；LAS 角度读取本身不需要这个权限。

## 当前兼容性

本项目首先针对并已经实机验证：

- `MacBookPro16,1` — MacBook Pro (16-inch, 2019)

代码也包含 `MacBookPro16,4` 以及较新的已知 LAS MacBook 型号识别，并会对未知型号直接尝试 HID 探测，但尚未逐台实机验证。

部分应用的窗口可能主动限制最小尺寸、禁止调整尺寸，或者使用非标准窗口实现，因此可能无法完全服从 Duo 布局。这属于 macOS 应用窗口本身的限制。

## 项目结构

```text
MacBook-Duo-Screen/
├── Run.command
├── Sources/
│   ├── main.swift              # CLI / 菜单栏 App 入口
│   ├── LidAngleSensor.swift    # LAS HID 读取、滤波、机型识别
│   ├── WindowManager.swift     # Accessibility 窗口捕获、布局、恢复
│   └── AppDelegate.swift       # 菜单栏、Duo 状态机、设置
├── .gitignore
└── THIRD_PARTY_NOTICES.md
```

## Duo 状态机

默认参数：

```text
Normal
  │ angle <= 100°
  ▼
Duo ─────── angle >= 108° ──────► Normal
```

触发与恢复使用不同阈值（hysteresis），因此你把屏幕停在 100° 附近时，不会因为 1–2° 的轻微传感器波动不断进入/退出 Duo。

## 致谢

LAS 的公开逆向资料和设备识别方式参考了：

- Sam Gold — `samhenrigold/LidAngleSensor`
- Ming — `ufoym/mac-angle`

详细许可信息见 `THIRD_PARTY_NOTICES.md`。
