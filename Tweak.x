// RedditLegacy: keeps the official Reddit app usable on iOS 15.
//  - Removes the NSFW label from subreddits in GraphQL responses (banner); posts keep theirs (blur).
//  - Blanks the "0 online" label, a count the server no longer provides.
//  - Blurs media inside NSFW subreddits, as the home feed already does.
//  - Removes ads from GraphQL responses.
//  - Reports a current version to Reddit's game servers.
//  - Adds a "View 18+ content" badge over blurred feed media, which clears images in place.
//
// Development builds (without RELEASE=1) also write and upload a diagnostics log: field names,
// numbers, booleans, API error messages, screen classes and short on-screen labels matching
// keywords. Tokens, headers and string values from responses are never stored.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

static const NSUInteger kMaxJSONBytes = 20 * 1024 * 1024;
static const int kMaxDepth = 64;
static const NSInteger kBadgeTag = 0x52454444;
static BOOL blurEnabled = YES;
static const CGFloat kMinMediaWidth = 100;
static const CGFloat kBlurredDetailLimit = 3;
enum { kDetailSide = 64 };
static NSMutableDictionary<NSString *, NSArray<NSString *> *> *clearAddressesByTitle;
static NSCache<NSString *, UIImage *> *revealedImages;
static char kImageDetailKey;
static char kClearAddressesKey;
static char kRecheckPendingKey;
// Newest platform version this app version can be expected to accept; see processJSON.
static NSString *const kGamePlatformVersion = @"0.12.0";
static NSString *const kGameClientVersion = @"2026.44.0";
static NSString *const kGameClientBuildNumber = @"700000";
static NSString *const kGameClientBuild = @"2026.44.0.700000";

static NSRegularExpression *zeroOnlineText;

static BOOL matches(NSRegularExpression *regex, NSString *text) {
  return [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)] != nil;
}

static BOOL isRedditHost(NSString *host) {
  return [host hasSuffix:@"reddit.com"] || [host hasSuffix:@"redd.it"] ||
         [host hasSuffix:@"redditmedia.com"] || [host hasSuffix:@"redditstatic.com"];
}

static BOOL isAPIHost(NSString *host) {
  return [host hasSuffix:@"reddit.com"] && ([host hasPrefix:@"gql"] || [host hasPrefix:@"oauth"]);
}

#ifdef RL_DEV
#import <stdatomic.h>

static const unsigned long long kMaxLogBytes = 2 * 1024 * 1024;
static const NSUInteger kMaxImageProbes = 30;
static const int64_t kLogUploadSeconds = 10;

static NSString *logPath;
static dispatch_queue_t logQueue;
static NSMutableSet<NSString *> *loggedLines;
static NSRegularExpression *interestingKey;
static NSRegularExpression *interestingLabel;
static NSRegularExpression *avatarPath;
static NSRegularExpression *typeLikeKey;
static NSRegularExpression *overlayClass;
static NSRegularExpression *versionHeader;
static NSRegularExpression *versionKey;
static NSRegularExpression *upgradeText;

// Each distinct line is written once per launch, so the log stays small and readable.
static void writeLog(NSString *line) {
  dispatch_async(logQueue, ^{
    if ([loggedLines containsObject:line]) return;
    [loggedLines addObject:line];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:logPath]) [fm createFileAtPath:logPath contents:nil attributes:nil];
    if ([fm attributesOfItemAtPath:logPath error:nil].fileSize > kMaxLogBytes) return;
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    [handle seekToEndOfFile];
    [handle writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
  });
}

// Downloads one image per field and records whether it arrives and whether iOS can decode it.
// Query strings are left out of the log.
static void probeImage(NSString *keyPath, NSString *urlString) {
  static NSMutableSet<NSString *> *probed;
  @synchronized(NSURLSession.class) {
    if (!probed) probed = [NSMutableSet set];
    if ([probed containsObject:keyPath] || probed.count >= kMaxImageProbes) return;
    [probed addObject:keyPath];
  }
  NSURL *url = [NSURL URLWithString:urlString];
  if (!url) {
    writeLog([NSString stringWithFormat:@"IMG %@ invalid url", keyPath]);
    return;
  }
  [[NSURLSession.sharedSession
      dataTaskWithURL:url
    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
      NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
                             ? ((NSHTTPURLResponse *)response).statusCode
                             : 0;
      UIImage *image = data ? [UIImage imageWithData:data] : nil;
      writeLog([NSString stringWithFormat:
                             @"IMG %@ host=%@ ext=%@ status=%ld type=%@ bytes=%lu decoded=%d err=%ld",
                             keyPath, url.host, url.pathExtension, (long)status, response.MIMEType,
                             (unsigned long)data.length, image != nil, (long)error.code]);
    }] resume];
}

// The receiver address is not compiled in: tools/add_log_url.py adds this file to a local package.
static void startLogUpload(void) {
  NSString *address = [NSString stringWithContentsOfFile:@"/var/jb/Library/MobileSubstrate/DynamicLibraries/RedditLegacy.url"
                                                encoding:NSUTF8StringEncoding
                                                   error:nil];
  address = [address stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSURL *uploadURL = address.length ? [NSURL URLWithString:address] : nil;
  if (!uploadURL) return;
  static unsigned long long lastSize = 0;
  static NSURLSession *session;
  static dispatch_source_t timer;
  session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
  timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, logQueue);
  dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, kLogUploadSeconds * NSEC_PER_SEC, NSEC_PER_SEC);
  dispatch_source_set_event_handler(timer, ^{
    NSData *log = [NSData dataWithContentsOfFile:logPath];
    if (log.length == 0 || log.length == lastSize) return;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:uploadURL];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 8;
    unsigned long long size = log.length;
    [[session uploadTaskWithRequest:request
                           fromData:log
                  completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                    if (!error) dispatch_async(logQueue, ^{ lastSize = size; });
                  }] resume];
  });
  dispatch_resume(timer);
}

