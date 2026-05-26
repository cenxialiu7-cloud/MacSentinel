#import "ThermalSensorBridge.h"
#import <Foundation/Foundation.h>
#import <IOKit/hidsystem/IOHIDEventSystemClient.h>

// MARK: - Private API declarations
//
// These symbols ARE exported from IOKit.framework on all macOS versions ≥ 10.15
// but are NOT in the public headers. Tools like Stats (MIT) and AsitopGUI use
// the same approach. Listed in IOKit.framework/IOKit binary via:
//   nm -D /System/Library/Frameworks/IOKit.framework/IOKit | grep IOHIDEventSystem

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t eventType, int32_t options, int64_t time);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef property);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

// Constants we need
#define kIOHIDEventTypeTemperature        15
#define kHIDPage_AppleVendor              0xff00
#define kHIDUsage_AppleVendor_TemperatureSensor 0x0005

// IOHIDEventField for temperature = (eventType << 16) | 0
#define kIOHIDEventFieldTemperatureLevel  ((kIOHIDEventTypeTemperature << 16) | 0)

// MARK: - Helper: classify sensor name into CPU/GPU/Battery bucket

typedef enum {
    SensorKindUnknown = 0,
    SensorKindCPU,
    SensorKindGPU,
    SensorKindBattery,
} SensorKind;

static SensorKind classifySensor(NSString *name) {
    if (name == nil) return SensorKindUnknown;
    NSString *lower = [name lowercaseString];
    // Apple Silicon sensor naming follows patterns documented in iStat Menus
    // and Stats: ANE = Apple Neural Engine, GPU0 = GPU, eCPU/pCPU = Efficient/Performance CPU
    if ([lower containsString:@"battery"] || [lower hasPrefix:@"gas gauge"]) return SensorKindBattery;
    if ([lower containsString:@"gpu"]) return SensorKindGPU;
    if ([lower containsString:@"cpu"] ||
        [lower containsString:@"ecpu"] ||
        [lower containsString:@"pcpu"] ||
        [lower containsString:@"soc"] ||
        [lower hasPrefix:@"pmu"] ||
        [lower hasPrefix:@"tp"] ||         // pre-M3 cores
        [lower hasPrefix:@"tc"]) {         // pre-M3 cores
        return SensorKindCPU;
    }
    return SensorKindUnknown;
}

// MARK: - Public API

AppleSiliconThermalData readAppleSiliconThermal(void) {
    AppleSiliconThermalData data = { -1.0, -1.0, -1.0, 0, false };

    @autoreleasepool {
        // Build matching dict for HID temperature sensors
        // { PrimaryUsagePage: 0xff00, PrimaryUsage: 0x0005 }
        NSDictionary *match = @{
            @"PrimaryUsagePage": @(kHIDPage_AppleVendor),
            @"PrimaryUsage":     @(kHIDUsage_AppleVendor_TemperatureSensor),
        };

        IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (client == NULL) return data;

        IOHIDEventSystemClientSetMatching(client, (__bridge CFDictionaryRef)match);
        CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
        if (services == NULL) {
            CFRelease(client);
            return data;
        }

        double cpuSum = 0.0; int cpuCount = 0;
        double gpuSum = 0.0; int gpuCount = 0;
        double battSum = 0.0; int battCount = 0;
        int totalFound = 0;

        CFIndex count = CFArrayGetCount(services);
        for (CFIndex i = 0; i < count; i++) {
            IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);

            // Get sensor product name
            CFStringRef nameRef = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
            NSString *name = (__bridge_transfer NSString *)nameRef;

            // Read temperature event
            IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0);
            if (event == NULL) continue;

            double temp = IOHIDEventGetFloatValue(event, kIOHIDEventFieldTemperatureLevel);
            CFRelease(event);

            // Sanity check: valid range 0–150 °C; -1 if out of range
            if (temp < 0 || temp > 150) continue;

            totalFound++;
            SensorKind kind = classifySensor(name);
            switch (kind) {
                case SensorKindCPU:     cpuSum  += temp; cpuCount++;  break;
                case SensorKindGPU:     gpuSum  += temp; gpuCount++;  break;
                case SensorKindBattery: battSum += temp; battCount++; break;
                case SensorKindUnknown: break;
            }
        }

        CFRelease(services);
        CFRelease(client);

        if (cpuCount > 0)  data.cpuTemperature     = cpuSum  / cpuCount;
        if (gpuCount > 0)  data.gpuTemperature     = gpuSum  / gpuCount;
        if (battCount > 0) data.batteryTemperature = battSum / battCount;
        data.sensorsFound = totalFound;
        data.isAvailable  = (cpuCount > 0);
    }

    return data;
}
