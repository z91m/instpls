#import <UIKit/UIKit.h>
#import <Photos/Photos.h>  // لحفظ الصور والفيديوهات في الألبوم

// --- تعريفات عامة لتجنب أخطاء الترجمة (نخبر المترجم بوجود هذه الكلاسات) ---
@interface IGFeedPhotoView : UIView
@property (nonatomic, strong) id media;   // يحتوي على بيانات الوسائط
@property (nonatomic, strong) id item;    // بديل لـ media في بعض الإصدارات
- (id)feedItem;                    // دالة لجلب العنصر
@end

@interface IGCommentCell : UITableViewCell
@property (nonatomic, strong) UILabel *textLabel;       // النص الأساسي
@property (nonatomic, strong) UILabel *commentTextLabel; // بديل لـ textLabel
@end

@interface IGDirectThreadViewController : UIViewController
- (void)sendReadReceipt;           // دالة إرسال إيصال القراءة
- (void)sendTypingIndicator;       // دالة إرسال مؤشر الكتابة
@end

// ============================================================
// 1. ميزة تحميل الصور والفيديوهات
// ============================================================
%hook IGFeedPhotoView

- (void)layoutSubviews {
    %orig;
    
    // نضيف الزر مرة واحدة فقط (نتجنب تكراره كل مرة يعاد رسم العرض)
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIButton *saveBtn = [UIButton buttonWithType:UIButtonTypeRoundedRect];
        [saveBtn setTitle:@"📥 Save" forState:UIControlStateNormal];
        [saveBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [saveBtn setBackgroundColor:[UIColor colorWithRed:0.0 green:0.5 blue:1.0 alpha:0.8]];
        saveBtn.layer.cornerRadius = 8;
        saveBtn.frame = CGRectMake(20, 20, 80, 35);
        [saveBtn addTarget:self action:@selector(instpls_saveMedia) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:saveBtn];
    });
}

// دالة الحفظ الجديدة (نستخدم NSURLSession الحديث بدلاً من NSURLConnection)
- (void)instpls_saveMedia {
    // 1. محاولة استخراج رابط الوسائط من الكائن الحالي
    id mediaObject = nil;
    if ([self respondsToSelector:@selector(media)]) {
        mediaObject = [self performSelector:@selector(media)];
    } else if ([self respondsToSelector:@selector(item)]) {
        mediaObject = [self performSelector:@selector(item)];
    } else if ([self respondsToSelector:@selector(feedItem)]) {
        mediaObject = [self performSelector:@selector(feedItem)];
    }
    
    if (!mediaObject) {
        NSLog(@"❌ InstPls: لم يتم العثور على وسائط للحفظ.");
        return;
    }
    
    // 2. محاولة استخراج الرابط (URL) من كائن الوسائط
    NSString *urlString = nil;
    if ([mediaObject respondsToSelector:@selector(imageURL)]) {
        urlString = [mediaObject performSelector:@selector(imageURL)];
    } else if ([mediaObject respondsToSelector:@selector(videoURL)]) {
        urlString = [mediaObject performSelector:@selector(videoURL)];
    } else if ([mediaObject respondsToSelector:@selector(url)]) {
        urlString = [mediaObject performSelector:@selector(url)];
    }
    
    if (!urlString || ![urlString isKindOfClass:[NSString class]]) {
        NSLog(@"❌ InstPls: لم يتم العثور على رابط صالح.");
        return;
    }
    
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        NSLog(@"❌ InstPls: الرابط غير صحيح.");
        return;
    }
    
    NSLog(@"✅ InstPls: جاري تحميل الوسائط من: %@", url);
    
    // 3. تحميل البيانات باستخدام NSURLSession (الحديث والأمن)
    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        if (error) {
            NSLog(@"❌ InstPls: فشل التحميل: %@", error);
            return;
        }
        
        // 4. حفظ الملف في ألبوم الصور
        NSString *tempPath = [location path];
        if ([[response MIMEType] hasPrefix:@"video"]) {
            // حفظ فيديو
            if (UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(tempPath)) {
                UISaveVideoAtPathToSavedPhotosAlbum(tempPath, nil, nil, nil);
                NSLog(@"✅ InstPls: تم حفظ الفيديو في الألبوم.");
            }
        } else {
            // حفظ صورة
            UIImage *image = [UIImage imageWithContentsOfFile:tempPath];
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

- (void)instpls_copyComment:(UIGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    
    // محاولة جلب النص من الخلية
    UILabel *label = nil;
    if ([self respondsToSelector:@selector(commentTextLabel)]) {
        label = [self performSelector:@selector(commentTextLabel)];
    } else if ([self respondsToSelector:@selector(textLabel)]) {
        label = [self performSelector:@selector(textLabel)];
    }
    
    if (label && [label.text length] > 0) {
        [UIPasteboard generalPasteboard].string = label.text;
        NSLog(@"📋 InstPls: تم نسخ التعليق: %@", label.text);
        
        // إشعار مرئي للمستخدم (وميض سريع)
        label.backgroundColor = [UIColor yellowColor];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            label.backgroundColor = [UIColor clearColor];
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
    // تعطيل إرسال إيصال القراءة (لا نستدعي %orig)
    NSLog(@"👀 InstPls: تم حظر إرسال إيصال القراءة.");
}

- (void)sendTypingIndicator {
    // تعطيل مؤشر الكتابة
    NSLog(@"⌨️ InstPls: تم حظر مؤشر الكتابة.");
}
%end

// ============================================================
// رسالة تأكيد عند تحميل التعديل (تظهر في سجل النظام)
// ============================================================
%ctor {
    NSLog(@"🚀 InstPls: تم تحميل التعديل بنجاح!");
}