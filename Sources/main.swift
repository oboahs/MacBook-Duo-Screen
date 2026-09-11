import AppKit
import Foundation
import Darwin

func printCLIHelp() {
    print("""
    MacBook Duo Screen 1.0

    用法：
      MacBookDuoScreen           启动菜单栏应用
      MacBookDuoScreen --once    读取一次 LAS 角度
      MacBookDuoScreen --watch   在终端持续监测 LAS
      MacBookDuoScreen --help    显示帮助
    """)
}

func runOneShot() -> Int32 {
    do {
        let sensor = try LidAngleSensor()
        let angle = try sensor.readAngle()
        print("机器型号：\(currentMacModel())")
        print("LAS 角度：\(String(format: "%.1f", angle))°")
        return 0
    } catch {
        fputs("读取失败：\(error.localizedDescription)\n", stderr)
        return 1
    }
}

func runWatch() -> Int32 {
    do {
        let sensor = try LidAngleSensor()
        let filter = LidMotionFilter()
        print("MacBook Duo Screen · LAS monitor")
        print("机器型号：\(currentMacModel())")
        print("按 Control+C 退出。\n")

        while true {
            let sample = filter.update(rawAngle: try sensor.readAngle())
            let angleText = String(format: "%6.1f", sample.angle)
            let speedText = String(format: "%7.1f", abs(sample.velocity))
            print("\r角度：\(angleText)°   状态：\(sample.directionText)   速度：\(speedText) °/s      ", terminator: "")
            fflush(stdout)
            usleep(50_000)
        }
    } catch {
        fputs("\n读取失败：\(error.localizedDescription)\n", stderr)
        return 1
    }
}

let arguments = Set(CommandLine.arguments.dropFirst())

if arguments.contains("--help") || arguments.contains("-h") {
    printCLIHelp()
    exit(0)
}

if arguments.contains("--once") {
    exit(runOneShot())
}

if arguments.contains("--watch") {
    exit(runWatch())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
