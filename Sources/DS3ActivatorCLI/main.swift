import Foundation
import IOKit.hid

enum AppConstants {
    enum HID {
        static let vendorID = 0x054C   // Sony
        static let productID = 0x0268  // DualShock 3
        static let deviceName = "DualShock 3"
    }
}

func log(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    print("[\(formatter.string(from: Date()))] \(message)")
}


final class DS3HIDController {
    private let hidManager: IOHIDManager

    var onConnect: ((IOHIDDevice) -> Void)?
    var onDisconnect: ((IOHIDDevice) -> Void)?

    // Mantiene abierto cada dispositivo activado + su buffer de lectura,
    // para que el DS3 no vuelva a modo "parpadeo" por falta de un lector activo.
    private var openBuffers: [ObjectIdentifier: UnsafeMutablePointer<UInt8>] = [:]
    private let bufferSize = 64

    init() throws {
        hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        log("IOHIDManager creado")

        let criteria: [String: Any] = [
            kIOHIDVendorIDKey as String: AppConstants.HID.vendorID,
            kIOHIDProductIDKey as String: AppConstants.HID.productID
        ]
        IOHIDManagerSetDeviceMatching(hidManager, criteria as CFDictionary)
        log(String(format: "Buscando VID:0x%04X PID:0x%04X", AppConstants.HID.vendorID, AppConstants.HID.productID))

        let opaqueSelf = Unmanaged.passRetained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(hidManager, { context, _, _, device in
            guard let context else { return }
            let instance = Unmanaged<DS3HIDController>.fromOpaque(context).takeUnretainedValue()
            instance.onConnect?(device)
        }, opaqueSelf)

        IOHIDManagerRegisterDeviceRemovalCallback(hidManager, { context, _, _, device in
            guard let context else { return }
            let instance = Unmanaged<DS3HIDController>.fromOpaque(context).takeUnretainedValue()
            instance.onDisconnect?(device)
        }, opaqueSelf)

        IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        let result = IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            let msg = String(format: "IOHIDManagerOpen falló (0x%08X)", result)
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result),
                           userInfo: [NSLocalizedDescriptionKey: msg])
        }
        log("IOHIDManager abierto correctamente")
    }

    deinit {
        IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        Unmanaged.passUnretained(self).release()
    }

    func getDeviceName(_ device: IOHIDDevice) -> String? {
        IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
    }

    func activateController(_ device: IOHIDDevice, named deviceName: String) {
        log("Iniciando activación de \(deviceName)…")

        DispatchQueue.global(qos: .userInitiated).async {
            let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            guard openResult == kIOReturnSuccess else {
                log(String(format: "No se pudo abrir el dispositivo (0x%08X). ¿Probaste con sudo?", openResult))
                return
            }

            // Feature report de activación
            let feature: [UInt8] = [0x42, 0x0C, 0x00, 0x00]
            let featureResult = feature.withUnsafeBufferPointer {
                IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0xF4, $0.baseAddress!, $0.count)
            }
            guard featureResult == kIOReturnSuccess else {
                log(String(format: "Feature report falló (0x%08X)", featureResult))
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
                return
            }
            log("Feature report enviado")

            Thread.sleep(forTimeInterval: 0.1)

            // Output report: enciende LED1
            var output = [UInt8](repeating: 0, count: 48)
            output[0] = 0x01
            output[9] = 0x02

            let outputResult = output.withUnsafeBufferPointer {
                IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x01, $0.baseAddress!, $0.count)
            }

            if outputResult == kIOReturnSuccess {
                log("\(deviceName) activado y listo")
            } else {
                log(String(format: "LED no se pudo encender (0x%08X)", outputResult))
            }

            DispatchQueue.main.async {
                self.keepAlive(device)
            }
        }
    }

    private func keepAlive(_ device: IOHIDDevice) {
        let key = ObjectIdentifier(device)
        guard openBuffers[key] == nil else { return } // ya está escuchando

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        openBuffers[key] = buffer

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, buffer, bufferSize,
            { _, _, _, _, _, _, _ in},
            context
        )
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        log("Escuchando reportes de \(getDeviceName(device) ?? "el mando") para mantenerlo activo")
    }

    func releaseDevice(_ device: IOHIDDevice) {
        let key = ObjectIdentifier(device)
        if let buffer = openBuffers.removeValue(forKey: key) {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            buffer.deallocate()
        }
    }
}

// MARK: - Punto de entrada

log("DS3 Activator (CLI) iniciado. Esperando conexión del mando… (Ctrl+C para salir)")

var controller: DS3HIDController?

do {
    controller = try DS3HIDController()
} catch {
    log("Error al iniciar HID: \(error.localizedDescription)")
    exit(1)
}

controller?.onConnect = { device in
    let name = controller?.getDeviceName(device) ?? AppConstants.HID.deviceName
    log("\(name) conectado")
    controller?.activateController(device, named: name)
}

controller?.onDisconnect = { device in
    let name = controller?.getDeviceName(device) ?? AppConstants.HID.deviceName
    log("\(name) desconectado")
    controller?.releaseDevice(device)
}

// Manejo limpio de Ctrl+C
signal(SIGINT) { _ in
    log("Saliendo…")
    exit(0)
}

// Mantiene vivo el proceso escuchando eventos HID
RunLoop.main.run()