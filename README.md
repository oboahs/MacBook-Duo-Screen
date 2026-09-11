# MacBook Duo Screen

这是一个围绕 MacBook **Lid Angle Sensor（LAS，屏幕转轴角度传感器）**开发的实验项目。当前 V0.1 先完成最底层、最关键的一步：在 macOS 上直接读取转轴角度，并验证 `MacBookPro16,1`（MacBook Pro 16-inch, 2019）的 LAS 是否能够稳定输出实时数据。

## 当前功能

- 原生读取 MacBook 转轴角度，不依赖 Python、Homebrew 或 CMake。
- 针对 `MacBookPro16,1` / `MacBookPro16,4` 做已知兼容提示。
- 实时显示角度、打开/合上方向以及角速度。
- 提供 `Run.command`，Finder 中双击即可运行。
- 首次运行自动编译，后续直接复用 `.build/MacBookDuoScreen`。
- 源码修改后，下次启动会自动重新编译。

## 最简单的使用方式

1. Clone 或下载本仓库。
2. 在 Finder 中进入项目目录。
3. 双击 **`Run.command`**。
4. 如果系统提示需要安装 Apple Command Line Tools，完成安装后再次双击 `Run.command`。
5. 轻轻前后移动屏幕，终端里应该能看到实时角度变化。
6. 按 `Control + C` 停止监测。

正常输出大致如下：

```text
MacBook Duo Screen · LAS hardware test
机器型号：MacBookPro16,1
兼容性：已知支持（2019 16-inch MacBook Pro）
正在连接转轴角度传感器……
✓ 已连接 LAS，当前角度：103.0°
轻轻前后移动屏幕即可观察数据；按 Control+C 退出。

角度： 105.0°   状态：打开 ↑   速度：  20.0 °/s
```

## 如果 `Run.command` 无法双击运行

从 Git clone 得到的文件会保留可执行权限。如果是通过某些压缩/同步方式得到项目，权限可能丢失，可在终端进入项目目录后执行一次：

```bash
chmod +x Run.command
```

如果 macOS 因为下载来源阻止第一次启动，可在 Finder 中右键 `Run.command` → **打开**。

## 命令行模式

持续监测：

```bash
./Run.command
```

只读取一次：

```bash
./Run.command --once
```

显示帮助：

```bash
./Run.command --help
```

## 技术实现

程序使用 macOS `IOKit.hid` 直接探测 Apple LAS HID 设备：

- Vendor ID: `0x05AC`
- Product ID: `0x8104`
- Usage Page: `0x0020`（Sensor）
- Usage: `0x008A`（Orientation）
- Feature Report ID: `1`

读取 Feature Report 后，将第 1、2 字节按 little-endian 组合成转轴角度值。当前实现使用 Swift + IOKit，由 `Run.command` 调用 `xcrun swiftc` 编译，因此不需要额外包管理器。

## 项目阶段

当前 **V0.1 = LAS 硬件验证层**。确认 `MacBookPro16,1` 上角度、方向、角速度读取稳定后，就可以继续往 Duo Screen 的交互层扩展，例如：按角度划分上下屏状态、角度阈值触发动作、用开合速度识别手势、把屏幕转轴作为连续控制器等。

## 项目结构

```text
MacBook-Duo-Screen/
├── Run.command          # 双击启动；首次自动编译
├── Sources/
│   └── main.swift       # LAS 探测、读取与实时监测
├── .gitignore
└── THIRD_PARTY_NOTICES.md
```

## 兼容性

当前首先针对：

- `MacBookPro16,1` — MacBook Pro (16-inch, 2019)
- `MacBookPro16,4` — MacBook Pro (16-inch, 2019)

程序也会在其他 Mac 上尝试直接探测相同的 LAS HID 接口，但暂不承诺兼容。

## 致谢

LAS 的公开逆向资料和设备识别方式参考了：

- Sam Gold — `samhenrigold/LidAngleSensor`
- Ming — `ufoym/mac-angle`

详细许可信息见 `THIRD_PARTY_NOTICES.md`。
