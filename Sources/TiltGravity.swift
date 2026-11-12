import Foundation
import IOKit
import IOKit.hid
import simd

/// Reads the MacBook's built-in accelerometer through the undocumented
/// AppleSPU HID device and turns the tilt into a 2-D gravity direction for the
/// leaf simulation. The sensor reports ~800 Hz; we decimate and low-pass it.
final class TiltGravity {
    static let shared = TiltGravity()

    private(set) var enabled = false
    private(set) var gravity = SIMD2<Float>(0, 1)

    private var device: IOHIDDevice?
    private var reportBuffer: UnsafeMutablePointer<UInt8>?
    private var sampleCounter = 0
    private var smoothed = SIMD2<Float>(0, 0)
    private var reference = SIMD2<Float>(0, 0)
    private var hasReference = false

    private init() {}

    /// Check for the SPU accelerometer without opening it.
    static func sensorAvailable() -> Bool {
        guard let matching = IOServiceMatching("AppleSPUHIDDevice") else { return false }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            let page = Self.propertyInt(service, "PrimaryUsagePage")
            let usage = Self.propertyInt(service, "PrimaryUsage")
            IOObjectRelease(service)
            if page == 0xFF00 && usage == 3 { return true }
            service = IOIteratorNext(iterator)
        }
        return false
    }

    func setEnabled(_ value: Bool) {
        if value { start() } else { stop() }
    }

    func start() {
        guard !enabled else { return }
        guard openDevice() else { return }
        enabled = true
        gravity = SIMD2(0, 1)
        smoothed = .zero
        hasReference = false
        sampleCounter = 0
        NSLog("Seasons: tilt sensor started")
    }

    func stop() {
        guard enabled || device != nil else { return }
        enabled = false
        if let device {
            IOHIDDeviceUnscheduleFromRunLoop(
                device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue
            )
            IOHIDDeviceClose(device, 0)
        }
        device = nil
        reportBuffer?.deallocate()
        reportBuffer = nil
        gravity = SIMD2(0, 1)
    }

    fileprivate func handleReport(_ report: UnsafeMutablePointer<UInt8>, length: Int) {
        guard length >= 22 else { return }
        sampleCounter &+= 1
        guard sampleCounter % 4 == 0 else { return }

        func i32(_ offset: Int) -> Int32 {
            Int32(report[offset])
                | (Int32(report[offset + 1]) << 8)
                | (Int32(report[offset + 2]) << 16)
                | (Int32(report[offset + 3]) << 24)
        }
        let ax = Float(i32(6)) / 65536
        let ay = Float(i32(10)) / 65536

        smoothed.x += (ax - smoothed.x) * 0.50
        smoothed.y += (ay - smoothed.y) * 0.50

        if !hasReference {
            reference = smoothed
            hasReference = true
            return
        }

        // Screen space: x right, y down. Use the in-plane tilt as a direction
        // and blend away from the default downward vector. A minimum downward
        // component keeps the leaves from ever piling on the top edge.
        let dx = smoothed.x - reference.x
        let dy = smoothed.y - reference.y
        let mag = sqrt(dx * dx + dy * dy)
        let blend = min(1, mag / 0.12)
        let inX: Float = mag > 0.001 ? dx / mag : 0
        let inY: Float = mag > 0.001 ? -dy / mag : 1
        var gx = inX * blend
        var gy = 1 - blend + inY * blend
        var len = sqrt(gx * gx + gy * gy)
        if len > 0.001 {
            gx /= len
            gy /= len
        }
        // Never let gravity point more than ~75 degrees away from down.
        if gy < 0.25 {
            gy = 0.25
            len = sqrt(gx * gx + gy * gy)
            if len > 0.001 {
                gx /= len
                gy /= len
            }
        }
        gravity = SIMD2(gx, gy)
    }

    private func openDevice() -> Bool {
        wakeDrivers()
        guard let matching = IOServiceMatching("AppleSPUHIDDevice") else { return false }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            let page = Self.propertyInt(service, "PrimaryUsagePage")
            let usage = Self.propertyInt(service, "PrimaryUsage")
            if page == 0xFF00 && usage == 3,
               let dev = IOHIDDeviceCreate(kCFAllocatorDefault, service),
               IOHIDDeviceOpen(dev, 0) == kIOReturnSuccess {
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                buffer.initialize(repeating: 0, count: 4096)
                reportBuffer = buffer
                device = dev
                IOHIDDeviceRegisterInputReportWithTimeStampCallback(
                    dev, buffer, 4096, tiltReportCallback,
                    Unmanaged.passUnretained(self).toOpaque()
                )
                IOHIDDeviceScheduleWithRunLoop(
                    dev, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue
                )
                IOObjectRelease(service)
                return true
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return false
    }

    private func wakeDrivers() {
        guard let matching = IOServiceMatching("AppleSPUHIDDriver") else { return }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            Self.setInt(service, "SensorPropertyReportingState", 1)
            Self.setInt(service, "SensorPropertyPowerState", 1)
            Self.setInt(service, "ReportInterval", 1000)
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    private static func propertyInt(_ service: io_service_t, _ key: String) -> Int {
        guard let value = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return -1 }
        return (value as? NSNumber)?.intValue ?? -1
    }

    private static func setInt(_ service: io_service_t, _ key: String, _ value: Int32) {
        let number = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, [value])
        IORegistryEntrySetCFProperty(service, key as CFString, number)
    }
}

private func tiltReportCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex,
    timestamp: UInt64
) {
    guard let context else { return }
    let tilt = Unmanaged<TiltGravity>.fromOpaque(context).takeUnretainedValue()
    tilt.handleReport(report, length: reportLength)
}
