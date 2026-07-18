import Foundation

enum AppMonotonicClock {
    static func nowSeconds() -> Double {
        ProcessInfo.processInfo.systemUptime
    }
}
