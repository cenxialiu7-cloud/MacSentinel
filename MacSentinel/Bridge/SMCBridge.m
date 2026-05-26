#import "SMCBridge.h"
#include <IOKit/IOKitLib.h>
#include <string.h>

// ── SMC Internal Types ──────────────────────────────────────────────────────

#define KERNEL_INDEX_SMC      2
#define SMC_CMD_READ_BYTES    5
#define SMC_CMD_READ_KEYINFO  9

typedef struct {
    char     major;
    char     minor;
    char     build;
    char     reserved[1];
    UInt16   release;
} SMCVersion;

typedef struct {
    UInt16  version;
    UInt16  length;
    UInt32  cpuPLimit;
    UInt32  gpuPLimit;
    UInt32  memPLimit;
} SMCPLimitData;

typedef struct {
    UInt32  dataSize;
    UInt32  dataType;
    char    dataAttributes;
} SMCKeyInfoData;

typedef struct {
    UInt32          key;
    SMCVersion      vers;
    SMCPLimitData   pLimitData;
    SMCKeyInfoData  keyInfo;
    char            result;
    char            status;
    char            data8;
    UInt32          data32;
    UInt8           bytes[32];
} SMCParamStruct;

// ── Helpers ──────────────────────────────────────────────────────────────────

static UInt32 _strtoul(const char *str, int size, int base) {
    UInt32 total = 0;
    for (int i = 0; i < size; i++) {
        if (base == 16) {
            total += str[i] << (size - 1 - i) * 8;
        } else {
            total += ((unsigned char)(str[i]) << (size - 1 - i) * 8);
        }
    }
    return total;
}

static kern_return_t smcCall(io_connect_t conn, int index,
                              SMCParamStruct *in, SMCParamStruct *out) {
    size_t   inStructSize  = sizeof(SMCParamStruct);
    size_t   outStructSize = sizeof(SMCParamStruct);
    return IOConnectCallStructMethod(conn, index, in, inStructSize, out, &outStructSize);
}

static kern_return_t smcReadKey(io_connect_t conn, const char *key,
                                 SMCParamStruct *out) {
    SMCParamStruct in = {};
    in.key = _strtoul(key, 4, 16);
    in.data8 = SMC_CMD_READ_KEYINFO;

    kern_return_t ret = smcCall(conn, KERNEL_INDEX_SMC, &in, out);
    if (ret != kIOReturnSuccess) return ret;

    SMCParamStruct in2 = {};
    in2.key = _strtoul(key, 4, 16);
    in2.keyInfo.dataSize = out->keyInfo.dataSize;
    in2.data8 = SMC_CMD_READ_BYTES;

    return smcCall(conn, KERNEL_INDEX_SMC, &in2, out);
}

// ── Public API ───────────────────────────────────────────────────────────────

kern_return_t smcOpen(io_connect_t *conn) {
    io_service_t service = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceMatching("AppleSMC")
    );
    if (service == IO_OBJECT_NULL) return kIOReturnNotFound;

    kern_return_t ret = IOServiceOpen(service, mach_task_self(), 0, conn);
    IOObjectRelease(service);
    return ret;
}

kern_return_t smcClose(io_connect_t conn) {
    return IOServiceClose(conn);
}

double smcReadTemperature(io_connect_t conn, const char *key) {
    SMCParamStruct out = {};
    kern_return_t ret = smcReadKey(conn, key, &out);
    if (ret != kIOReturnSuccess) return -1.0;

    // sp78 format: fixed point, 1 sign bit, 7 integer bits, 8 fractional bits
    double temp = ((out.bytes[0] * 256.0) + out.bytes[1]) / 256.0;
    if (temp < 0 || temp > 150) return -1.0;  // Sanity check
    return temp;
}

double smcReadFanSpeed(io_connect_t conn, const char *key) {
    SMCParamStruct out = {};
    kern_return_t ret = smcReadKey(conn, key, &out);
    if (ret != kIOReturnSuccess) return -1.0;

    // fpe2 format: 14 integer bits, 2 fractional bits
    double rpm = ((out.bytes[0] * 256.0) + out.bytes[1]) / 4.0;
    if (rpm < 0 || rpm > 20000) return -1.0;
    return rpm;
}

double smcReadPower(io_connect_t conn, const char *key) {
    SMCParamStruct out = {};
    kern_return_t ret = smcReadKey(conn, key, &out);
    if (ret != kIOReturnSuccess) return -1.0;

    // flt format: 32-bit float
    if (out.keyInfo.dataSize == 4) {
        float value;
        memcpy(&value, out.bytes, 4);
        if (value >= 0 && value < 1000) return (double)value;
    }
    return -1.0;
}

SMCData smcReadAll(void) {
    SMCData data = { 0, 0, 0, 0, 0, false };
    io_connect_t conn;

    if (smcOpen(&conn) != kIOReturnSuccess) return data;
    data.isAvailable = true;

    // Try multiple CPU temperature keys (M-series vs Intel naming)
    data.cpuTemperature = smcReadTemperature(conn, SMC_KEY_CPU_TEMP);
    if (data.cpuTemperature < 0)
        data.cpuTemperature = smcReadTemperature(conn, "TC0F");
    if (data.cpuTemperature < 0)
        data.cpuTemperature = smcReadTemperature(conn, "Tp01");

    data.gpuTemperature      = smcReadTemperature(conn, SMC_KEY_GPU_TEMP);
    data.batteryTemperature  = smcReadTemperature(conn, SMC_KEY_BATTERY_TEMP);
    data.fanSpeedRPM         = smcReadFanSpeed(conn, SMC_KEY_FAN_SPEED);
    data.totalPowerWatts     = smcReadPower(conn, SMC_KEY_POWER_TOTAL);

    smcClose(conn);
    return data;
}