// Asks the older REST endpoint whether Reddit still reports an online count. The app's
// token is only forwarded to oauth.reddit.com, and is never written to the log.
static void probeOnlineCount(NSURLRequest *source) {
  if (!isAPIHost(source.URL.host)) return;
  NSString *authorization = [source valueForHTTPHeaderField:@"Authorization"];
  if (![authorization hasPrefix:@"Bearer "]) return;
  // The probe's own request passes through the NSURLSession hook and calls this function
  // again, so the flag must be claimed before sending it. dispatch_once would crash here.
  static atomic_flag started = ATOMIC_FLAG_INIT;
  if (atomic_flag_test_and_set(&started)) return;
  NSMutableURLRequest *request = [NSMutableURLRequest
      requestWithURL:[NSURL URLWithString:@"https://oauth.reddit.com/r/AskReddit/about?raw_json=1"]];
  [request setValue:authorization forHTTPHeaderField:@"Authorization"];
  NSString *agent = [source valueForHTTPHeaderField:@"User-Agent"];
  if (agent) [request setValue:agent forHTTPHeaderField:@"User-Agent"];
  [[NSURLSession.sharedSession
      dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
          NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
                                 ? ((NSHTTPURLResponse *)response).statusCode
                                 : 0;
          NSDictionary *about = nil;
          if (data) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:NSDictionary.class] &&
                [json[@"data"] isKindOfClass:NSDictionary.class])
              about = json[@"data"];
          }
          writeLog([NSString stringWithFormat:
                                 @"PROBE status=%ld active_user_count=%@ accounts_active=%@ subscribers=%@",
                                 (long)status, about[@"active_user_count"],
                                 about[@"accounts_active"], about[@"subscribers"]]);
        }] resume];
}

static NSString *describeValue(id value) {
  if ([value isKindOfClass:NSNumber.class]) return [value description];
  if ([value isKindOfClass:NSString.class])
    return [NSString stringWithFormat:@"<string:%lu>", (unsigned long)[value length]];
  if (value == NSNull.null) return @"null";
  return nil;
}

static void logField(NSString *key, NSString *keyPath, id value, NSString *operation) {
  if ([value isKindOfClass:NSString.class]) {
    BOOL isGameVersion = [keyPath containsString:@"devvit"] && [key isEqualToString:@"version"];
    if ((matches(versionKey, key) || isGameVersion) && [value length] <= 40)
      writeLog([NSString stringWithFormat:@"VERSION %@ %@=%@", operation, keyPath, value]);
    if ([key isEqualToString:@"webViewBaseUrl"])
      writeLog([NSString stringWithFormat:@"GAMEWEB %@", [NSURL URLWithString:value].host]);
    if (matches(upgradeText, value))
      writeLog([NSString stringWithFormat:@"UPGRADE %@ %@", operation, keyPath]);
  }
  if ([value isKindOfClass:NSString.class] && [value hasPrefix:@"http"] &&
      matches(avatarPath, keyPath) && ![keyPath containsString:@"award"])
    probeImage(keyPath, value);
  if (matches(interestingKey, key)) {
    NSString *description = describeValue(value);
    if (description)
      writeLog([NSString stringWithFormat:@"FIELD %@ %@=%@", operation, keyPath, description]);
  }
}

// Shows which version the app reports, and which hosts Reddit's games use. Only headers named
// after a version, build, platform or user agent are recorded, so tokens stay out of the log.
static void logRequestVersion(NSURLRequest *request, NSURLSession *session) {
  NSString *host = request.URL.host;
  BOOL isDevvit = [host containsString:@"devvit"];
  if (!isRedditHost(host) && !isDevvit) return;
  NSMutableDictionary *headers = [NSMutableDictionary dictionary];
  [headers addEntriesFromDictionary:session.configuration.HTTPAdditionalHeaders];
  [headers addEntriesFromDictionary:request.allHTTPHeaderFields];
  for (NSString *key in headers) {
    if ([key isKindOfClass:NSString.class] && matches(versionHeader, key))
      writeLog([NSString stringWithFormat:@"HDR %@=%@", key, headers[key]]);
  }
  if (isDevvit) {
    NSArray<NSString *> *parts = request.URL.pathComponents;
    writeLog([NSString stringWithFormat:@"DEVVIT %@ %@", host, parts.count > 1 ? parts[1] : @"-"]);
  }
}

static void logWebView(NSURL *url) {
  NSArray<NSString *> *parts = url.pathComponents;
  writeLog([NSString stringWithFormat:@"WEB %@ %@", url.host, parts.count > 1 ? parts[1] : @"-"]);
}

// Records the upgrade notice when a web view shows it, and nothing else from the page.
static void logWebViewNotice(WKWebView *webView) {
  __weak WKWebView *weakView = webView;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    [weakView evaluateJavaScript:@"document.body ? document.body.innerText.slice(0, 300) : ''"
               completionHandler:^(id result, NSError *error) {
                 if ([result isKindOfClass:NSString.class] && matches(upgradeText, result))
                   writeLog([NSString stringWithFormat:@"WEBNOTICE %@", weakView.URL.host]);
               }];
  });
}

// Runs one turn later, once Auto Layout has placed the badge.
static void logBadgeState(UIView *media, UILabel *badge, NSUInteger addresses, CGFloat detail) {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSString *name = NSStringFromClass(media.class);
    NSString *kind = [name containsString:@"Carousel"] ? @"carousel"
                     : [name containsString:@"Video"]  ? @"video"
                                                       : @"image";
    writeLog([NSString stringWithFormat:@"BADGEPOS %@ media=%.0fx%.0f addresses=%lu detail=%.0f shown=%d", kind,
                                        media.bounds.size.width, media.bounds.size.height,
                                        (unsigned long)addresses, MIN(detail, 999), !badge.hidden]);
  });
}

static void logTap(void) { writeLog(@"TAP badge"); }

static void logReveal(NSUInteger index, BOOL decoded) {
  writeLog([NSString stringWithFormat:@"REVEAL page=%lu decoded=%d", (unsigned long)index, decoded]);
}

