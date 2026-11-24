#import "YTB.h"
#import <os/log.h>

os_log_t YTBLogHandle(void) {
    static os_log_t handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = os_log_create("com.ratproduction.ytbypass", "core");
    });
    return handle;
}

__attribute__((constructor)) static void YTBInit(void) {
    @autoreleasepool {
        if (YTBURLBlockerDisabled()) {
            os_log(YTBLogHandle(), "YTBypass: blocker disabled via preference");
            return;
        }
        YTBInstallURLBlocker();
        os_log(YTBLogHandle(), "YTBypass: ad/tracking URL blocker active");
    }
}
