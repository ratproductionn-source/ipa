#import "YTB.h"
#import <os/log.h>

extern os_log_t YTBLogHandle(void);

static NSString *const kYTBDisabledKey = @"YTBURLBlockerDisabled";

static NSArray<NSString *> *YTBBlockedHosts(void) {
    static NSArray<NSString *> *hosts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hosts = @[
            @"doubleclick.net",
            @"googleadservices.com",
            @"googlesyndication.com",
            @"adservice.google.com",
        ];
    });
    return hosts;
}

static NSArray<NSString *> *YTBBlockedPathFragments(void) {
    static NSArray<NSString *> *fragments;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fragments = @[
            @"/api/stats/ads",
            @"/api/stats/atr",
            @"/pagead/",
            @"/ptracking",
            @"/get_midroll_info",
        ];
    });
    return fragments;
}

BOOL YTBURLBlockerDisabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kYTBDisabledKey];
}

BOOL YTBBlockedURL(NSURL *url) {
    if (url == nil) {
        return NO;
    }

    NSString *host = url.host.lowercaseString;
    if (host.length > 0) {
        for (NSString *blocked in YTBBlockedHosts()) {
            if ([host isEqualToString:blocked] ||
                [host hasSuffix:[@"." stringByAppendingString:blocked]]) {
                return YES;
            }
        }
    }

    NSString *absolute = url.absoluteString;
    if (absolute.length > 0) {
        for (NSString *fragment in YTBBlockedPathFragments()) {
            if ([absolute rangeOfString:fragment].location != NSNotFound) {
                return YES;
            }
        }
    }

    return NO;
}

/// Serves an empty 204 for blocked requests instead of letting them reach the
/// network. Keeps the player's state machine alive: it sees a completed,
/// empty response rather than a transport error it would retry or surface.
@interface YTBURLBlocker : NSURLProtocol @end

@implementation YTBURLBlocker

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([NSURLProtocol propertyForKey:@"YTBHandled" inRequest:request] != nil) {
        return NO;
    }
    return YTBBlockedURL(request.URL);
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSMutableURLRequest *mutableRequest = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:@"YTBHandled" inRequest:mutableRequest];

    NSHTTPURLResponse *response =
        [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                    statusCode:204
                                   HTTPVersion:@"HTTP/1.1"
                                  headerFields:@{@"Content-Length": @"0"}];

    [self.client URLProtocol:self
          didReceiveResponse:response
          cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:[NSData data]];
    [self.client URLProtocolDidFinishLoading:self];

    os_log(YTBLogHandle(), "YTBypass: blocked %{public}@", self.request.URL.host);
}

- (void)stopLoading {
}

@end

void YTBInstallURLBlocker(void) {
    [NSURLProtocol registerClass:[YTBURLBlocker class]];
}
