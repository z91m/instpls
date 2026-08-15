#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <objc/message.h>

// --- تعريفات عامة لتجنب أخطاء الترجمة ---
@interface IGFeedPhotoView : UIView
@property (nonatomic, strong) id media;
@property (nonatomic, strong) id item;
- (id)feedItem;
@end

@interface IGCommentCell : UITableViewCell
@property (nonatomic, strong) UILabel *textLabel;
@property (nonatomic, strong) UILabel *commentTextLabel;
@end

@interface IGDirectThreadViewController : UIViewController
- (void)sendReadReceipt;
- (void)sendTypingIndicator;
@end

// ============================================================
// دالة مساعدة: استدعاء selector يرجع NSString بأمان (بدون تحذيرات ARC)
// ============================================================
static NSString * instpls_safeStringFromSelector(id target, SEL selector) {
    if (!target || ![target respondsToSelector:selector]) return nil;
    NSString *(*func)(id, SEL) = (NSString *(*)(id, SEL))objc_msgSend;
    id result = func(target, selector);
    if (result && [result isKindOfClass:[NSString class]]) {
        return result;
    }
    return nil;
}

// ============================================================
// 1. ميزة تحميل الصور والفيديوهات
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
        [saveBtn addTarget:self action:@selector(instpls_saveMedia) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:saveBtn];
    });
}

%new
- (void)instpls_saveMedia {
    id mediaObject = nil;
    if ([self respondsToSelector:@selector(media)]) {
        mediaObject = [self media];
    } else if ([self respondsToSelector:@selector(item)]) {
        mediaObject = [self item];
    } else if ([self respondsToSelector:@selector(feedItem)]) {
        mediaObject = [self feedItem];
    }

    if (!mediaObject) {
        NSLog(@"❌ InstPls: لم يتم العثور على وسائط للحفظ.");
        return;
    }

    NSString *urlString = instpls_safeStringFromSelector(mediaObject, @selector(imageURL));
    if (!urlString) urlString = instpls_safeStringFromSelector(mediaObject, @selector(videoURL));
    if (!urlString) urlString = instpls_safeStringFromSelector(mediaObject, @selector(url));

    if (!urlString) {
        NSLog(@"❌ InstPls: لم يتم العثور على رابط صالح.");
        return;
    }

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        NSLog(@"❌ InstPls: الرابط غير صحيح.");
        return;
    }

    NSLog(@"✅ InstPls: جاري تحميل الوسائط من: %@", url);

    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        if (error || !location) {
            NSLog(@"❌ InstPls: فشل التحميل: %@", error);
            return;
        }

        NSString *ext = [[response MIMEType] hasPrefix:@"video"] ? @"mp4" : @"jpg";
        NSString *destPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID].UUIDString stringByAppendingPathExtension:ext]];
        NSError *copyError = nil;
        [[NSFileManager defaultManager] copyItemAtPath:location.path toPath:destPath error:&copyError];
        if (copyError) {
            NSLog(@"❌ InstPls: فشل نسخ الملف المؤقت: %@", copyError);
            return;
        }

        if ([ext isEqualToString:@"mp4"]) {
            if (UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(destPath)) {
                UISaveVideoAtPathToSavedPhotosAlbum(destPath, nil, nil, nil);
                NSLog(@"✅ InstPls: تم حفظ الفيديو في الألبوم.");
            }
        } else {
            UIImage *image = [UIImage imageWithContentsOfFile:destPath];
            if (image) {
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil);
                NSLog(@"✅ InstPls: تم حفظ الصورة في الألبوم.");
            }
        }
    }];
    [task resume];
}
%end

// ============================================================
// 2. ميزة نسخ التعليقات (بالضغط المطول)
// ============================================================
%hook IGCommentCell

- (void)awakeFromNib {
    %orig;
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(instpls_copyComment:)];
    [self addGestureRecognizer:longPress];
}

%new
- (void)instpls_copyComment:(UIGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;

    UILabel *label = nil;
    if ([self respondsToSelector:@selector(commentTextLabel)]) {
        label = [self commentTextLabel];
    } else if ([self respondsToSelector:@selector(textLabel)]) {
        label = [self textLabel];
    }

    if (label && label.text.length > 0) {
        [UIPasteboard generalPasteboard].string = label.text;
        NSLog(@"📋 InstPls: تم نسخ التعليق.");

        UIColor *originalColor = label.backgroundColor;
        label.backgroundColor = [UIColor yellowColor];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            label.backgroundColor = originalColor;
        });
    } else {
        NSLog(@"❌ InstPls: لم يتم العثور على نص للنسخ.");
    }
}
%end

// ============================================================
// 3. ميزة إخفاء الظهور (تعطيل إيصال القراءة ومؤشر الكتابة)
// ============================================================
%hook IGDirectThreadViewController

- (void)sendReadReceipt {
    NSLog(@"👀 InstPls: تم حظر إرسال إيصال القراءة.");
}

- (void)sendTypingIndicator {
    NSLog(@"⌨️ InstPls: تم حظر مؤشر الكتابة.");
}
%end

// ============================================================
// رسالة تأكيد عند تحميل التعديل
// ============================================================
%ctor {
    NSLog(@"🚀 InstPls: تم تحميل التعديل بنجاح!");
}