// Records how blurred and clear images measure, to check the limit against real images.
static void logDetail(UIView *media, CGFloat detail, BOOL isTagged) {
  NSString *kind = [NSStringFromClass(media.class) containsString:@"Video"] ? @"video" : @"image";
  writeLog([NSString stringWithFormat:@"DETAIL %@ tagged=%d value=%.0f", kind, isTagged, MIN(detail, 999)]);
}

static void logFeedStackFound(BOOL found) {
  writeLog([NSString stringWithFormat:@"BADGE feedStack=%d", found]);
}

static void logAd(NSString *path, NSString *operation, NSString *kind) {
  writeLog([NSString stringWithFormat:@"AD %@ %@ %@", operation, path, kind]);
}

// Records the shape of feed cells and blurred media as the server sent them. Strings are only
// kept for type-like fields, so titles and usernames stay out of the log.
static void logStructure(NSDictionary *dict, NSString *path, NSString *operation) {
  BOOL isMedia = dict[@"isObfuscated"] != nil;
  BOOL isFeedCell = dict[@"__typename"] != nil && [operation hasSuffix:@"Sdui"];
  if (!isMedia && !isFeedCell) return;
  NSMutableArray<NSString *> *fields = [NSMutableArray array];
  for (NSString *key in [dict.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    id value = dict[key];
    NSString *description;
    if ([value isKindOfClass:NSNumber.class]) description = [value description];
    else if (value == NSNull.null) description = @"null";
    else if ([value isKindOfClass:NSArray.class]) description = @"[]";
    else if ([value isKindOfClass:NSDictionary.class]) description = @"{}";
    else if ([key isEqualToString:@"__typename"] || matches(typeLikeKey, key)) description = value;
    else description = @"<s>";
    [fields addObject:[NSString stringWithFormat:@"%@=%@", key, description]];
  }
  writeLog([NSString stringWithFormat:@"STRUCT %@ %@ %@", operation, path,
                                      [fields componentsJoinedByString:@" "]]);
}

static NSString *operationName(NSURLRequest *request) {
  NSString *name = [request valueForHTTPHeaderField:@"x-apollo-operation-name"];
  if (name.length) return name;
  if (!request.HTTPBody) return @"?";
  id body = [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:nil];
  if ([body isKindOfClass:NSDictionary.class] && [body[@"operationName"] isKindOfClass:NSString.class])
    return body[@"operationName"];
  return @"?";
}

static void logResult(NSURLRequest *request, NSString *operation, NSURLResponse *response,
                      NSError *error) {
  NSString *host = request.URL.host;
  if (error) {
    writeLog([NSString stringWithFormat:@"NETERR %@ %@ %@ %ld", host, operation, error.domain,
                                        (long)error.code]);
    return;
  }
  NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
                         ? ((NSHTTPURLResponse *)response).statusCode
                         : 0;
  writeLog([NSString stringWithFormat:@"HTTP %ld %@ %@", (long)status, host, operation]);
}

static void logGraphQLErrors(id json, NSString *operation) {
  if (![json isKindOfClass:NSDictionary.class]) return;
  id errors = json[@"errors"];
  if (![errors isKindOfClass:NSArray.class]) return;
  for (id item in (NSArray *)errors) {
    if (![item isKindOfClass:NSDictionary.class]) continue;
    NSString *message = [item[@"message"] isKindOfClass:NSString.class] ? item[@"message"] : @"?";
    if (message.length > 200) message = [message substringToIndex:200];
    writeLog([NSString stringWithFormat:@"GQLERR %@ %@", operation, message]);
  }
}

static void logLabel(UILabel *label, NSString *text) {
  if (text.length == 0 || text.length > 60) return;
  if (matches(interestingLabel, text)) {
    NSMutableArray<NSString *> *chain = [NSMutableArray array];
    UIView *view = label;
    for (int i = 0; view && i < 6; i++, view = view.superview)
      [chain addObject:NSStringFromClass(view.class)];
    writeLog([NSString stringWithFormat:@"LABEL \"%@\" %@", text, [chain componentsJoinedByString:@" < "]]);
  }
}

// Shows whether the app itself asks for avatar images. The file name is left out of the log.
static void logAvatarRequest(NSURL *url) {
  NSString *path = url.path;
  if (!path || !matches(avatarPath, path)) return;
  NSArray<NSString *> *parts = url.pathComponents;
  writeLog([NSString stringWithFormat:@"REQ %@ %@ ext=%@", url.host,
                                      parts.count > 1 ? parts[1] : @"-", url.pathExtension]);
}

// Finds on-screen text that never goes through UILabel, such as custom or SwiftUI views.
static void logVisibleText(UIView *view, int depth) {
  if (depth > 40) return;
  NSString *className = NSStringFromClass(view.class);
  if (matches(overlayClass, className) && ![className hasPrefix:@"UI"] && ![className hasPrefix:@"_UI"]) {
    writeLog([NSString stringWithFormat:@"OVERLAY %@ < %@ hidden=%d alpha=%.2f", className,
                                        NSStringFromClass(view.superview.class), view.hidden, view.alpha]);
  }
  NSString *text = view.accessibilityLabel;
  if ([view isKindOfClass:UILabel.class]) text = ((UILabel *)view).text;
  else if ([view isKindOfClass:UITextView.class]) text = ((UITextView *)view).text;
  // Custom views can return something other than a string from accessibilityLabel.
  if ([text isKindOfClass:NSString.class] && text.length > 0 && text.length <= 60 &&
      matches(interestingLabel, text)) {
    NSString *parent = view.superview ? NSStringFromClass(view.superview.class) : @"-";
    writeLog([NSString stringWithFormat:@"VIEW \"%@\" %@ < %@", text, NSStringFromClass(view.class), parent]);
  }
  for (UIView *child in view.subviews) logVisibleText(child, depth + 1);
}

static void logScreen(UIViewController *controller) {
  NSString *name = NSStringFromClass(controller.class);
  writeLog([NSString stringWithFormat:@"SCREEN %@", name]);
  if ([name hasPrefix:@"UI"] || [name hasPrefix:@"_UI"]) return;
  __weak UIViewController *weakController = controller;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    UIViewController *strongController = weakController;
    if (strongController.isViewLoaded) logVisibleText(strongController.view, 0);
  });
}

