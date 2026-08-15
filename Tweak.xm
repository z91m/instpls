#import <UIKit/UIKit.h>
#import <Photos/Photos.h>

// ============================================================
// تعريف عام لتجنب أخطاء الترجمة (زر الحفظ يُضاف على أي خلية صورة بالفييد)
// ============================================================
@interface IGFeedPhotoView : UIView
@end

// ============================================================
// ذاكرة مؤقتة عامة لالتقاط روابط الميديا من طبقة الشبكة
// ============================================================
@interface InstplsMediaTracker : NSObject
+ (instancetype)shared;
- (void)recordURL:(NSURL *)url type:(NSString *)type;
- (NSString *)mostRecentURLString;
@end

@implementation InstplsMediaTracker {
    NSMutableArray<NSDictionary *> *_entries; // كل عنصر: {url, type, timestamp}
    NSLock *_lock;
}

+ (instancetype)shared {
    static InstplsMediaTracker *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [InstplsMediaTracker new];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _entries = [NSMutableArray array];
        _lock = [NSLock new];
    }
    return self;
}

- (void)pruneLocked {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSMutableArray *fresh = [NSMutableArray array];
    for (NSDictionary *entry in _entries) {
        NSTimeInterval ts = [entry[@"timestamp"] doubleValue];
        if (now - ts <= 25.0) { // نحتفظ فقط بآخر 25 ثانية
            [fresh addObject:entry];
        }
    }
    // نحد الحد الأقصى لعدد العناصر حتى لو كلها حديثة
    while (fresh.count > 15) {
        [fresh removeObjectAtIndex:0];
    }
    _entries = fresh;
}

- (void)recordURL:(NSURL *)url type:(NSString *)type {
    if (!url) return;
    [_lock lock];
    NSDictionary *entry = @{
        @"url": url.absoluteString,
        @"type": type ?: @"unknown",
        @"timestamp": @([NSDate date].timeIntervalSince1970)
    };
    [_entries addObject:entry];
    [self pruneLocked];
    [_lock unlock];
    NSLog(@"📡 InstPls: تم رصد رابط ميديا (%@): %@", type, url.absoluteString);
}

- (NSString *)mostRecentURLString {
    NSString *result = nil;
    [_lock lock];
    [self pruneLocked];
    if (_entries.count > 0) {
        NSDictionary *last = _entries.lastObject;
        result = last[@"url"];
        [_entries removeLastObject]; // نستهلكه حتى ما نعيد استخدام نفس الرابط مرتين
    }
    [_lock unlock];
    return result;
}

@end

// ============================================================
// دالة فلترة: هل هذا رابط ميديا فعلي من سيرفرات إنستقرام؟
// ترجع: @"image" أو @"video" أو nil (لو مو ميديا أو مو من CDN إنستقرام)
// ============================================================
static NSString * instpls_classifyMediaURL(NSURL *url) {
    if (!url) return nil;
    NSString *host = [url.host lowercaseString];
    if (!host) return nil;

    BOOL isInstagramCDN = [host containsString:@"cdninstagram.com"] ||
                          [host containsString:@"fbcdn.net"];
    if (!isInstagramCDN) return nil;

    NSString *path = [url.path lowercaseString];
    NSArray *imageExts = @[@".jpg", @".jpeg", @".png", @".heic", @".webp"];
    NSArray *videoExts  = @[@".mp4", @".mov"];

    for (NSString *ext in imageExts) {
        if ([path hasSuffix:ext]) return @"image";
    }
    for (NSString *ext in videoExts) {
        if ([path hasSuffix:ext]) return @"video";
    }
    // بعض روابط CDN ما فيها امتداد واضح بالمسار (باراميترات مشفرة)
    // نتجاهلها حاليًا لتفادي التقاط روابط غير ميديا (زي API calls)
    return nil;
}

// ============================================================
// 1. هوك مركزي على طبقة الشبكة: يلتقط كل رابط ميديا يمر عبر NSURLSession
// ============================================================
%hook NSURLSessionTask

