#ifndef YTB_H
#define YTB_H

#import <Foundation/Foundation.h>

/// YES when the user has switched the blocker off through NSUserDefaults
/// (key: YTBURLBlockerDisabled) in the host app's domain.
FOUNDATION_EXPORT BOOL YTBURLBlockerDisabled(void);

/// Returns YES when the URL belongs to an ad / tracking endpoint that the
/// client never needs in order to play a video.
FOUNDATION_EXPORT BOOL YTBBlockedURL(NSURL *url);

/// Installs the NSURLProtocol intercepting every request the app makes.
FOUNDATION_EXPORT void YTBInstallURLBlocker(void);

#endif /* YTB_H */
