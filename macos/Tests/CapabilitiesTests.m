#import <Foundation/Foundation.h>
#include "capabilities.h"
#include <assert.h>

static const char *capText;
static unsigned requestedOffset;
static int mode, writes;
int captest_sleep(useconds_t delay) { (void)delay; return 0; }
IOReturn IOAVServiceWriteI2C(IOAVServiceRef service, uint32_t chip, uint32_t address, void *bytes, uint32_t length) {
    (void)service; (void)chip;
    assert(address == 0x51 && length == 5);
    UInt8 *data = bytes;
    assert(data[0] == 0x83 && data[1] == 0xf3); // Capability request, never Set VCP.
    assert((0x6e ^ 0x51 ^ data[0] ^ data[1] ^ data[2] ^ data[3] ^ data[4]) == 0);
    requestedOffset = ((unsigned)data[2] << 8) | data[3];
    writes++;
    return mode == 4 ? kIOReturnError : kIOReturnSuccess;
}
IOReturn IOAVServiceReadI2C(IOAVServiceRef service, uint32_t chip, uint32_t address, void *bytes, uint32_t length) {
    (void)service; (void)chip;
    assert(address == 0x51 && length == 38);
    UInt8 *data = bytes;
    memset(data, 0, length);
    size_t total = strlen(capText);
    unsigned count = mode == 5 ? 32 : (unsigned)MIN(32, total - requestedOffset);
    data[0] = 0x6e; data[1] = 0x80 | (count + 3); data[2] = 0xe3;
    data[3] = requestedOffset >> 8; data[4] = requestedOffset & 255;
    if (mode == 5) memset(data + 5, 'a', count);
    else memcpy(data + 5, capText + requestedOffset, count);
    if (mode == 2) data[4] ^= 1;
    if (mode == 3) data[2] = 0x02; // Wrong reply opcode.
    if (mode == 6 && count) data[5] = 0x01; // Invalid text.
    if (mode == 7 && count) data[5 + count - 1] = 0; // NUL-terminated final chunk.
    UInt8 checksum = 0x50;
    for (unsigned i = 0; i < count + 5; i++) checksum ^= data[i];
    data[count + 5] = checksum;
    if (mode == 1) data[count + 5] ^= 1;
    if (mode == 8) data[1] = 0xff; // Oversized frame.
    return kIOReturnSuccess;
}
int main(void) {
    @autoreleasepool {
        DDCTransport transport = {.service = NULL, .chipAddress = 0x37};
        capText = "(prot(monitor)model(Example)vcp(10 60(0F 10 11 12 1B) D6(01 04)))";
        NSString *text = readCapabilities(&transport);
        assert([text isEqualToString:@(capText)] && writes > 1);
        for (mode = 1; mode <= 6; mode++) assert(readCapabilities(&transport) == nil);
        mode = 7; capText = "(vcp(60(11)))X";
        assert([readCapabilities(&transport) isEqualToString:@"(vcp(60(11)))"]);
        mode = 8; assert(readCapabilities(&transport) == nil);
        mode = 0; capText = "";
        assert([readCapabilities(&transport) isEqualToString:@""]);
        puts("Passed 10 capability-transport cases using simulated I2C only.");
    }
    return 0;
}