// Feed cells appear while scrolling, long after their screen did, so the windows are rechecked.
static void startViewScan(void) {
  static dispatch_source_t timer;
  timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
  dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC);
  dispatch_source_set_event_handler(timer, ^{
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
      if (![scene isKindOfClass:UIWindowScene.class]) continue;
      for (UIWindow *window in ((UIWindowScene *)scene).windows) logVisibleText(window, 0);
    }
  });
  dispatch_resume(timer);
}

static void startDiagnostics(NSString *path) {
  logPath = path;
  logQueue = dispatch_queue_create("redditlegacy.log", DISPATCH_QUEUE_SERIAL);
  loggedLines = [NSMutableSet set];
  interestingKey = [NSRegularExpression
      regularExpressionWithPattern:@"nsfw|over_?18|mature|blur|obfuscat|online|active|visitor|"
                                   @"subscriber|contribution|ageverif|agegate|minimumage|"
                                   @"snoovatar|avatar|adpayload|promoted|sponsor|adpost|isad"
                           options:NSRegularExpressionCaseInsensitive
                             error:nil];
  interestingLabel = [NSRegularExpression
      regularExpressionWithPattern:@"nsfw|online|conectad|en l[ií]nea|18\\+|adult|mature|madur|sensible|"
                                   @"visitant|visitor|usuario|users|miembro|member|contribu|"
                                   @"uh oh|upgrade|latest version|actualiz|"
                                   @"\\b(ver|verla|toca|tocar|click|clic|pulsa|mostrar|show|view|reveal|tap)\\b"
                           options:NSRegularExpressionCaseInsensitive
                             error:nil];
  versionHeader = [NSRegularExpression regularExpressionWithPattern:@"version|build|platform|user-agent"
                                                            options:NSRegularExpressionCaseInsensitive
                                                              error:nil];
  versionKey = [NSRegularExpression regularExpressionWithPattern:@"minversion|minimumversion|appversion|minclient|clientversion|minapp|apiversion"
                                                         options:NSRegularExpressionCaseInsensitive
                                                           error:nil];
  upgradeText = [NSRegularExpression regularExpressionWithPattern:@"latest version|upgrade your app|uh oh"
                                                          options:NSRegularExpressionCaseInsensitive
                                                            error:nil];
  typeLikeKey = [NSRegularExpression regularExpressionWithPattern:@"type|kind|mode|state|style|variant|treatment|policy"
                                                          options:NSRegularExpressionCaseInsensitive
                                                            error:nil];
  overlayClass = [NSRegularExpression regularExpressionWithPattern:@"blur|obfuscat|nsfw|spoiler|reveal|overlay|sensitive|mature|image|media|gallery|thumbnail|preview"
                                                           options:NSRegularExpressionCaseInsensitive
                                                             error:nil];
  avatarPath = [NSRegularExpression regularExpressionWithPattern:@"avatar|snoo|icon"
                                                         options:NSRegularExpressionCaseInsensitive
                                                           error:nil];
  NSDictionary *info = NSBundle.mainBundle.infoDictionary;
  writeLog([NSString stringWithFormat:@"START app=%@ build=%@ ios=%@",
                                      info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"],
                                      UIDevice.currentDevice.systemVersion]);
  startLogUpload();
  startViewScan();
}

static BOOL shouldWrap(NSString *host) { return isRedditHost(host) || [host containsString:@"devvit"]; }
#else
static inline void logRequestVersion(NSURLRequest *request, NSURLSession *session) {}
static inline void logWebView(NSURL *url) {}
static inline void logWebViewNotice(WKWebView *webView) {}
static inline void logFeedStackFound(BOOL found) {}
static inline void logBadgeState(UIView *media, UILabel *badge, NSUInteger addresses, CGFloat detail) {}
static inline void logReveal(NSUInteger index, BOOL decoded) {}
static inline void logTap(void) {}
static inline void logDetail(UIView *media, CGFloat detail, BOOL isTagged) {}
static inline void probeOnlineCount(NSURLRequest *source) {}
static inline void logField(NSString *key, NSString *keyPath, id value, NSString *operation) {}
static inline void logStructure(NSDictionary *dict, NSString *path, NSString *operation) {}
static inline void logAd(NSString *path, NSString *operation, NSString *kind) {}
static inline NSString *operationName(NSURLRequest *request) { return nil; }
static inline void logResult(NSURLRequest *request, NSString *operation, NSURLResponse *response,
                             NSError *error) {}
static inline void logGraphQLErrors(id json, NSString *operation) {}
static inline void logLabel(UILabel *label, NSString *text) {}
static inline void logAvatarRequest(NSURL *url) {}
static inline void logScreen(UIViewController *controller) {}
static inline BOOL shouldWrap(NSString *host) { return isAPIHost(host); }
#endif

// Empties ad containers in place. Each field keeps its original JSON type, because the app's
// response parser rejects a field whose type changes.
static BOOL removeAds(NSMutableDictionary *dict, NSString *path, NSString *operation) {
  if (![dict isKindOfClass:NSMutableDictionary.class]) return NO;
  BOOL changed = NO;
  if ([dict[@"__typename"] isEqual:@"AdPost"] && ![dict[@"isHidden"] isEqual:@YES]) {
    dict[@"isHidden"] = @YES;
    logAd(path, operation, @"AdPost");
    changed = YES;
  }
  id cells = dict[@"cells"];
  if ([dict[@"adPayload"] isKindOfClass:NSDictionary.class] && [cells isKindOfClass:NSArray.class] &&
      [cells count] > 0) {
    dict[@"cells"] = @[];
    logAd(path, operation, @"adPayload");
    changed = YES;
  }
  for (NSString *key in @[ @"adPosts", @"commentsPageAds", @"commentTreeAds", @"pdpCommentsAds" ]) {
    id ads = dict[key];
    if ([ads isKindOfClass:NSArray.class] && [ads count] > 0) {
      dict[key] = @[];
      logAd(path, operation, key);
      changed = YES;
    }
  }
  return changed;
}

