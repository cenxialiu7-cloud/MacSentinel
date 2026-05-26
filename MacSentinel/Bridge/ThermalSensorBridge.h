#ifndef ThermalSensorBridge_h
#define ThermalSensorBridge_h

#include <stdint.h>
#include <stdbool.h>

/// Apple Silicon thermal reading via IOHIDEventSystem (private API).
/// On Apple Silicon (M1/M2/M3+), the traditional SMC keys (TC0P, TC0E, Tp01)
/// don't expose CPU temperatures without root. The supported workaround used
/// by tools like Stats, AsitopGUI, MX Power Gadget is to enumerate HID
/// services with usagePage = kHIDPage_AppleVendor (0xff00) and usage =
/// kHIDUsage_AppleVendor_TemperatureSensor (0x0005), then read temperature
/// events from each matched service.
///
/// This module gracefully degrades on Intel Macs (where smcReadAll already
/// works) by returning isAvailable=false when no IOHID temp sensors are found.

typedef struct {
    double cpuTemperature;        // °C — averaged across CPU cores' sensors, -1 if N/A
    double gpuTemperature;        // °C — GPU die sensor (where exposed), -1 if N/A
    double batteryTemperature;    // °C — battery sensor on notebooks, -1 if N/A
    int    sensorsFound;          // Number of HID temperature sensors enumerated
    bool   isAvailable;           // true if at least one CPU sensor reading succeeded
} AppleSiliconThermalData;

/// Read all Apple Silicon thermal sensors. Safe to call on Intel Macs
/// (returns isAvailable=false). This is a synchronous read; on M2 the
/// enumeration completes in ~10–30 ms.
AppleSiliconThermalData readAppleSiliconThermal(void);

#endif /* ThermalSensorBridge_h */
