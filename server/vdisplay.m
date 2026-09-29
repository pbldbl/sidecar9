#import <Foundation/Foundation.h>
#import "vdisplay.h"

@class CGVirtualDisplay;
@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) uint32_t maxPixelsWide;
@property (nonatomic) uint32_t maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) uint32_t productID;
@property (nonatomic) uint32_t vendorID;
@property (nonatomic) uint32_t serialNum;
@property (nonatomic, copy) void (^terminationHandler)(id sender, CGVirtualDisplay *display);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) uint32_t hiDPI;
@property (nonatomic, copy) NSArray<CGVirtualDisplayMode *> *modes;
@end

@interface CGVirtualDisplay : NSObject
@property (nonatomic, readonly) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

static CGVirtualDisplay *gDisplay;

CGDirectDisplayID VDCreate(int width, int height, double refreshHz, int hiDPI, const char *name) {
    @autoreleasepool {
        CGVirtualDisplayDescriptor *d = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
        if (!d) return 0;
        d.queue = dispatch_get_main_queue();
        d.name = [NSString stringWithUTF8String:name];
        d.maxPixelsWide = (uint32_t)(width * (hiDPI ? 2 : 1));
        d.maxPixelsHigh = (uint32_t)(height * (hiDPI ? 2 : 1));
        d.sizeInMillimeters = CGSizeMake(160, 120);   // ~7.9" 4:3, как у iPad mini
        d.vendorID = 0x4A4F;   // произвольные, но постоянные: macOS помнит раскладку по ним
        d.productID = 0x0A01;
        d.serialNum = 1;
        d.terminationHandler = nil;
        CGVirtualDisplay *disp = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:d];
        if (!disp) return 0;
        CGVirtualDisplaySettings *s = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
        s.hiDPI = hiDPI ? 1 : 0;
        CGVirtualDisplayMode *m = [[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:(uint32_t)width height:(uint32_t)height refreshRate:refreshHz];
        s.modes = @[m];
        if (![disp applySettings:s]) return 0;
        gDisplay = disp;
        return disp.displayID;
    }
}

void VDDestroy(void) {
    gDisplay = nil;
}
