#import <Foundation/Foundation.h>
#include "i2c.h"
// Reads capability text only; never sends a Set VCP command.
NSString *readCapabilities(DDCTransport *transport);
