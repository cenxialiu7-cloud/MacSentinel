#ifndef SMCBridge_h
#define SMCBridge_h

#include <IOKit/IOKitLib.h>
#include <stdbool.h>

// SMC Data Types
#define SMC_KEY_CPU_TEMP    "TC0P"   // CPU Proximity Temperature
#define SMC_KEY_CPU_TEMP2   "TC0E"   // CPU Energy temp
#define SMC_KEY_GPU_TEMP    "TG0D"   // GPU Die Temperature (M-series)
#define SMC_KEY_FAN_SPEED   "F0Ac"   // Fan 0 Actual Speed (RPM)
#define SMC_KEY_POWER_TOTAL "PSTR"   // System Total Power (Watts)
#define SMC_KEY_BATTERY_TEMP "TB0T"  // Battery Temperature

typedef struct {
    double cpuTemperature;   // °C
    double gpuTemperature;   // °C
    double batteryTemperature; // °C
    double fanSpeedRPM;      // RPM
    double totalPowerWatts;  // Watts
    bool   isAvailable;
} SMCData;

// Open/close SMC connection
kern_return_t smcOpen(io_connect_t *conn);
kern_return_t smcClose(io_connect_t conn);

// Read a single SMC value
double smcReadTemperature(io_connect_t conn, const char *key);
double smcReadFanSpeed(io_connect_t conn, const char *key);
double smcReadPower(io_connect_t conn, const char *key);

// Convenience: read all SMC data at once
SMCData smcReadAll(void);

#endif /* SMCBridge_h */