// Reddit's game servers answer this app version with an upgrade notice. Only requests to those
// servers report a current version; every other request keeps the real one.
static NSURLRequest *requestForGameServers(NSURLRequest *request) {
  if (![request.URL.host containsString:@"devvit"]) return request;
  NSMutableURLRequest *updated = [request mutableCopy];
  [updated setValue:[@"Reddit;iOS;" stringByAppendingString:kGameClientBuild]
      forHTTPHeaderField:@"devvit-user-agent"];
  NSString *agent = [request valueForHTTPHeaderField:@"User-Agent"];
  if (agent.length) {
    NSRange range = [agent rangeOfString:@"Reddit/Version "];
    NSRange end = [agent rangeOfString:@"/iOS "];
    if (range.location == 0 && end.location != NSNotFound) {
      NSString *current = [NSString stringWithFormat:@"Reddit/Version %@/Build %@", kGameClientVersion, kGameClientBuildNumber];
      [updated setValue:[current stringByAppendingString:[agent substringFromIndex:end.location]]
          forHTTPHeaderField:@"User-Agent"];
    }
  }
  return updated;
}

static NSString *normalizedTitle(NSString *title) {
  NSArray<NSString *> *words = [title.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSPredicate *notEmpty = [NSPredicate predicateWithFormat:@"length > 0"];
  return [[words filteredArrayUsingPredicate:notEmpty] componentsJoinedByString:@" "];
}

static void addClearAddress(id source, NSMutableArray<NSString *> *addresses) {
  if (![source isKindOfClass:NSDictionary.class]) return;
  NSString *blurred = source[@"obfuscatedPath"];
  NSString *clear = source[@"path"];
  if ([blurred isKindOfClass:NSString.class] && blurred.length && [clear isKindOfClass:NSString.class] && clear.length)
    [addresses addObject:clear];
}

// A feed post arrives as a group of cells: remembers its clear images under its title. These stay
// in memory only, and are what lets a tap show the image inside the feed.
static void rememberPostImages(NSDictionary *group) {
  NSArray *cells = group[@"cells"];
  if (![cells isKindOfClass:NSArray.class]) return;
  NSString *title = nil;
  NSMutableArray<NSString *> *addresses = [NSMutableArray array];
  for (NSDictionary *cell in cells) {
    if (![cell isKindOfClass:NSDictionary.class]) continue;
    NSString *type = cell[@"__typename"];
    if ([type isEqual:@"TitleCell"] && [cell[@"title"] isKindOfClass:NSString.class]) title = cell[@"title"];
    if ([type isEqual:@"ImageCell"]) addClearAddress(cell[@"media"], addresses);
    if ([type isEqual:@"GalleryCell"] && [cell[@"pages"] isKindOfClass:NSArray.class]) {
      for (NSDictionary *page in cell[@"pages"])
        if ([page isKindOfClass:NSDictionary.class]) addClearAddress(page[@"image"], addresses);
    }
  }
  if (title.length == 0 || addresses.count == 0) return;
  @synchronized(clearAddressesByTitle) { clearAddressesByTitle[normalizedTitle(title)] = addresses; }
}

static BOOL cellHasBlurredCopy(NSDictionary *cell) {
  for (NSString *key in @[ @"media", @"preview" ]) {
    NSDictionary *source = cell[key];
    if ([source isKindOfClass:NSDictionary.class] && [source[@"obfuscatedPath"] isKindOfClass:NSString.class] &&
        [source[@"obfuscatedPath"] length] > 0)
      return YES;
  }
  return NO;
}

static BOOL isSubredditObject(NSDictionary *dict, NSString *path) {
  if ([dict[@"__typename"] isEqual:@"Subreddit"]) return YES;
  return [[path componentsSeparatedByString:@"."].lastObject hasPrefix:@"subreddit"];
}

// Walks a parsed response and clears the NSFW label on subreddits. Only the exact key isNsfw
// is changed: account settings and age checks use other fields, and posts keep their label so
// the app still blurs NSFW media.
static BOOL processJSON(id object, NSString *path, NSString *operation, int depth) {
  if (depth > kMaxDepth) return NO;
  BOOL changed = NO;
  if ([object isKindOfClass:NSDictionary.class]) {
    NSMutableDictionary *dict = object;
    logStructure(dict, path, operation);
    if (removeAds(dict, path, operation)) changed = YES;
    if ([dict[@"__typename"] isEqual:@"CellGroup"]) rememberPostImages(dict);
    for (NSString *key in dict.allKeys) {
      id value = dict[key];
      NSString *keyPath = [path stringByAppendingFormat:@".%@", key];
      logField(key, keyPath, value, operation);
      // Games declare the platform version they were built with, and this app version may refuse
      // anything newer than it knows. Reporting an older one lets it try to open them.
      if ([key isEqualToString:@"publicApiVersion"] && [value isKindOfClass:NSString.class] &&
          [dict isKindOfClass:NSMutableDictionary.class] && ![value isEqualToString:kGamePlatformVersion]) {
        dict[key] = kGamePlatformVersion;
        changed = YES;
      }
      if ([key isEqualToString:@"isNsfwMediaBlocked"] && [value isKindOfClass:NSNumber.class])
        blurEnabled = [value boolValue];
      if ([key isEqualToString:@"isNsfw"] && [value isKindOfClass:NSNumber.class] &&
          [value boolValue] && [dict isKindOfClass:NSMutableDictionary.class] &&
          isSubredditObject(dict, path)) {
        dict[key] = @NO;
        changed = YES;
      } else if (processJSON(value, keyPath, operation, depth + 1)) {
        changed = YES;
      }
    }
    // Inside NSFW subreddits the server sends a blurred copy but marks the media as not
    // obfuscated, unlike the home feed. Marking it makes the app use that copy there too.
    id blurredCopy = dict[@"obfuscatedPath"];
    id isObfuscated = dict[@"isObfuscated"];
    BOOL hasBlurredCopy = [blurredCopy isKindOfClass:NSString.class] && [blurredCopy length] > 0;
    if (hasBlurredCopy && [isObfuscated isKindOfClass:NSNumber.class] && ![isObfuscated boolValue] &&
        [dict isKindOfClass:NSMutableDictionary.class]) {
      dict[@"isObfuscated"] = @YES;
      changed = YES;
    }
    // A blurred clip playing by itself is pointless, so it waits for a tap like an image does.
    if ([dict[@"__typename"] isEqual:@"LegacyVideoCell"] && [dict isKindOfClass:NSMutableDictionary.class] &&
        cellHasBlurredCopy(dict)) {
      for (NSString *key in @[ @"isAutoplayAllowed", @"isGif" ]) {
        if ([dict[key] isEqual:@YES]) {
          dict[key] = @NO;
          changed = YES;
        }
      }
    }
  } else if ([object isKindOfClass:NSArray.class]) {
    for (id item in (NSArray *)object)
      if (processJSON(item, path, operation, depth + 1)) changed = YES;
  }
  return changed;
}

static NSData *processResponse(NSURLRequest *request, NSString *operation, NSData *data) {
  if (!isAPIHost(request.URL.host) || data.length == 0 || data.length > kMaxJSONBytes) return data;
  id json = [NSJSONSerialization JSONObjectWithData:data
                                            options:NSJSONReadingMutableContainers
                                              error:nil];
  if (!json) return data;
  logGraphQLErrors(json, operation);
  if (!processJSON(json, @"$", operation, 0)) return data;
  // A failed rewrite falls back to the original response so the request still works.
  NSData *rewritten = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
  return rewritten ?: data;
}

static BOOL isBlurredMediaContainer(UIView *view) {
  NSString *name = NSStringFromClass(view.class);
  return [name containsString:@"MediaInsetSliceView"] &&
         ([name containsString:@"ServerImage"] || [name containsString:@"Carousel"] ||
          [name containsString:@"LegacyVideo"]);
}

static void collectImageViews(UIView *view, NSMutableArray<UIImageView *> *found, int depth) {
  if (depth > 14) return;
  if ([view isKindOfClass:UIImageView.class] && CGRectGetWidth(view.bounds) >= kMinMediaWidth)
    [found addObject:(UIImageView *)view];
  for (UIView *child in view.subviews) collectImageViews(child, found, depth + 1);
}

// Mean difference between neighbouring pixels of a small grayscale copy. A blurred copy has almost
// no fine detail, so this tells it apart from the clear image wherever the image came from.
static CGFloat imageDetail(UIImage *image) {
  NSNumber *cached = objc_getAssociatedObject(image, &kImageDetailKey);
  if (cached) return cached.doubleValue;
  CGImageRef source = image.CGImage;
  if (!source) return CGFLOAT_MAX;
  uint8_t pixels[kDetailSide * kDetailSide];
  CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
  CGContextRef context = CGBitmapContextCreate(pixels, kDetailSide, kDetailSide, 8, kDetailSide, gray,
                                               (CGBitmapInfo)kCGImageAlphaNone);
  CGColorSpaceRelease(gray);
  if (!context) return CGFLOAT_MAX;
  CGContextSetInterpolationQuality(context, kCGInterpolationLow);
  CGContextDrawImage(context, CGRectMake(0, 0, kDetailSide, kDetailSide), source);
  CGContextRelease(context);
  uint64_t total = 0;
  for (int y = 0; y < kDetailSide - 1; y++) {
    for (int x = 0; x < kDetailSide - 1; x++) {
      int value = pixels[y * kDetailSide + x];
      total += abs(value - pixels[y * kDetailSide + x + 1]) + abs(value - pixels[(y + 1) * kDetailSide + x]);
    }
  }
  CGFloat detail = (CGFloat)total / (2.0 * (kDetailSide - 1) * (kDetailSide - 1));
  objc_setAssociatedObject(image, &kImageDetailKey, @(detail), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  return detail;
}

// Gallery pages sit side by side, so a page's position gives its index in the post.
static NSUInteger pageIndexOfImageView(UIView *imageView) {
  for (UIView *view = imageView; view; view = view.superview) {
    if ([NSStringFromClass(view.class) containsString:@"RPLCarouselPage"]) {
      CGFloat width = CGRectGetWidth(view.bounds);
      return width > 0 ? (NSUInteger)MAX(0, lround(CGRectGetMinX(view.frame) / width)) : 0;
    }
  }
  return 0;
}

static void revealImagesIn(UIView *media, UILabel *badge) {
  NSArray<NSString *> *addresses = objc_getAssociatedObject(badge, &kClearAddressesKey);
  if (addresses.count == 0) return;
  badge.hidden = YES;
  __weak UIView *weakMedia = media;
  for (NSUInteger index = 0; index < addresses.count; index++) {
    NSString *address = addresses[index];
    NSURL *url = [NSURL URLWithString:address];
    if (!url) continue;
    [[NSURLSession.sharedSession
          dataTaskWithURL:url
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
          UIImage *image = data ? [UIImage imageWithData:data] : nil;
          logReveal(index, image != nil);
          dispatch_async(dispatch_get_main_queue(), ^{
            if (!image) {
              badge.hidden = NO;
              return;
            }
            [revealedImages setObject:image forKey:address];
            NSMutableArray<UIImageView *> *imageViews = [NSMutableArray array];
            collectImageViews(weakMedia, imageViews, 0);
            for (UIImageView *imageView in imageViews)
              if (pageIndexOfImageView(imageView) == index) imageView.image = image;
          });
        }] resume];
  }
}

@interface RedditLegacyBadgeTarget : NSObject
- (void)badgeTapped:(UITapGestureRecognizer *)recognizer;
@end

@implementation RedditLegacyBadgeTarget
- (void)badgeTapped:(UITapGestureRecognizer *)recognizer {
  UILabel *badge = (UILabel *)recognizer.view;
  logTap();
  if (badge.superview) revealImagesIn(badge.superview, badge);
}
@end

static BOOL hasAdultTag(UIView *view, int depth) {
  if (depth > 12 || isBlurredMediaContainer(view)) return NO;
  if ([view isKindOfClass:UILabel.class] && [((UILabel *)view).text containsString:@"18+"] &&
      [NSStringFromClass(view.superview.class) containsString:@"ContentTag"])
    return YES;
  for (UIView *child in view.subviews)
    if (hasAdultTag(child, depth + 1)) return YES;
  return NO;
}

static void refreshAdultBadges(UIView *stack);

// An image can change without a new layout pass, for example after the app clears it, so a badge
// on screen keeps checking what is under it.
static void scheduleBadgeRecheck(UILabel *badge) {
  if (objc_getAssociatedObject(badge, &kRecheckPendingKey)) return;
  objc_setAssociatedObject(badge, &kRecheckPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  __weak UILabel *weakBadge = badge;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    UILabel *strongBadge = weakBadge;
    if (!strongBadge) return;
    objc_setAssociatedObject(strongBadge, &kRecheckPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!strongBadge.window || strongBadge.hidden) return;
    Class feedStack = NSClassFromString(@"FeedKit_Slices.FeedStackSliceView");
    UIView *view = strongBadge;
    while (view && ![view isKindOfClass:feedStack]) view = view.superview;
    if (view) refreshAdultBadges(view);
  });
}

