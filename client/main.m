// MacScreen: нативный клиент второго экрана для iOS 9 (armv7).
// Принимает прямоугольники BGRA (raw deflate) от screenserve, рисует их в полноэкранной view,
// курсор Mac рисует поверх, касания превращает в мышь.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <zlib.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>

static NSString *const kHostKey = @"serverHost";
static NSString *const kDefaultHost = @"192.168.1.144";
static const int kPort = 8082;

#pragma mark - ScreenView

@interface ScreenView : UIView
@property (nonatomic) int fbWidth, fbHeight;
@property (nonatomic) uint8_t *fb;              // XRGB1555 LE, 2 байта на пиксель
@property (nonatomic) CGContextRef ctx;
@property (nonatomic, strong) CALayer *cursorLayer;
- (void)resizeTo:(int)w height:(int)h;
- (void)blitRect:(CGRect)r data:(const uint8_t *)data;
- (void)present;
- (void)setCursorX:(int)x y:(int)y visible:(BOOL)visible;
@end

@implementation ScreenView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor blackColor];
        self.contentMode = UIViewContentModeScaleAspectFit;
        self.layer.magnificationFilter = kCAFilterNearest;
        self.multipleTouchEnabled = YES;
        _cursorLayer = [CALayer layer];
        _cursorLayer.contents = (id)[self cursorImage].CGImage;
        _cursorLayer.bounds = CGRectMake(0, 0, 16, 24);
        _cursorLayer.anchorPoint = CGPointMake(0, 0);
        _cursorLayer.hidden = YES;
        _cursorLayer.zPosition = 10;
        [self.layer addSublayer:_cursorLayer];
    }
    return self;
}

- (UIImage *)cursorImage {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(16, 24), NO, 0);
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGContextMoveToPoint(c, 1, 1);
    CGContextAddLineToPoint(c, 1, 18);
    CGContextAddLineToPoint(c, 5, 14);
    CGContextAddLineToPoint(c, 8, 21);
    CGContextAddLineToPoint(c, 11, 20);
    CGContextAddLineToPoint(c, 8, 13);
    CGContextAddLineToPoint(c, 14, 13);
    CGContextClosePath(c);
    CGContextSetFillColorWithColor(c, [UIColor blackColor].CGColor);
    CGContextSetStrokeColorWithColor(c, [UIColor whiteColor].CGColor);
    CGContextSetLineWidth(c, 1.2);
    CGContextDrawPath(c, kCGPathFillStroke);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

- (void)resizeTo:(int)w height:(int)h {
    if (w == _fbWidth && h == _fbHeight && _fb) return;
    if (_ctx) CGContextRelease(_ctx);
    free(_fb);
    _fbWidth = w; _fbHeight = h;
    _fb = calloc((size_t)w * 2 * h, 1);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    _ctx = CGBitmapContextCreate(_fb, w, h, 5, w * 2, cs,
                                 kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder16Little);
    CGColorSpaceRelease(cs);
}

- (void)blitRect:(CGRect)r data:(const uint8_t *)data {
    int x = (int)r.origin.x, y = (int)r.origin.y, w = (int)r.size.width, h = (int)r.size.height;
    if (!_fb || x < 0 || y < 0 || x + w > _fbWidth || y + h > _fbHeight) return;
    for (int row = 0; row < h; row++)
        memcpy(_fb + ((y + row) * _fbWidth + x) * 2, data + row * w * 2, w * 2);
}

- (void)present {
    if (!_ctx) return;
    CGImageRef img = CGBitmapContextCreateImage(_ctx);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.layer.contents = (__bridge id)img;
    self.layer.contentsGravity = kCAGravityResizeAspect;
    [CATransaction commit];
    CGImageRelease(img);
}

- (CGRect)imageFrame {
    // куда реально вписана картинка (aspect fit)
    if (_fbWidth == 0) return self.bounds;
    CGFloat sx = self.bounds.size.width / _fbWidth, sy = self.bounds.size.height / _fbHeight;
    CGFloat s = MIN(sx, sy);
    CGFloat w = _fbWidth * s, h = _fbHeight * s;
    return CGRectMake((self.bounds.size.width - w) / 2, (self.bounds.size.height - h) / 2, w, h);
}

- (void)setCursorX:(int)x y:(int)y visible:(BOOL)visible {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (!visible || _fbWidth == 0) { _cursorLayer.hidden = YES; }
    else {
        CGRect f = [self imageFrame];
        CGFloat s = f.size.width / _fbWidth;
        _cursorLayer.hidden = NO;
        _cursorLayer.position = CGPointMake(f.origin.x + x * s, f.origin.y + y * s);
    }
    [CATransaction commit];
}

- (CGPoint)fbPointFromTouch:(CGPoint)p {
    CGRect f = [self imageFrame];
    CGFloat s = f.size.width / MAX(1, _fbWidth);
    CGFloat x = (p.x - f.origin.x) / s, y = (p.y - f.origin.y) / s;
    x = MAX(0, MIN(_fbWidth - 1, x)); y = MAX(0, MIN(_fbHeight - 1, y));
    return CGPointMake(x, y);
}
@end

