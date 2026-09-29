// Виртуальный дисплей через приватный API CoreGraphics (то же, что делает DeskPad).
#import <CoreGraphics/CoreGraphics.h>
CGDirectDisplayID VDCreate(int width, int height, double refreshHz, int hiDPI, const char *name);
void VDDestroy(void);