// Blurred clips play under the blur with nothing to see, so they stay paused behind the badge.
static void pausePlayersIn(UIView *view, int depth) {
  if (depth > 10) return;
  Class playerLayerClass = NSClassFromString(@"AVPlayerLayer");
  if ([view.layer isKindOfClass:playerLayerClass]) {
    AVPlayer *player = ((AVPlayerLayer *)view.layer).player;
    if (player.rate != 0) [player pause];
  }
  for (UIView *child in view.subviews) pausePlayersIn(child, depth + 1);
}

// The badge shows only over a post's image that really looks blurred, so one the app already
// cleared loses it. With known clear addresses a tap clears the image in place; otherwise touches
// pass through to the app's own handler.
static void updateAdultBadge(UIView *media, BOOL isTagged, NSArray<NSString *> *addresses) {
  static RedditLegacyBadgeTarget *target;
  if (!target) target = [RedditLegacyBadgeTarget new];
  NSMutableArray<UIImageView *> *imageViews = [NSMutableArray array];
  collectImageViews(media, imageViews, 0);
  BOOL isBlurred = NO;
  CGFloat lowestDetail = CGFLOAT_MAX;
  for (UIImageView *imageView in imageViews) {
    NSUInteger index = pageIndexOfImageView(imageView);
    UIImage *revealed = index < addresses.count ? [revealedImages objectForKey:addresses[index]] : nil;
    if (revealed) {
      if (imageView.image != revealed) imageView.image = revealed;
      continue;
    }
    if (!imageView.image) continue;
    CGFloat detail = imageDetail(imageView.image);
    lowestDetail = MIN(lowestDetail, detail);
    if (detail < kBlurredDetailLimit) isBlurred = YES;
  }
  if (lowestDetail < CGFLOAT_MAX) logDetail(media, lowestDetail, isTagged);
  BOOL show = isTagged && isBlurred;
  UILabel *badge = (UILabel *)[media viewWithTag:kBadgeTag];
  if (!show) {
    badge.hidden = YES;
    return;
  }
  if (!badge) {
    badge = [UILabel new];
    badge.tag = kBadgeTag;
    BOOL isSpanish = [NSLocale.preferredLanguages.firstObject hasPrefix:@"es"];
    badge.text = isSpanish ? @"Ver contenido 18+" : @"View 18+ content";
    badge.font = [UIFont boldSystemFontOfSize:13];
    badge.textColor = UIColor.whiteColor;
    badge.textAlignment = NSTextAlignmentCenter;
    badge.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
    badge.clipsToBounds = YES;
    [badge addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:target
                                                                        action:@selector(badgeTapped:)]];
    CGSize size = [badge sizeThatFits:CGSizeZero];
    CGFloat height = size.height + 14;
    badge.layer.cornerRadius = height / 2;
    // Images finish loading after this runs, so the badge must stay above views added later.
    badge.layer.zPosition = 1000;
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    [media addSubview:badge];
    // The container has no final size yet at this point, so its center is left to Auto Layout.
    [NSLayoutConstraint activateConstraints:@[
      [badge.widthAnchor constraintEqualToConstant:size.width + 24],
      [badge.heightAnchor constraintEqualToConstant:height],
      [badge.centerXAnchor constraintEqualToAnchor:media.centerXAnchor],
      [badge.centerYAnchor constraintEqualToAnchor:media.centerYAnchor],
    ]];
  }
  badge.hidden = NO;
  objc_setAssociatedObject(badge, &kClearAddressesKey, addresses, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  badge.userInteractionEnabled = addresses.count > 0;
  scheduleBadgeRecheck(badge);
  if ([NSStringFromClass(media.class) containsString:@"LegacyVideo"]) pausePlayersIn(media, 0);
  logBadgeState(media, badge, addresses.count, lowestDetail);
}

