#include "capabilities.h"

NSString *readCapabilities(DDCTransport *transport) {
    NSMutableData *text = [NSMutableData data];
    for (unsigned offset = 0; offset < 4096;) {
        UInt8 reply[38] = {};
        unsigned payload = 0;
        bool valid = false;
        for (int attempt = 0; attempt < 3 && !valid; attempt++) {
            UInt8 request[] = {0x83, 0xf3, offset >> 8, offset & 255, 0};
            request[4] = 0x6e ^ 0x51 ^ request[0] ^ request[1] ^ request[2] ^ request[3];
            usleep(50000);
            if (IOAVServiceWriteI2C(transport->service, transport->chipAddress, 0x51, request, sizeof(request))) continue;
            usleep(50000);
            memset(reply, 0, sizeof(reply));
            if (IOAVServiceReadI2C(transport->service, transport->chipAddress, 0x51, reply, sizeof(reply))) continue;
            payload = reply[1] & 0x7f;
            if (reply[0] != 0x6e || !(reply[1] & 0x80) || payload < 3 || payload > 35 || reply[2] != 0xe3) continue;
            if ((((unsigned)reply[3] << 8) | reply[4]) != offset) continue;
            UInt8 checksum = 0x50;
            for (unsigned i = 0; i < payload + 3; i++) checksum ^= reply[i];
            valid = checksum == 0;
        }
        if (!valid) return nil;
        unsigned count = payload - 3;
        if (!count) return [[NSString alloc] initWithData:text encoding:NSASCIIStringEncoding];
        for (unsigned i = 0; i < count; i++) {
            if (reply[5 + i] == 0) return [[NSString alloc] initWithData:text encoding:NSASCIIStringEncoding];
            if (reply[5 + i] < 0x20 || reply[5 + i] > 0x7e) return nil;
            [text appendBytes:&reply[5 + i] length:1];
        }
        offset += count;
    }
    return nil;
}
