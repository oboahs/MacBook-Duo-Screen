import Foundation
import Darwin
import IOKit.hid

private let noOptions = IOOptionBits(kIOHIDOptionsTypeNone)

private enum LidAngleError: LocalizedError {
    case managerOpenFailed(IOReturn)
    case sensorNotFound
    case readFailed(IOReturn)
    case invalidReportLength(CFIndex)

    var errorDescription: String? {
        switch self {
        case .managerOpenFailed(let code):
            return "无法打开 IOHIDManager（IOReturn: \(code)）"
        case .sensorNotFound:
            return "没有找到可读取的转轴角度传感器（Apple 0x05AC / 0x8104, UsagePage 0x20, Usage 0x8A）"
        case .readFailed(let code):
            return "读取转轴角度失败（IOReturn: \(code)）"
        case .invalidReportLength(let length):
            return "传感器返回的数据长度异常：\(length)"
        }
    }
}

private final class LidAngleSensor {
    private let manager: IOHIDManager
    private let device: IOHIDDevice

    init() throws {
        let createdManager = IOHIDManagerCreate(kCFAllocatorDefault, noOptions)
        let openResult = IOHIDManagerOpen(createdManager, noOptions)
        guard openResult == kIOReturnSuccess else {
            throw LidAngleError.managerOpenFailed(openResult)
        }

        manager = createdManager

        // Apple Lid Angle Sensor (LAS)
        // VID 0x05AC, PID 0x8104, Sensor usage page 0x20, Orientation usage 0x8A.
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x05AC,
            kIOHIDProductIDKey as String: 0x8104,
            "UsagePage": 0x0020,
            "Usage": 0x008A,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty else {
            IOHIDManagerClose(manager, noOptions)
            throw LidAngleError.sensorNotFound
        }

        var selected: IOHIDDevice? = nil
        for candidate in devices {
            guard IOHIDDeviceOpen(candidate, noOptions) == kIOReturnSuccess else { continue }

            var report = [UInt8](repeating: 0, count: 8)
            var reportLength = CFIndex(report.count)
            let result = IOHIDDeviceGetReport(
                candidate,
                kIOHIDReportTypeFeature,
                1,
                &report,
                &reportLength
            )

            if result == kIOReturnSuccess && reportLength >= 3 {
                selected = candidate
                break
            }

            IOHIDDeviceClose(candidate, noOptions)
        }

        guard let selectedDevice = selected else {
            IOHIDManagerClose(manager, noOptions)
            throw LidAngleError.sensorNotFound
        }
        device = selectedDevice
    }

    deinit {
        IOHIDDeviceClose(device, noOptions)
        IOHIDManagerClose(manager, noOptions)
    }

    func readAngle() throws -> Double {
        var report = [UInt8](repeating: 0, count: 8)
        var reportLength = CFIndex(report.count)

        let result = IOHIDDeviceGetReport(
            device,
            kIOHIDReportTypeFeature,
            1,
            &report,
            &reportLength
        )

        guard result == kIOReturnSuccess else {
            throw LidAngleError.readFailed(result)
        }
        guard reportLength >= 3 else {
            throw LidAngleError.invalidReportLength(reportLength)
        }

        // Report byte 0 is the report ID; bytes 1-2 contain the little-endian angle value.
        let rawValue = UInt16(report[2]) << 8 | UInt16(report[1])
        return Double(rawValue)
    }
}

private func currentMacModel() -> String {
    var size: size_t = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0 && size > 0 else {
        return "Unknown"
    }

    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
        return "Unknown"
    }
    return String(cString: buffer)
}

private func printHelp() {
    print("""
    MacBook Duo Screen - Lid Angle Sensor Test

    用法：
      MacBookDuoScreen           持续监测转轴角度
      MacBookDuoScreen --once    只读取一次
      MacBookDuoScreen --help    显示帮助
    """)
}

private func directionText(deltaPerSecond: Double) -> String {
    if deltaPerSecond > 1.0 { return "打开 ↑" }
    if deltaPerSecond < -1.0 { return "合上 ↓" }
    return "静止 ·"
}

let arguments = Set(CommandLine.arguments.dropFirst())
if arguments.contains("--help") || arguments.contains("-h") {
    printHelp()
    exit(EXIT_SUCCESS)
}

let model = currentMacModel()
print("MacBook Duo Screen · LAS hardware test")
print("机器型号：\(model)")

if model == "MacBookPro16,1" || model == "MacBookPro16,4" {
    print("兼容性：已知支持（2019 16-inch MacBook Pro）")
} else {
    print("兼容性：未针对该型号预设判断，将直接探测传感器")
}

print("正在连接转轴角度传感器……")

do {
    let sensor = try LidAngleSensor()
    let firstAngle = try sensor.readAngle()
    print("✓ 已连接 LAS，当前角度：\(String(format: "%.1f", firstAngle))°")

    if arguments.contains("--once") {
        exit(EXIT_SUCCESS)
    }

    print("轻轻前后移动屏幕即可观察数据；按 Control+C 退出。")
    print("")

    var lastAngle = firstAngle
    var lastTime = ProcessInfo.processInfo.systemUptime

    while true {
        usleep(100_000)
        let angle = try sensor.readAngle()
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = max(now - lastTime, 0.001)
        let velocity = (angle - lastAngle) / elapsed
        let angleText = String(format: "%6.1f", angle)
        let speedText = String(format: "%7.1f", abs(velocity))
        let direction = directionText(deltaPerSecond: velocity)

        print("\r角度：\(angleText)°   状态：\(direction)   速度：\(speedText) °/s      ", terminator: "")
        fflush(stdout)

        lastAngle = angle
        lastTime = now
    }
} catch {
    print("")
    print("✗ 测试失败：\(error.localizedDescription)")
    print("")
    print("如果这台机器是 MacBookPro16,1：")
    print("1. 先重新启动一次 macOS 后再试；")
    print("2. 确认没有其他 LAS 测试程序正在占用 HID 设备；")
    print("3. 把本窗口完整输出发出来，便于继续定位。")
    exit(EXIT_FAILURE)
}
