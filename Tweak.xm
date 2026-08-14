#import <UIKit/UIKit.h>

%hook IGFeedPhotoView

- (void)layoutSubviews {
    %orig;
    NSLog(@"InstPls: تم تحميل عرض الفيديو");
}

%end