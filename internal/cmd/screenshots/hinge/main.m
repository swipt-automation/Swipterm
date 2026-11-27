#import <Foundation/Foundation.h>
#import <IOKit/IOCFSerialize.h>
#import <mach/mach_time.h>

// These HID SPI are exported by the Simulator's IOKit. CoreSimulator's hinge
// slider sends a vendor-defined HID event carrying its new angle in degrees.
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
extern IOHIDEventRef IOHIDEventCreateVendorDefinedEvent(CFAllocatorRef allocator,
    uint64_t timestamp, uint32_t usagePage, uint32_t usage, uint32_t version,
    const uint8_t *data, CFIndex length, uint32_t options);
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client, IOHIDEventRef event);

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSNumber *angle = argc == 2 ? (@{@"open": @180})[@(argv[1])] : nil;
        if (!angle) {
            fprintf(stderr, "Expected pose open\n");
            return 2;
        }
        NSDictionary *payload = @{
            @"provider": @"com.apple.Virtualization.VirtualMachines",
            @"source": @"hinge-slider-control",
            @"type": @"range",
            @"value": angle,
        };
        NSData *data = CFBridgingRelease(IOCFSerialize((__bridge CFTypeRef)payload, kIOCFSerializeToBinary));
        if (!data) {
            fprintf(stderr, "Unable to serialize simulator hinge angle\n");
            return 1;
        }
        IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (!client) {
            fprintf(stderr, "Unable to create simulator HID client\n");
            return 1;
        }
        IOHIDEventRef event = IOHIDEventCreateVendorDefinedEvent(kCFAllocatorDefault,
            mach_absolute_time(), 0xff61, 0x5b, 0, data.bytes, data.length, 0);
        if (!event) {
            CFRelease(client);
            fprintf(stderr, "Unable to create simulator hinge event\n");
            return 1;
        }
        IOHIDEventSystemClientDispatchEvent(client, event);
        CFRelease(event);
        CFRelease(client);
        return 0;
    }
}