static void updateAdultBadges(UIView *view, BOOL isTagged, NSArray<NSString *> *addresses, int depth) {
  if (depth > 6) return;
  if (isBlurredMediaContainer(view)) {
    updateAdultBadge(view, isTagged, addresses);
    return;
  }
  for (UIView *child in view.subviews) updateAdultBadges(child, isTagged, addresses, depth + 1);
}

// Titles are not always drawn by a UILabel, so any view that exposes its text is considered.
static NSString *textOfView(UIView *view) {
  id text = [view respondsToSelector:@selector(text)] ? [(id)view text] : nil;
  if ([text isKindOfClass:NSString.class] && [text length]) return text;
  id attributed = [view respondsToSelector:@selector(attributedText)] ? [(id)view attributedText] : nil;
  if ([attributed isKindOfClass:NSAttributedString.class]) return [attributed string];
  return nil;
}

// Finds the clear image addresses by matching the post's title on screen to the feed data.
static NSArray<NSString *> *clearAddressesInStack(UIView *view, int depth) {
  if (depth > 12 || isBlurredMediaContainer(view)) return nil;
  NSString *text = textOfView(view);
  if (text.length) {
    NSString *title = normalizedTitle(text);
    @synchronized(clearAddressesByTitle) {
      NSArray<NSString *> *found = clearAddressesByTitle[title];
      if (found) return found;
    }
  }
  for (UIView *child in view.subviews) {
    NSArray<NSString *> *found = clearAddressesInStack(child, depth + 1);
    if (found) return found;
  }
  return nil;
}

