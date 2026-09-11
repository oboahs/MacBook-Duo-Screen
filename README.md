# MacBook Duo Screen

MacBook Duo Screen 是一个针对 **MacBookPro16,1（MacBook Pro 16-inch, 2019 / Intel）** 实机开发的转轴视觉实验。它读取 MacBook 的 **Lid Angle Sensor（LAS）**，实时捕获内置屏幕，再根据物理屏幕开合角度对整块桌面做反向透视补偿。

目标不是改变窗口大小，而是让屏幕在开合时，桌面内容在观察者眼中尽量像“固定在空间里”：物理面板发生旋转，软件画面围绕底部转轴做相反方向的视觉补偿。

## V2：Perspective Lock

这一版已经移除 V1 的“双窗口布局”方向，改为和 `duo-fold` / `MacDuo` 相同的视觉思路：

- **LAS → 屏幕角度**：继续使用已经在 `MacBookPro16,1` 上验证成功的 Intel HID 读取方式。
- **ScreenCaptureKit → 实时桌面**：抓取内置屏幕，并显式排除本程序自身，避免递归捕获。
- **Metal → 全屏反向透视**：用底部中央转轴作为视觉锚点。屏幕向下合时，桌面从转轴处向外扩张，上方内容扩张更强，以抵消物理屏幕的透视缩短。
- **透明交互逻辑**：覆盖层不拦截鼠标，下面的真实桌面仍然可以操作。
- **Intel 优化**：默认只捕获 30 fps，并把超高 Retina 输入限制在最大约 2560 px 宽；Metal 显示仍可 60 Hz，降低 2019 Intel MacBook Pro 的 GPU / 功耗压力。

核心视觉模型参考了开源项目 [DhananjayBhosale/MacDuo](https://github.com/DhananjayBhosale/MacDuo) 的 Duo effect。MacDuo 的关键思路是：**物理 MacBook 屏幕本身已经制造了真实的透视梯形，因此软件不需要再模拟一个 3D 笔记本，而是对桌面做围绕底部铰链的反向扩张。** 本项目保留这个思路，并用已经验证可工作的 Intel LAS 层替换其 Apple-silicon-only 的发布假设。

## 使用方法

1. Clone / 更新仓库。
2. Finder 中双击 `Run.command`。
3. 菜单栏会显示实时 LAS 角度，例如 `113°`。
4. 点击角度，选择 **“启用视觉锁定”**。
5. 第一次启用时允许 macOS 的 **“屏幕录制”**权限；如系统要求重新打开应用，关闭后重新双击 `Run.command`。
6. 启用成功时，程序会把**当前屏幕角度自动设为视觉基准**。
7. 从这个角度慢慢向下合屏幕，桌面内容会开始反向扩张；重新打开回基准角度时，覆盖层自动退出，恢复直接显示真实桌面。

> V2 不再需要“辅助功能”权限，因为它不会修改或移动其他应用窗口。

## 菜单

- **启用/关闭视觉锁定**：开始或停止屏幕捕获与视觉补偿。
- **将当前角度设为视觉基准**：在你当前最舒服的正常屏幕角度校准为 0% 补偿。
- **补偿强度**：70% / 85% / 100% / 115%。默认 100%。如果看起来画面跟不上物理屏幕，可提高；如果补偿过头，可降低。
- **透视补偿**：柔和 / 标准 / 强。控制屏幕上部相对底部的非线性扩张幅度。
- **运动柔化**：降低运动时的锐利抖动。Intel 版使用轻量的五采样 shader，不使用昂贵的多级模糊金字塔。
- **打开屏幕录制权限设置**：首次授权或权限异常时使用。
- **重新连接转轴传感器**：LAS 暂时失联时重新探测。

## 双击启动

`Run.command` 会在本项目目录生成：

```text
.build/MacBook Duo Screen.app
```

源码变化后会自动重新编译。V2 使用的系统框架包括：

```text
AppKit
IOKit
ScreenCaptureKit
CoreMedia / CoreVideo
Metal / MetalKit
```

没有 Python、Homebrew、CMake 或第三方运行时依赖。

## Intel 兼容策略

上游 MacDuo README 将正式发行版限定为 Apple Silicon，但其主要技术栈本身是原生 Swift + ScreenCaptureKit + Metal，并没有要求 ARM 指令集才能实现 Duo 效果。本项目没有直接使用其 Apple Silicon 发布二进制，而是：

1. 本机通过 `xcrun swiftc` 直接编译 **x86_64** 可执行文件；
2. LAS 使用已在 `MacBookPro16,1` 实机验证的 `0x05AC / 0x8104 / UsagePage 0x20 / Usage 0x8A` HID 路径；
3. 针对 Intel GPU 将桌面捕获默认限制为 30 fps / 最大约 2560 px 宽；
4. 透视 shader 使用单 pass + 轻量五采样柔化，而不是完整 MacDuo 的五效果、多级模糊体系。

当前首要目标机型：

- `MacBookPro16,1` — MacBook Pro (16-inch, 2019)
- `MacBookPro16,4` — MacBook Pro (16-inch, 2019)

## 当前限制

这是第一版真正的视觉补偿实现，仍有两个明确限制：

1. **点击坐标尚未做逆映射。** 覆盖层不拦截鼠标，所以底层桌面可以继续点击，但当补偿幅度很大时，你看到的按钮位置和真实点击位置会有偏差。后续可以加入鼠标坐标反变换。
2. **视觉补偿是观察者模型，不是真实空间追踪。** LAS 只告诉我们屏幕相对底座的夹角，不知道你的眼睛在哪里。默认参数针对正常坐姿设计，因此需要通过“补偿强度 / 透视补偿”做少量主观校准。

## 命令行诊断

读取一次 LAS：

```bash
./Run.command --once
```

持续监测：

```bash
./Run.command --watch
```

## 项目结构

```text
MacBook-Duo-Screen/
├── Run.command
├── Sources/
│   ├── main.swift
│   ├── LidAngleSensor.swift
│   ├── DesktopCapture.swift
│   ├── PerspectiveRenderer.swift
│   └── AppDelegate.swift
├── THIRD_PARTY_NOTICES.md
└── README.md
```

## 致谢与许可

LAS 逆向资料参考 `samhenrigold/LidAngleSensor` 与 `ufoym/mac-angle`。视觉渲染架构和 Duo effect 的核心思路参考 MIT 许可的 `DhananjayBhosale/MacDuo`。完整第三方许可与归属信息见 `THIRD_PARTY_NOTICES.md`。