- (void)resume {
    @try {
        NSURL *url = self.currentRequest.URL ?: self.originalRequest.URL;
        NSString *type = instpls_classifyMediaURL(url);
        if (type) {
            [[InstplsMediaTracker shared] recordURL:url type:type];
        }
    } @catch (NSException *e) {
        // لا نكسر تحميل التطبيق الأصلي إطلاقًا مهما صار
    }
    %orig;
}

%end

// ============================================================
// 2. زر الحفظ على واجهة الصورة/الفيديو بالفييد
// ============================================================
%hook IGFeedPhotoView

- (void)layoutSubviews {
    %orig;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIButton *saveBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        [saveBtn setTitle:@"📥 Save" forState:UIControlStateNormal];
        [saveBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [saveBtn setBackgroundColor:[UIColor colorWithRed:0.0 green:0.5 blue:1.0 alpha:0.8]];
        saveBtn.layer.cornerRadius = 8;
        saveBtn.frame = CGRectMake(20, 20, 80, 35);
        saveBtn.tag = 991199;
        [saveBtn addTarget:self action:@selector(instpls_saveMedia) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:saveBtn];
    });
}

%new
- (void)instpls_flashButtonFeedback:(BOOL)success {
    UIButton *btn = [self viewWithTag:991199];
    if (!btn) return;
    NSString *originalTitle = [btn titleForState:UIControlStateNormal];
    [btn setTitle:success ? @"✅ Saved" : @"❌ Not found" forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [btn setTitle:originalTitle forState:UIControlStateNormal];
    });
}

%new
- (void)instpls_saveMedia {
    NSString *urlString = [[InstplsMediaTracker shared] mostRecentURLString];

    if (!urlString) {
        NSLog(@"❌ InstPls: لا يوجد رابط ميديا مرصود حاليًا. جرب تسكرول شوي أو انتظر تحميل الصورة كامل.");
        [self instpls_flashButtonFeedback:NO];
        return;
    }

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        NSLog(@"❌ InstPls: الرابط الملتقط غير صالح.");
        [self instpls_flashButtonFeedback:NO];
        return;
    }

    NSLog(@"✅ InstPls: جاري تحميل الوسائط من: %@", url);

    __weak typeof(self) weakSelf = self;
    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        BOOL success = NO;

        if (error || !location) {
            NSLog(@"❌ InstPls: فشل التحميل: %@", error);
        } else {
            NSString *mime = [response.MIMEType lowercaseString] ?: @"";
            NSString *ext = [mime containsString:@"video"] ? @"mp4" : @"jpg";
            NSString *destPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                   [[NSUUID UUID].UUIDString stringByAppendingPathExtension:ext]];

            NSError *copyError = nil;
            [[NSFileManager defaultManager] copyItemAtPath:location.path toPath:destPath error:&copyError];

            if (copyError) {
                NSLog(@"❌ InstPls: فشل نسخ الملف المؤقت: %@", copyError);
            } else if ([ext isEqualToString:@"mp4"]) {
                if (UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(destPath)) {
                    UISaveVideoAtPathToSavedPhotosAlbum(destPath, nil, nil, nil);
                    NSLog(@"✅ InstPls: تم حفظ الفيديو في الألبوم.");
                    success = YES;
                }
            } else {
                UIImage *image = [UIImage imageWithContentsOfFile:destPath];
                if (image) {
                    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil);
                    NSLog(@"✅ InstPls: تم حفظ الصورة في الألبوم.");
                    success = YES;
                }
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf instpls_flashButtonFeedback:success];
        });
    }];
    [task resume];
}

%end

// ============================================================
// رسالة تأكيد عند تحميل التعديل
// ============================================================
%ctor {
    NSLog(@"🚀 InstPls: تم تحميل التعديل بنجاح! (نسخة الحفظ عبر الشبكة)");
}
