@import Foundation;
@import IOKit;
#include "capabilities.h"

// Reuse upstream's display matching and transport selection without modifying it.
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--help") == 0) {
            puts("display-discovery display list | display UUID capabilities");
            return EXIT_SUCCESS;
        }
        bool list = argc == 3 && strcmp(argv[1], "display") == 0 && strcmp(argv[2], "list") == 0;
        bool capabilities = argc == 4 && strcmp(argv[1], "display") == 0 && strcmp(argv[3], "capabilities") == 0;
        if (!list && !capabilities) {
            fputs("Expected display list or display UUID capabilities\n", stderr);
            return EXIT_FAILURE;
        }
        DisplayInfos displays[MAX_DISPLAYS] = {};
        CGDisplayCount count = getOnlineDisplayInfos(displays);
        for (CGDisplayCount i = 0; i < count; i++) {
            DisplayInfos *display = &displays[i];
            if (CGDisplayIsBuiltin(display->id)) continue;
            if (list) {
                printf("[%u] %s (%s)\n", i + 1,
                       [display->productName ?: @"External Display" UTF8String], [display->uuid UTF8String]);
            } else if ([display->uuid isEqualToString:@(argv[2])]) {
                DDCTransport transport = getDisplayDDCTransport(display);
                if (!transport.service) break;
                NSString *text = readCapabilities(&transport);
                CFRelease(transport.service);
                if (!text) break;
                puts([text UTF8String]);
                return EXIT_SUCCESS;
            }
        }
        if (list) return EXIT_SUCCESS;
        fputs("Display or capabilities unavailable\n", stderr);
        return EXIT_FAILURE;
    }
}
