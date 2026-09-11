import Foundation
import Darwin
import IOKit.hid

let mdsNoOptions = IOOptionBits(kIOHIDOptionsTypeNone)

enum LidAngleError: LocalizedError {
    case managerOpenFailed(IOReturn)
    case sensorNotFound
    case deviceOpenFailed(IOReturn)
    case readFailed(IOReturn)
    case invalidReportLength(CFIndex)

    var errorDescription: String? {
        switch self {
        case .managerOpenFailed(let code):
            return "无法打开 IOHIDManager（IOReturn: \(code)）"
        case .sensorNotFound:
            return "没有找到可读取的转轴角度传感器（Apple 0x05AC / 0x8104, UsagePage 0x20, Usage 0x8A）"
        case .deviceOpenFailed(let code):
            return "无法打开转轴角度传感器（IOReturn: \(code)）"
        case .readFailed(let code):
            return "读取转轴角度失败（IOReturn: \(code)）"
        case .invalidReportLength(let length):
            return "传感器返回的数据长度异常：\(length)"
        }
    }
}

final class LidAngleSensor {
    private let manager: IOHIDManager
    private let device: IOHIDDevice

    init() throws {
        let createdManager = IOHIDManagerCreate(kCFAllocatorDefault, mdsNoOptions)
        let openResult = IOHIDManagerOpen(createdManager, mdsNoOptions)
        guard openResult == kIOReturnSuccess else {
            throw LidAngleError.managerOpenFailed(openResult)
        }

        manager = createdManager

        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x05AC,
            kIOHIDProductIDKey as String: 0x8104,
            "UsagePage": 0x0020,
            "Usage": 0x008A,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty else {
            IOHIDManagerClose(manager, mdsNoOptions)
            throw LidAngleError.sensorNotFound
        }

        var selected: IOHIDDevice?
        var lastOpenError: IOReturn?

        for candidate in devices {
            let candidateOpenResult = IOHIDDeviceOpen(candidate, mdsNoOptions)
            guard candidateOpenResult == kIOReturnSuccess else {
                lastOpenError = candidateOpenResult
                continue
            }

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

            IOHIDDeviceClose(candidate, mdsNoOptions)
        }

        guard let selectedDevice = selected else {
            IOHIDManagerClose(manager, mdsNoOptions)
            if let code = lastOpenError {
                throw LidAngleError.deviceOpenFailed(code)
            }
            throw LidAngleError.sensorNotFound
        }

        device = selectedDevice
    }

    deinit {
        IOHIDDeviceClose(device, mdsNoOptions)
        IOHIDManagerClose(manager, mdsNoOptions)
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

        let rawValue = UInt16(report[2]) << 8 | UInt16(report[1])
        return Double(rawValue)
    }
}

struct LidMotionSample {
    let angle: Double
    let velocity: Double

    var directionText: String {
        if velocity > 2.0 { return "打开 ↑" }
        if velocity < -2.0 { return "合上 ↓" }
        return "静止 ·"
    }
}

final class LidMotionFilter {
    private var filteredAngle: Double?
    private var lastAngle: Double?
    private var lastTime: TimeInterval?
    private var filteredVelocity = 0.0

    private let angleAlpha = 0.28
    private let velocityAlpha = 0.32

    func reset() {
        filteredAngle = nil
        lastAngle = nil
        lastTime = nil
        filteredVelocity = 0
    }

    func update(rawAngle: Double, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> LidMotionSample {
        let angle: Double
        if let previous = filteredAngle {
            angle = angleAlpha * rawAngle + (1.0 - angleAlpha) * previous
        } else {
            angle = rawAngle
        }
        filteredAngle = angle

        guard let previousAngle = lastAngle, let previousTime = lastTime else {
            lastAngle = angle
            lastTime = now
            return LidMotionSample(angle: angle, velocity: 0)
        }

        let elapsed = max(now - previousTime, 0.001)
        let instantVelocity = (angle - previousAngle) / elapsed
        filteredVelocity = velocityAlpha * instantVelocity + (1.0 - velocityAlpha) * filteredVelocity

        if abs(filteredVelocity) < 0.8 {
            filteredVelocity = 0
        }

        lastAngle = angle
        lastTime = now
        return LidMotionSample(angle: angle, velocity: filteredVelocity)
    }
}

func currentMacModel() -> String {
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

func isKnownLASModel(_ model: String) -> Bool {
    let known = Set([
        "MacBookPro16,1", "MacBookPro16,4",
        "MacBookPro18,1", "MacBookPro18,2", "MacBookPro18,3", "MacBookPro18,4",
        "Mac14,5", "Mac14,6", "Mac14,9", "Mac14,10",
        "Mac15,3", "Mac15,6", "Mac15,7", "Mac15,8", "Mac15,9", "Mac15,11",
        "Mac16,1", "Mac16,5", "Mac16,6", "Mac16,7", "Mac16,8", "Mac16,9", "Mac16,10",
        "Mac14,2", "Mac14,15", "Mac16,12", "Mac16,13",
    ])
    return known.contains(model)
}