// The feed captures touches before they reach the badge, so it is handed them directly.
static UILabel *tappableBadgeAtPoint(UIView *view, UIView *stack, CGPoint point, int depth) {
  if (depth > 6) return nil;
  if (isBlurredMediaContainer(view)) {
    UILabel *badge = (UILabel *)[view viewWithTag:kBadgeTag];
    if (badge && !badge.hidden && badge.userInteractionEnabled &&
        [badge pointInside:[stack convertPoint:point toView:badge] withEvent:nil])
      return badge;
    return nil;
  }
  for (UIView *child in view.subviews) {
    UILabel *found = tappableBadgeAtPoint(child, stack, point, depth + 1);
    if (found) return found;
  }
  return nil;
}

static void refreshAdultBadges(UIView *stack) {
  updateAdultBadges(stack, blurEnabled && hasAdultTag(stack, 0), clearAddressesInStack(stack, 0), 0);
}

static BOOL isZeroOnline(NSString *text) {
  return text.length > 0 && text.length <= 60 && matches(zeroOnlineText, text);
}

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
  logAvatarRequest(request.URL);
  logRequestVersion(request, self);
  if (!handler || !shouldWrap(request.URL.host)) return %orig;
  probeOnlineCount(request);
  NSString *operation = operationName(request);
  void (^wrapped)(NSData *, NSURLResponse *, NSError *) =
      ^(NSData *data, NSURLResponse *response, NSError *error) {
        logResult(request, operation, response, error);
        handler(error ? data : processResponse(request, operation, data), response, error);
      };
  return %orig(requestForGameServers(request), wrapped);
}
%end

%hook UILabel
// Reddit no longer sends an online count, so the app always shows zero. Emptying the text
// also survives the app toggling the label's visibility, and reused cells simply get new text.
- (void)setText:(NSString *)text {
  logLabel(self, text);
  %orig(isZeroOnline(text) ? @"" : text);
}
- (void)setAttributedText:(NSAttributedString *)text {
  logLabel(self, text.string);
  %orig(isZeroOnline(text.string) ? [[NSAttributedString alloc] initWithString:@""] : text);
}
%end

@interface FeedStackSliceView : UIView
@end

%group AdultBadge
%hook FeedStackSliceView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
  UIView *stack = (UIView *)self;
  UILabel *badge = tappableBadgeAtPoint(stack, stack, point, 0);
  return badge ?: %orig;
}
- (void)layoutSubviews {
  %orig;
  UIView *stack = (UIView *)self;
  refreshAdultBadges(stack);
  // The 18+ tag and the image address arrive after this layout pass, so they are checked again.
  __weak UIView *weakStack = stack;
  for (NSNumber *delay in @[ @0, @0.5, @1.5, @3 ]) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      UIView *strongStack = weakStack;
      if (strongStack) refreshAdultBadges(strongStack);
    });
  }
}
%end
%end

@interface CarouselPageView : UIView
@end

%group GalleryPages
%hook CarouselPageView
- (void)layoutSubviews {
  %orig;
  UIView *view = (UIView *)self;
  Class feedStack = NSClassFromString(@"FeedKit_Slices.FeedStackSliceView");
  while (view && ![view isKindOfClass:feedStack]) view = view.superview;
  if (view) refreshAdultBadges(view);
}
%end
%end

// Only activated in development builds.
%group Diagnostics
%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
  logAvatarRequest(request.URL);
  logRequestVersion(request, self);
  return %orig;
}
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url {
  logAvatarRequest(url);
  return %orig;
}
%end

%hook WKWebView
- (WKNavigation *)loadRequest:(NSURLRequest *)request {
  logWebView(request.URL);
  logWebViewNotice(self);
  return %orig;
}
- (WKNavigation *)loadHTMLString:(NSString *)html baseURL:(NSURL *)baseURL {
  logWebView(baseURL);
  logWebViewNotice(self);
  return %orig;
}
%end

%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
  %orig;
  logScreen(self);
}
%end
%end

%ctor {
  clearAddressesByTitle = [NSMutableDictionary dictionary];
  revealedImages = [NSCache new];
  zeroOnlineText = [NSRegularExpression
      regularExpressionWithPattern:@"^[\\s•·]*(0|no|sin|ning[uú]n)\\s+((users?|usuarios?|personas?)\\s+)?"
                                   @"(online|conectad[oa]s?|en l[ií]nea)[\\s•·]*$"
                           options:NSRegularExpressionCaseInsensitive
                             error:nil];

#ifdef RL_DEV
  NSString *documents =
      NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  NSString *log = [documents stringByAppendingPathComponent:@"RedditLegacy.log"];
  [NSFileManager.defaultManager removeItemAtPath:log error:nil];
  startDiagnostics(log);
  %init(Diagnostics);
#endif
  Class feedStack = NSClassFromString(@"FeedKit_Slices.FeedStackSliceView");
  if (feedStack) {
    %init(AdultBadge, FeedStackSliceView = feedStack);
  }
  logFeedStackFound(feedStack != nil);
  Class carouselPage = NSClassFromString(@"RPLComponents_Carousel.RPLCarouselPage");
  if (carouselPage) {
    %init(GalleryPages, CarouselPageView = carouselPage);
  }
  %init;
}