#pragma mark - Client

@interface Client : NSObject
@property (nonatomic, weak) ScreenView *view;
@property (nonatomic, copy) NSString *host;
@property (nonatomic) int fd;
@property (nonatomic) BOOL stop;
@property (nonatomic, copy) void (^statusBlock)(NSString *);
- (void)start;
- (void)sendMouseX:(int)x y:(int)y action:(uint8_t)action;
- (void)sendScrollX:(int)x y:(int)y dx:(int)dx dy:(int)dy;
@end

@implementation Client

- (void)start {
    [NSThread detachNewThreadSelector:@selector(loop) toTarget:self withObject:nil];
}

- (void)status:(NSString *)s {
    dispatch_async(dispatch_get_main_queue(), ^{ if (self.statusBlock) self.statusBlock(s); });
}

static BOOL readFully(int fd, uint8_t *buf, size_t n) {
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, buf + got, n - got);
        if (r <= 0) return NO;
        got += (size_t)r;
    }
    return YES;
}

- (int)connectTo:(NSString *)host {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_port = htons(kPort);
    if (inet_pton(AF_INET, host.UTF8String, &a.sin_addr) != 1) { close(fd); return -1; }
    struct timeval tv = {5, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    if (connect(fd, (struct sockaddr *)&a, sizeof a) != 0) { close(fd); return -1; }
    tv.tv_sec = 30; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    int one = 1; setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    write(fd, "MSC1", 4);
    return fd;
}

- (void)loop {
    uint8_t *comp = malloc(4 * 1024 * 1024);
    uint8_t *raw = malloc(1024 * 1024 * 4 * 2);
    size_t rawCap = 1024 * 1024 * 4 * 2;
    while (!self.stop) {
        [self status:[NSString stringWithFormat:@"Подключение к %@…", self.host]];
        int fd = [self connectTo:self.host];
        if (fd < 0) { sleep(2); continue; }
        self.fd = fd;
        [self status:nil];
        int frames = 0; NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
        while (!self.stop) {
            uint8_t type;
            if (!readFully(fd, &type, 1)) break;
            if (type == 1) {
                uint8_t b[5]; if (!readFully(fd, b, 5)) break;
                int w = b[0] | b[1] << 8, h = b[2] | b[3] << 8;
                dispatch_sync(dispatch_get_main_queue(), ^{ [self.view resizeTo:w height:h]; });
            } else if (type == 2) {
                uint8_t b[12]; if (!readFully(fd, b, 12)) break;
                int x = b[0] | b[1] << 8, y = b[2] | b[3] << 8, w = b[4] | b[5] << 8, h = b[6] | b[7] << 8;
                uint32_t len = b[8] | b[9] << 8 | b[10] << 16 | b[11] << 24;
                if (len > 4 * 1024 * 1024) break;
                if (!readFully(fd, comp, len)) break;
                size_t need = (size_t)w * 2 * h;
                if (need > rawCap) { rawCap = need; raw = realloc(raw, rawCap); }
                z_stream z; memset(&z, 0, sizeof z);
                inflateInit2(&z, -15);
                z.next_in = comp; z.avail_in = len; z.next_out = raw; z.avail_out = (uInt)need;
                int rc = inflate(&z, Z_FINISH);
                inflateEnd(&z);
                if (rc != Z_STREAM_END && rc != Z_OK) continue;
                // копируем в буфер вне главного потока: буфер защищён тем, что present() читает целиком
                [self.view blitRect:CGRectMake(x, y, w, h) data:raw];
            } else if (type == 3) {
                dispatch_sync(dispatch_get_main_queue(), ^{ [self.view present]; });
                uint8_t ack = 20; write(fd, &ack, 1);
                frames++;
                NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
                if (now - t0 > 10) { NSLog(@"MacScreen: %.1f кадров/с", frames / (now - t0)); frames = 0; t0 = now; }
            } else if (type == 5) {
                uint8_t b[5]; if (!readFully(fd, b, 5)) break;
                int x = (int16_t)(b[0] | b[1] << 8), y = (int16_t)(b[2] | b[3] << 8);
                BOOL vis = b[4] != 0;
                dispatch_async(dispatch_get_main_queue(), ^{ [self.view setCursorX:x y:y visible:vis]; });
            } else if (type == 4) {
                // ping
            } else {
                break;
            }
        }
        close(fd); self.fd = -1;
        if (!self.stop) sleep(1);
    }
    free(comp); free(raw);
}

- (void)sendMouseX:(int)x y:(int)y action:(uint8_t)action {
    if (self.fd < 0) return;
    uint8_t b[6] = {10, (uint8_t)(x & 0xff), (uint8_t)(x >> 8), (uint8_t)(y & 0xff), (uint8_t)(y >> 8), action};
    write(self.fd, b, 6);
}

- (void)sendScrollX:(int)x y:(int)y dx:(int)dx dy:(int)dy {
    if (self.fd < 0) return;
    uint8_t b[9] = {11, (uint8_t)(x & 0xff), (uint8_t)(x >> 8), (uint8_t)(y & 0xff), (uint8_t)(y >> 8),
                    (uint8_t)(dx & 0xff), (uint8_t)((dx >> 8) & 0xff), (uint8_t)(dy & 0xff), (uint8_t)((dy >> 8) & 0xff)};
    write(self.fd, b, 9);
}
@end

#pragma mark - ViewController

@interface ViewController : UIViewController
@property (nonatomic, strong) ScreenView *screen;
@property (nonatomic, strong) Client *client;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic) CGPoint touchStart;
@property (nonatomic) NSTimeInterval touchStartTime;
@property (nonatomic) BOOL dragging;
@property (nonatomic) CGPoint lastScroll;
@end

