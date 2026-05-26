#ifndef IOKitBridge_h
#define IOKitBridge_h

#include <stdint.h>
#include <stdbool.h>

// Battery information from IOKit
typedef struct {
    int     currentCapacity;       // % (0–100) on macOS 11+
    int     maxCapacity;           // % (always 100 on Apple Silicon when CurrentCapacity is %)
    int     designCapacity;        // mAh (battery's original design capacity)
    int     rawMaxCapacity;        // mAh (actual current full charge capacity – use for health)
    int     nominalChargeCapacity; // mAh (alternative key on some macOS versions)
    int     cycleCount;            // Charge cycles
    int     temperature;           // Tenths of °C (divide by 10)
    double  voltage;               // V
    double  amperage;              // A (negative = discharging)
    bool    isCharging;
    bool    isPluggedIn;
    bool    isFullyCharged;
    bool    isAvailable;
} BatteryData;

// Read battery info via IOKit
BatteryData readBatteryData(void);

// Disk I/O stats via IOKit
typedef struct {
    uint64_t bytesRead;
    uint64_t bytesWritten;
    bool     isAvailable;
} DiskIOData;

DiskIOData readDiskIOData(void);

#endif /* IOKitBridge_h */

