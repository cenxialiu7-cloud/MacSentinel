#import "IOKitBridge.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>

BatteryData readBatteryData(void) {
    BatteryData data = { 0, 0, 0, 0, 0, 0, 0, 0, 0, false, false, false, false };

    io_service_t service = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceMatching("AppleSmartBattery")
    );

    if (service == IO_OBJECT_NULL) {
        // Fallback: try IOPowerSources
        CFTypeRef psInfo = IOPSCopyPowerSourcesInfo();
        if (!psInfo) return data;

        CFArrayRef psList = IOPSCopyPowerSourcesList(psInfo);
        if (!psList || CFArrayGetCount(psList) == 0) {
            if (psList) CFRelease(psList);
            CFRelease(psInfo);
            return data;
        }

        CFDictionaryRef psDesc = IOPSGetPowerSourceDescription(
            psInfo, CFArrayGetValueAtIndex(psList, 0)
        );

        if (psDesc) {
            CFNumberRef current = CFDictionaryGetValue(psDesc, CFSTR(kIOPSCurrentCapacityKey));
            CFNumberRef max     = CFDictionaryGetValue(psDesc, CFSTR(kIOPSMaxCapacityKey));
            if (current) CFNumberGetValue(current, kCFNumberIntType, &data.currentCapacity);
            if (max)     CFNumberGetValue(max, kCFNumberIntType, &data.maxCapacity);

            CFStringRef state = CFDictionaryGetValue(psDesc, CFSTR(kIOPSPowerSourceStateKey));
            if (state) {
                data.isPluggedIn = CFStringCompare(state, CFSTR(kIOPSACPowerValue), 0) == kCFCompareEqualTo;
            }
            data.isAvailable = true;
        }

        CFRelease(psList);
        CFRelease(psInfo);
        return data;
    }

    // Full read from AppleSmartBattery
    CFMutableDictionaryRef props = NULL;
    if (IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) != kIOReturnSuccess) {
        IOObjectRelease(service);
        return data;
    }

    data.isAvailable = true;

    // Helper lambda-like macro
    #define GET_INT(key, field) { \
        CFNumberRef n = CFDictionaryGetValue(props, CFSTR(key)); \
        if (n) CFNumberGetValue(n, kCFNumberIntType, &data.field); \
    }
    #define GET_BOOL(key, field) { \
        CFBooleanRef b = CFDictionaryGetValue(props, CFSTR(key)); \
        if (b) data.field = CFBooleanGetValue(b); \
    }

    GET_INT("CurrentCapacity", currentCapacity)
    GET_INT("MaxCapacity", maxCapacity)
    GET_INT("DesignCapacity", designCapacity)
    GET_INT("AppleRawMaxCapacity", rawMaxCapacity)        // mAh – correct health source on Apple Silicon
    GET_INT("NominalChargeCapacity", nominalChargeCapacity) // mAh – fallback on older macOS
    GET_INT("CycleCount", cycleCount)
    GET_INT("Temperature", temperature)

    CFNumberRef voltage = CFDictionaryGetValue(props, CFSTR("Voltage"));
    if (voltage) {
        int v = 0;
        CFNumberGetValue(voltage, kCFNumberIntType, &v);
        data.voltage = v / 1000.0;  // mV -> V
    }

    CFNumberRef amperage = CFDictionaryGetValue(props, CFSTR("InstantAmperage"));
    if (amperage) {
        int a = 0;
        CFNumberGetValue(amperage, kCFNumberIntType, &a);
        data.amperage = a / 1000.0;  // mA -> A
    }

    GET_BOOL("IsCharging", isCharging)
    GET_BOOL("ExternalConnected", isPluggedIn)
    GET_BOOL("FullyCharged", isFullyCharged)

    #undef GET_INT
    #undef GET_BOOL

    CFRelease(props);
    IOObjectRelease(service);
    return data;
}

DiskIOData readDiskIOData(void) {
    DiskIOData data = { 0, 0, false };

    io_iterator_t driveList;
    kern_return_t err = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching("IOBlockStorageDriver"),
        &driveList
    );
    if (err != kIOReturnSuccess) return data;

    io_registry_entry_t drive;
    while ((drive = IOIteratorNext(driveList)) != IO_OBJECT_NULL) {
        CFMutableDictionaryRef props = NULL;
        if (IORegistryEntryCreateCFProperties(drive, &props,
                                               kCFAllocatorDefault, 0) == kIOReturnSuccess) {
            CFDictionaryRef stats = CFDictionaryGetValue(props, CFSTR("Statistics"));
            if (stats) {
                CFNumberRef bytesRead    = CFDictionaryGetValue(stats, CFSTR("Bytes (Read)"));
                CFNumberRef bytesWritten = CFDictionaryGetValue(stats, CFSTR("Bytes (Write)"));
                uint64_t r = 0, w = 0;
                if (bytesRead)    CFNumberGetValue(bytesRead,    kCFNumberSInt64Type, &r);
                if (bytesWritten) CFNumberGetValue(bytesWritten, kCFNumberSInt64Type, &w);
                data.bytesRead    += r;
                data.bytesWritten += w;
                data.isAvailable   = true;
            }
            CFRelease(props);
        }
        IOObjectRelease(drive);
    }
    IOObjectRelease(driveList);
    return data;
}