@implementation ViewController

- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    _screen = [[ScreenView alloc] initWithFrame:self.view.bounds];
    _screen.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_screen];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 40)];
    _statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.textColor = [UIColor whiteColor];
    _statusLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    [self.view addSubview:_statusLabel];

    NSString *host = [[NSUserDefaults standardUserDefaults] stringForKey:kHostKey] ?: kDefaultHost;
    _client = [Client new];
    _client.view = _screen;
    _client.host = host;
    __weak typeof(self) ws = self;
    _client.statusBlock = ^(NSString *s) { ws.statusLabel.text = s; ws.statusLabel.hidden = (s == nil); };
    [_client start];

    UITapGestureRecognizer *three = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(askHost)];
    three.numberOfTouchesRequired = 3;
    [self.view addGestureRecognizer:three];
    UITapGestureRecognizer *two = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(rightClick:)];
    two.numberOfTouchesRequired = 2;
    [self.view addGestureRecognizer:two];
    UIPanGestureRecognizer *pan2 = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(scroll:)];
    pan2.minimumNumberOfTouches = 2; pan2.maximumNumberOfTouches = 2;
    [self.view addGestureRecognizer:pan2];
}

- (void)askHost {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Адрес Mac" message:@"IP сервера screenserve"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.text = self.client.host; tf.keyboardType = UIKeyboardTypeDecimalPad; }];
    [a addAction:[UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Сохранить" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *h = a.textFields.firstObject.text;
        [[NSUserDefaults standardUserDefaults] setObject:h forKey:kHostKey];
        [[NSUserDefaults standardUserDefaults] synchronize];
        self.client.host = h;
        if (self.client.fd >= 0) { shutdown(self.client.fd, SHUT_RDWR); }
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)rightClick:(UITapGestureRecognizer *)g {
    CGPoint p = [_screen fbPointFromTouch:[g locationInView:_screen]];
    [_client sendMouseX:(int)p.x y:(int)p.y action:4];
}

- (void)scroll:(UIPanGestureRecognizer *)g {
    CGPoint p = [_screen fbPointFromTouch:[g locationInView:_screen]];
    if (g.state == UIGestureRecognizerStateBegan) { _lastScroll = [g translationInView:_screen]; return; }
    if (g.state != UIGestureRecognizerStateChanged) return;
    CGPoint t = [g translationInView:_screen];
    int dx = (int)(t.x - _lastScroll.x), dy = (int)(t.y - _lastScroll.y);
    _lastScroll = t;
    if (dx || dy) [_client sendScrollX:(int)p.x y:(int)p.y dx:dx dy:dy];
}

// Один палец: короткий тап = клик, движение = перемещение курсора; удержание 0.4 с и движение = перетаскивание
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    if (touches.count != 1 || event.allTouches.count != 1) return;
    UITouch *t = touches.anyObject;
    _touchStart = [t locationInView:_screen];
    _touchStartTime = t.timestamp;
    _dragging = NO;
    CGPoint p = [_screen fbPointFromTouch:_touchStart];
    [_client sendMouseX:(int)p.x y:(int)p.y action:0];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    if (event.allTouches.count != 1) return;
    UITouch *t = touches.anyObject;
    CGPoint loc = [t locationInView:_screen];
    CGPoint p = [_screen fbPointFromTouch:loc];
    if (!_dragging && t.timestamp - _touchStartTime > 0.4 && hypot(loc.x - _touchStart.x, loc.y - _touchStart.y) < 12) {
        _dragging = YES;
        [_client sendMouseX:(int)p.x y:(int)p.y action:1];
    }
    [_client sendMouseX:(int)p.x y:(int)p.y action:0];
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    if (event.allTouches.count != 1) return;
    UITouch *t = touches.anyObject;
    CGPoint loc = [t locationInView:_screen];
    CGPoint p = [_screen fbPointFromTouch:loc];
    if (_dragging) { [_client sendMouseX:(int)p.x y:(int)p.y action:2]; _dragging = NO; return; }
    if (t.timestamp - _touchStartTime < 0.35 && hypot(loc.x - _touchStart.x, loc.y - _touchStart.y) < 12)
        [_client sendMouseX:(int)p.x y:(int)p.y action:3];
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    if (_dragging) { CGPoint p = [_screen fbPointFromTouch:_touchStart]; [_client sendMouseX:(int)p.x y:(int)p.y action:2]; _dragging = NO; }
}
@end

#pragma mark - AppDelegate

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [ViewController new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class])); }
}
