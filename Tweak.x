// RedditLegacy: keeps the official Reddit app usable on iOS 15.
//  - Removes the NSFW label from subreddits in GraphQL responses (banner); posts keep theirs (blur).
//  - Blanks the "0 online" label, a count the server no longer provides.
//  - Removes ads from GraphQL responses.
//  - Reports a current version to Reddit's game servers.
//  - Blurs all 18+ feed media with a "View 18+ content" cover; a tap reveals that post in place.
//  - The "more actions" sheet of a post with a clip offers to save it to Photos.
//
// Development builds (without RELEASE=1) also write and upload a diagnostics log: field names,
// numbers, booleans, API error messages, screen classes and short on-screen labels matching
// keywords. Tokens, headers and string values from responses are never stored.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>

static const NSUInteger kMaxJSONBytes = 20 * 1024 * 1024;
static const int kMaxDepth = 64;
static const NSInteger kCoverTag = 0x52454444;
static const NSInteger kDownloadRowTag = 0x52454445;
static BOOL blurEnabled = YES;
static const CGFloat kMinMediaWidth = 100;
static const CGFloat kMinThumbnailWidth = 40;
static NSMutableDictionary<NSString *, NSArray<NSString *> *> *clearAddressesByTitle;
static NSCache<NSString *, UIImage *> *revealedImages;
static NSMutableSet<NSString *> *revealedPosts;
static NSMutableDictionary<NSString *, NSDictionary *> *clipsByTitle;
static char kRowClipKey;
static char kRowAnchorKey;
static char kRowHeightKey;
static __weak UIView *lastTouchedStack;
static char kPostKey;
static char kFeedMediaKey;
static NSString *const kGameClientVersion = @"2026.44.0";
static NSString *const kGameClientBuildNumber = @"700000";
static NSString *const kGameClientBuild = @"2026.44.0.700000";

static NSRegularExpression *zeroOnlineText;
static NSRegularExpression *zeroCountText;

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
          for (NSString *key in about) {
            NSString *lower = key.lowercaseString;
            if ([lower containsString:@"active"] || [lower containsString:@"online"] ||
                [lower containsString:@"visit"] || [lower containsString:@"weekly"] ||
                [lower containsString:@"contribut"])
              writeLog([NSString stringWithFormat:@"ABOUT %@=%@", key, about[key]]);
          }
        }] resume];
}

static void collectActiveCounts(id object, NSMutableSet<NSString *> *found, int depth) {
  if (depth > 12) return;
  if ([object isKindOfClass:NSDictionary.class]) {
    for (NSString *key in (NSDictionary *)object) {
      id value = object[key];
      NSString *lower = key.lowercaseString;
      if (([lower containsString:@"active"] || [lower containsString:@"online"] || [lower containsString:@"presence"]) &&
          [value isKindOfClass:NSNumber.class])
        [found addObject:[NSString stringWithFormat:@"%@=%@", key, value]];
      collectActiveCounts(value, found, depth + 1);
    }
  } else if ([object isKindOfClass:NSArray.class]) {
    for (id item in (NSArray *)object) collectActiveCounts(item, found, depth + 1);
  }
}

static void runActiveCountTest(NSString *label, NSURLRequest *request) {
  [[NSURLSession.sharedSession
      dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
          NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
                                 ? ((NSHTTPURLResponse *)response).statusCode
                                 : 0;
          id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
          NSMutableSet<NSString *> *found = [NSMutableSet set];
          collectActiveCounts(json, found, 0);
          NSString *errors = @"";
          if ([json isKindOfClass:NSDictionary.class] && [json[@"errors"] isKindOfClass:NSArray.class]) {
            id first = [json[@"errors"] firstObject];
            if ([first isKindOfClass:NSDictionary.class] && [first[@"message"] isKindOfClass:NSString.class]) errors = first[@"message"];
          }
          writeLog([NSString stringWithFormat:@"ACTIVETEST %@ status=%ld bytes=%lu values=%@ error=%@", label, (long)status,
                                              (unsigned long)data.length, [found.allObjects componentsJoinedByString:@","],
                                              errors.length > 120 ? [errors substringToIndex:120] : errors]);
        }] resume];
}

// Checks whether the server hides the online count from old app versions: repeats the app's own
// request as a current version, and tries the query web clients use. The token only goes to
// gql-fed.reddit.com, and only numbers named active, online or presence are logged.
static void testActiveCountSources(NSURLRequest *source, NSString *operation) {
  if (![operation isEqualToString:@"SubredditsForNames"]) return;
  static atomic_flag started = ATOMIC_FLAG_INIT;
  if (atomic_flag_test_and_set(&started)) return;
  NSString *agent = [NSString stringWithFormat:@"Reddit/Version %@/Build %@/iOS Version 16.7.12 (Build 20H364)",
                                               kGameClientVersion, kGameClientBuildNumber];
  NSString *clientVersion = [NSString stringWithFormat:@"%@-%@", kGameClientVersion, kGameClientBuildNumber];

  NSMutableURLRequest *current = [source mutableCopy];
  [current setValue:agent forHTTPHeaderField:@"User-Agent"];
  [current setValue:clientVersion forHTTPHeaderField:@"apollographql-client-version"];
  runActiveCountTest(@"sameQueryCurrentVersion", current);

  runActiveCountTest(@"sameQueryRealVersion", [source copy]);

  NSMutableURLRequest *web = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://gql-fed.reddit.com/?SubredditInfoByName"]];
  web.HTTPMethod = @"POST";
  [web setValue:[source valueForHTTPHeaderField:@"Authorization"] forHTTPHeaderField:@"Authorization"];
  [web setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  [web setValue:agent forHTTPHeaderField:@"User-Agent"];
  NSDictionary *body = @{
    @"operationName" : @"SubredditInfoByName",
    @"variables" : @{
      @"subredditName" : @"AskReddit",
      @"filterGated" : @NO,
      @"includeRecapFields" : @NO,
      @"includeWelcomePage" : @NO,
      @"includeDevvitData" : @NO
    },
    @"extensions" : @{
      @"persistedQuery" : @{
        @"version" : @1,
        @"sha256Hash" : @"6b9c1679e69097e1c6df364adc11183afe6e2b6545dd1c0c1cc8f7490448c3e5"
      }
    }
  };
  web.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
  runActiveCountTest(@"webQueryCurrentVersion", web);
}

static NSString *describeValue(id value) {
  if ([value isKindOfClass:NSNumber.class]) return [value description];
  if ([value isKindOfClass:NSString.class])
    return [NSString stringWithFormat:@"<string:%lu>", (unsigned long)[value length]];
  if (value == NSNull.null) return @"null";
  return nil;
}

static void logInitialRender(NSString *value);

static void logField(NSString *key, NSString *keyPath, id value, NSString *operation) {
  if ([value isKindOfClass:NSString.class]) {
    BOOL isGameVersion = [keyPath containsString:@"devvit"] && [key isEqualToString:@"version"];
    if ((matches(versionKey, key) || isGameVersion) && [value length] <= 40)
      writeLog([NSString stringWithFormat:@"VERSION %@ %@=%@", operation, keyPath, value]);
    if ([key isEqualToString:@"initialRender"]) logInitialRender(value);
    if ([key isEqualToString:@"webViewBaseUrl"])
      writeLog([NSString stringWithFormat:@"GAMEWEB %@", [NSURL URLWithString:value].host]);
    if (matches(upgradeText, value))
      writeLog([NSString stringWithFormat:@"UPGRADE %@ %@", operation, keyPath]);
    // Weekly visitor counts appear in search, so this shows which response and field carry them.
    if ([value length] <= 60 && [value rangeOfString:@"visit" options:NSCaseInsensitiveSearch].location != NSNotFound)
      writeLog([NSString stringWithFormat:@"VISITS %@ %@=%@", operation, keyPath, value]);
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

static void logCoverState(UIView *media, BOOL covered, NSUInteger addresses) {
  NSString *name = NSStringFromClass(media.class);
  NSString *kind = [name containsString:@"Carousel"] ? @"carousel"
                   : [name containsString:@"Video"]  ? @"video"
                                                     : @"image";
  NSMutableArray<NSString *> *sizes = [NSMutableArray array];
  for (UIView *child in media.subviews) {
    for (UIView *inner in child.subviews)
      [sizes addObject:[NSString stringWithFormat:@"%.0fx%.0f@%.0f", inner.bounds.size.width, inner.bounds.size.height, inner.frame.origin.x]];
  }
  writeLog([NSString stringWithFormat:@"COVER %@ covered=%d addresses=%lu media=%.0f inner=%@", kind, covered,
                                      (unsigned long)addresses, media.bounds.size.width,
                                      [sizes componentsJoinedByString:@","]]);
}

static void logTap(void) { writeLog(@"TAP cover"); }

static void logGameBundleNotice(NSData *data);

static BOOL dataHasUpgradeNotice(NSData *data) {
  for (NSString *word in @[ @"latest version", @"Uh oh", @"upgrade your app" ]) {
    if ([data rangeOfData:[word dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, data.length)].location != NSNotFound)
      return YES;
  }
  return NO;
}

// Shows whether the game servers send the notice, or the app decides it by itself.
static void logGameResponse(NSURLRequest *request, NSURLResponse *response, NSData *data) {
  if (![request.URL.host containsString:@"devvit"]) return;
  NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
  writeLog([NSString stringWithFormat:@"GAMERESP path=%@ status=%ld type=%@ encoding=%@ grpc=%@ bytes=%lu notice=%d",
                                      request.URL.lastPathComponent, (long)http.statusCode,
                                      [http valueForHTTPHeaderField:@"Content-Type"],
                                      [http valueForHTTPHeaderField:@"Content-Encoding"],
                                      [http valueForHTTPHeaderField:@"grpc-status"], (unsigned long)data.length,
                                      dataHasUpgradeNotice(data)]);
  if (dataHasUpgradeNotice(data)) logGameBundleNotice(data);
}

static void logGameBundleNotice(NSData *data) {
  static NSUInteger logged = 0;
  if (logged >= 2) return;
  NSString *code = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (!code) {
    writeLog(@"GAMECODE not utf8");
    return;
  }
  NSRange notice = [code rangeOfString:@"requires the latest version"];
  if (notice.location == NSNotFound) notice = [code rangeOfString:@"Uh oh"];
  if (notice.location == NSNotFound) return;
  logged++;
  writeLog([NSString stringWithFormat:@"GAMECODE length=%lu at=%lu start=%@", (unsigned long)code.length,
                                      (unsigned long)notice.location, [code substringToIndex:MIN(200, code.length)]]);
  NSUInteger start = notice.location > 4000 ? notice.location - 4000 : 0;
  NSUInteger end = MIN(code.length, notice.location + 1200);
  NSString *around = [code substringWithRange:NSMakeRange(start, end - start)];
  for (NSUInteger offset = 0; offset < around.length; offset += 900) {
    writeLog([NSString stringWithFormat:@"GAMECODE[%lu] %@", (unsigned long)(offset / 900),
                                        [around substringWithRange:NSMakeRange(offset, MIN(900, around.length - offset))]]);
  }
}

// Highlight cards draw their NSFW mark without a label, so their views are listed once.
static void logHighlightCard(UIView *view, int depth) {
  if (depth > 5) return;
  writeLog([NSString stringWithFormat:@"HIGHLIGHT depth=%d %@ %.0fx%.0f hidden=%d layers=%lu", depth,
                                      NSStringFromClass(view.class), view.bounds.size.width, view.bounds.size.height,
                                      view.hidden, (unsigned long)view.layer.sublayers.count]);
  for (UIView *child in view.subviews) logHighlightCard(child, depth + 1);
}

static void logInitialRender(NSString *value) {
  NSData *decoded = [[NSData alloc] initWithBase64EncodedString:value options:NSDataBase64DecodingIgnoreUnknownCharacters];
  writeLog([NSString stringWithFormat:@"GAMERENDER chars=%lu decoded=%lu noticeRaw=%d noticeDecoded=%d", (unsigned long)value.length,
                                      (unsigned long)decoded.length,
                                      dataHasUpgradeNotice([value dataUsingEncoding:NSUTF8StringEncoding]),
                                      decoded ? dataHasUpgradeNotice(decoded) : 0]);
}

static void logDownload(NSString *text) { writeLog([@"DOWNLOAD " stringByAppendingString:text]); }

static void logClipBlurHidden(void) { writeLog(@"CLIPBLUR hidden"); }

static void logRevealApplied(NSUInteger page, NSUInteger views, NSUInteger updated) {
  writeLog([NSString stringWithFormat:@"REVEALSET page=%lu views=%lu updated=%lu", (unsigned long)page,
                                      (unsigned long)views, (unsigned long)updated]);
}

static void logReveal(NSUInteger index, BOOL decoded) {
  writeLog([NSString stringWithFormat:@"REVEAL page=%lu decoded=%d", (unsigned long)index, decoded]);
}

static void logFeedStackFound(BOOL found) {
  writeLog([NSString stringWithFormat:@"BADGE feedStack=%d", found]);
}

static void logAd(NSString *path, NSString *operation, NSString *kind) {
  writeLog([NSString stringWithFormat:@"AD %@ %@ %@", operation, path, kind]);
}

// Records the shape of feed cells and blurred media as the server sent them. Strings are only
// kept for type-like fields, so titles and usernames stay out of the log.
static NSString *describeAddress(id value) {
  if (![value isKindOfClass:NSString.class]) return @"-";
  NSURL *url = [NSURL URLWithString:value];
  return [NSString stringWithFormat:@"%@/.%@", url.host ?: @"?", url.pathExtension ?: @""];
}

static void collectAddressesOf(id object, NSString *path, NSMutableArray<NSString *> *found, int depth) {
  if (depth > 6) return;
  if ([object isKindOfClass:NSDictionary.class]) {
    for (NSString *key in (NSDictionary *)object)
      collectAddressesOf(object[key], [path stringByAppendingFormat:@".%@", key], found, depth + 1);
  } else if ([object isKindOfClass:NSArray.class]) {
    id first = [(NSArray *)object firstObject];
    if (first) collectAddressesOf(first, path, found, depth + 1);
  } else if ([object isKindOfClass:NSString.class] && [object hasPrefix:@"http"]) {
    [found addObject:[NSString stringWithFormat:@"%@=%@", path, describeAddress(object)]];
  }
}

// Shows which addresses a clip offers, to find one that can be saved as a file.
static void logVideoCell(NSDictionary *cell) {
  NSMutableArray<NSString *> *addresses = [NSMutableArray array];
  collectAddressesOf(cell, @"", addresses, 0);
  writeLog([NSString stringWithFormat:@"VIDEOSRC gif=%@ type=%@ %@", cell[@"isGif"], cell[@"type"],
                                      [addresses componentsJoinedByString:@" "]]);
}

static void logPresented(UIViewController *controller) {
  writeLog([NSString stringWithFormat:@"PRESENT %@", NSStringFromClass(controller.class)]);
  if ([controller isKindOfClass:UIAlertController.class]) {
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (UIAlertAction *action in ((UIAlertController *)controller).actions)
      [titles addObject:action.title ?: @"-"];
    writeLog([NSString stringWithFormat:@"ALERTMENU %@", [titles componentsJoinedByString:@" | "]]);
  }
}

static void logContextMenu(id delegate) {
  writeLog([NSString stringWithFormat:@"CONTEXTMENU delegate=%@", NSStringFromClass([delegate class])]);
}

static void logStructure(NSDictionary *dict, NSString *path, NSString *operation) {
  if ([dict[@"__typename"] isEqual:@"LegacyVideoCell"]) logVideoCell(dict);
  BOOL isMedia = dict[@"isObfuscated"] != nil || [path containsString:@"highlightedPosts"];
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
static void logHighlightCard(UIView *view, int depth);

static void logVisibleText(UIView *view, int depth) {
  if (depth > 40) return;
  NSString *className = NSStringFromClass(view.class);
  if ([className containsString:@"HighlightThumbnailView"]) logHighlightCard(view, 0);
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
                                   @"uh oh|upgrade|latest version|actualiz|guardar|save|descarg|download|compartir|share|copiar|copy|"
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
static inline void logCoverState(UIView *media, BOOL covered, NSUInteger addresses) {}
static inline void logReveal(NSUInteger index, BOOL decoded) {}
static inline void logTap(void) {}
static inline void logGameResponse(NSURLRequest *request, NSURLResponse *response, NSData *data) {}
static inline void logDownload(NSString *text) {}
static inline void logPresented(UIViewController *controller) {}
static inline void logContextMenu(id delegate) {}
static inline void logClipBlurHidden(void) {}
static inline void logRevealApplied(NSUInteger page, NSUInteger views, NSUInteger updated) {}
static inline void testActiveCountSources(NSURLRequest *source, NSString *operation) {}
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
  // Only media the server really marked as blurred needs its clear image fetched on reveal.
  NSString *clear = source[@"path"];
  if ([source[@"isObfuscated"] isEqual:@YES] && [clear isKindOfClass:NSString.class] && clear.length)
    [addresses addObject:clear];
}

// A feed post arrives as a group of cells: remembers its clear images under its title. These stay
// in memory only, and are what lets a tap show the image inside the feed.
static void rememberPostImages(NSDictionary *group) {
  NSArray *cells = group[@"cells"];
  if (![cells isKindOfClass:NSArray.class]) return;
  NSString *title = nil;
  NSDictionary *clip = nil;
  NSMutableArray<NSString *> *addresses = [NSMutableArray array];
  NSMutableArray *allCells = [cells mutableCopy];
  for (NSDictionary *cell in cells) {
    id inner = [cell isKindOfClass:NSDictionary.class] ? cell[@"innerPost"] : nil;
    if ([inner isKindOfClass:NSDictionary.class] && [inner[@"cells"] isKindOfClass:NSArray.class])
      [allCells addObjectsFromArray:inner[@"cells"]];
  }
  for (NSDictionary *cell in allCells) {
    if (![cell isKindOfClass:NSDictionary.class]) continue;
    NSString *type = cell[@"__typename"];
    if ([type isEqual:@"LegacyVideoCell"] && !clip && [cell[@"media"] isKindOfClass:NSDictionary.class] &&
        [cell[@"media"][@"path"] isKindOfClass:NSString.class])
      clip = @{ @"path" : cell[@"media"][@"path"], @"isGif" : @([cell[@"isGif"] boolValue]) };
    if ([type isEqual:@"TitleCell"] && [cell[@"title"] isKindOfClass:NSString.class]) title = cell[@"title"];
    if ([type isEqual:@"ImageCell"]) addClearAddress(cell[@"media"], addresses);
    if ([type isEqual:@"GalleryCell"] && [cell[@"pages"] isKindOfClass:NSArray.class]) {
      for (NSDictionary *page in cell[@"pages"])
        if ([page isKindOfClass:NSDictionary.class]) addClearAddress(page[@"image"], addresses);
    }
  }
  if (title.length == 0) return;
  NSString *key = normalizedTitle(title);
  @synchronized(clearAddressesByTitle) {
    clearAddressesByTitle[key] = addresses;
    if (clip) clipsByTitle[key] = clip;
  }
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
    // Highlight cards show an NSFW mark from their thumbnail's own flag, which can be set for posts
    // that aren't NSFW. The post's flag is the one that counts.
    NSMutableDictionary *thumbnail = dict[@"thumbnailV2"];
    if ([thumbnail isKindOfClass:NSMutableDictionary.class] && [dict[@"isNsfw"] isEqual:@NO] &&
        [thumbnail[@"isObfuscatedDefault"] isEqual:@YES]) {
      thumbnail[@"isObfuscatedDefault"] = @NO;
      changed = YES;
    }
    // Clips are covered on screen instead. Left marked, the app keeps its own blur over the video,
    // which stays after the cover is removed.
    if ([dict[@"__typename"] isEqual:@"LegacyVideoCell"]) {
      for (NSString *key in @[ @"media", @"preview" ]) {
        NSMutableDictionary *source = dict[key];
        if ([source isKindOfClass:NSMutableDictionary.class] && [source[@"isObfuscated"] isEqual:@YES]) {
          source[@"isObfuscated"] = @NO;
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

static void collectImageViews(UIView *view, CGFloat minWidth, NSMutableArray<UIImageView *> *found, int depth) {
  if (depth > 14) return;
  if ([view isKindOfClass:UIImageView.class] && CGRectGetWidth(view.bounds) >= minWidth)
    [found addObject:(UIImageView *)view];
  for (UIView *child in view.subviews) collectImageViews(child, minWidth, found, depth + 1);
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

static BOOL hasAdultTag(UIView *view, int depth) {
  if (depth > 12 || isBlurredMediaContainer(view)) return NO;
  if ([view isKindOfClass:UILabel.class] && [((UILabel *)view).text containsString:@"18+"] &&
      [NSStringFromClass(view.superview.class) containsString:@"ContentTag"])
    return YES;
  for (UIView *child in view.subviews)
    if (hasAdultTag(child, depth + 1)) return YES;
  return NO;
}

static AVPlayerLayer *playerLayerIn(CALayer *layer, int depth) {
  Class playerLayerClass = NSClassFromString(@"AVPlayerLayer");
  if ([layer isKindOfClass:playerLayerClass]) return (AVPlayerLayer *)layer;
  if (depth > 3) return nil;
  for (CALayer *sublayer in layer.sublayers) {
    AVPlayerLayer *found = playerLayerIn(sublayer, depth + 1);
    if (found) return found;
  }
  return nil;
}

// A clip's player draws over everything below it, so it stays hidden and paused while covered,
// and starts once its post is revealed.
static void setClipBlocked(UIView *view, BOOL blocked, int depth) {
  if (depth > 10) return;
  if ([NSStringFromClass(view.class) containsString:@"PlayerLayerView"]) {
    BOOL wasBlocked = view.hidden;
    view.hidden = blocked;
    AVPlayer *player = playerLayerIn(view.layer, 0).player;
    if (blocked && player.rate != 0) [player pause];
    if (!blocked && wasBlocked) [player play];
    return;
  }
  for (UIView *child in view.subviews) setClipBlocked(child, blocked, depth + 1);
}

// The app can also draw its own blur across a clip. The cover already handles blurring, so that
// one is hidden; small blurred buttons in the player controls are left alone.
static void hideNativeClipBlur(UIView *view, UIView *media, int depth) {
  if (depth > 10 || view.tag == kCoverTag) return;
  if ([view isKindOfClass:UIVisualEffectView.class]) {
    if (CGRectGetWidth(view.bounds) >= CGRectGetWidth(media.bounds) * 0.8) {
      view.hidden = YES;
      logClipBlurHidden();
    }
    return;
  }
  for (UIView *child in view.subviews) hideNativeClipBlur(child, media, depth + 1);
}

// Titles are not always drawn by a UILabel, so any view that exposes its text is considered.
static NSString *textOfView(UIView *view) {
  id text = [view respondsToSelector:@selector(text)] ? [(id)view text] : nil;
  if ([text isKindOfClass:NSString.class] && [text length]) return text;
  id attributed = [view respondsToSelector:@selector(attributedText)] ? [(id)view attributedText] : nil;
  if ([attributed isKindOfClass:NSAttributedString.class]) return [attributed string];
  return nil;
}

// A post is identified by its title from the feed data. If it isn't found, the longest text in
// the post stands in, so a revealed post still stays revealed while scrolling.
static NSString *findPostKey(UIView *view, NSString **longest, int depth) {
  if (depth > 12 || isBlurredMediaContainer(view)) return nil;
  NSString *text = textOfView(view);
  if (text.length) {
    NSString *title = normalizedTitle(text);
    @synchronized(clearAddressesByTitle) {
      if (clearAddressesByTitle[title]) return title;
    }
    if (title.length > (*longest).length) *longest = title;
  }
  for (UIView *child in view.subviews) {
    NSString *found = findPostKey(child, longest, depth + 1);
    if (found) return found;
  }
  return nil;
}

static NSArray<NSString *> *clearAddressesForPost(NSString *key) {
  if (!key) return nil;
  @synchronized(clearAddressesByTitle) {
    return clearAddressesByTitle[key];
  }
}

static BOOL isPostRevealed(NSString *key) {
  if (!key) return NO;
  @synchronized(revealedPosts) {
    return [revealedPosts containsObject:key];
  }
}

static void refreshAdultBadges(UIView *stack);

static void refreshFeedStackOf(UIView *view) {
  Class feedStack = NSClassFromString(@"FeedKit_Slices.FeedStackSliceView");
  while (view && ![view isKindOfClass:feedStack]) view = view.superview;
  if (view) refreshAdultBadges(view);
}

// When the server sent a blurred copy, the image view is showing it, so the clear image has to be
// fetched. Otherwise removing the cover is enough, and the fetch is skipped.
static void fetchClearImages(UIView *host, NSString *key) {
  NSArray<NSString *> *addresses = clearAddressesForPost(key);
  __weak UIView *weakHost = host;
  for (NSUInteger index = 0; index < addresses.count; index++) {
    NSString *address = addresses[index];
    NSURL *url = [NSURL URLWithString:address];
    if (!url || [revealedImages objectForKey:address]) continue;
    [[NSURLSession.sharedSession
          dataTaskWithURL:url
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
          UIImage *image = data ? [UIImage imageWithData:data] : nil;
          logReveal(index, image != nil);
          if (!image) return;
          dispatch_async(dispatch_get_main_queue(), ^{
            [revealedImages setObject:image forKey:address];
            UIView *strongHost = weakHost;
            if (strongHost) refreshFeedStackOf(strongHost);
          });
        }] resume];
  }
}

// The language the app itself is running in, which can differ from the device's.
static NSString *appLanguageKey(NSDictionary *available) {
  NSString *language = NSBundle.mainBundle.preferredLocalizations.firstObject ?: @"en";
  if (available[language]) return language;
  if ([language hasPrefix:@"zh"]) {
    BOOL isTraditional = [language containsString:@"Hant"] || [language containsString:@"TW"] || [language containsString:@"HK"];
    return isTraditional ? @"zh-Hant" : @"zh-Hans";
  }
  return [language componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"-_"]].firstObject;
}

typedef NS_ENUM(NSUInteger, DownloadText) {
  DownloadTextGif,
  DownloadTextVideo,
  DownloadTextProgress,
  DownloadTextSaved,
  DownloadTextFailed,
};

static NSString *downloadText(DownloadText which) {
  NSDictionary<NSString *, NSArray<NSString *> *> *texts = @{
    @"ar" : @[ @"تنزيل GIF", @"تنزيل الفيديو", @"جارٍ التنزيل…", @"تم الحفظ في الصور", @"تعذر التنزيل" ],
    @"cs" : @[ @"Stáhnout GIF", @"Stáhnout video", @"Stahování…", @"Uloženo do Fotek", @"Stažení se nezdařilo" ],
    @"da" : @[ @"Download GIF", @"Download video", @"Downloader…", @"Gemt i Fotos", @"Kunne ikke downloade" ],
    @"de" : @[ @"GIF laden", @"Video laden", @"Wird geladen…", @"In Fotos gesichert", @"Download fehlgeschlagen" ],
    @"el" : @[ @"Λήψη GIF", @"Λήψη βίντεο", @"Λήψη…", @"Αποθηκεύτηκε στις Φωτογραφίες", @"Η λήψη απέτυχε" ],
    @"en" : @[ @"Download GIF", @"Download video", @"Downloading…", @"Saved to Photos", @"Download failed" ],
    @"es" : @[ @"Descargar GIF", @"Descargar vídeo", @"Descargando…", @"Guardado en Fotos", @"No se pudo descargar" ],
    @"fi" : @[ @"Lataa GIF", @"Lataa video", @"Ladataan…", @"Tallennettu Kuviin", @"Lataus epäonnistui" ],
    @"fr" : @[ @"Télécharger le GIF", @"Télécharger la vidéo", @"Téléchargement…", @"Enregistré dans Photos", @"Échec du téléchargement" ],
    @"he" : @[ @"הורדת GIF", @"הורדת וידאו", @"מוריד…", @"נשמר בתמונות", @"ההורדה נכשלה" ],
    @"hi" : @[ @"GIF डाउनलोड करें", @"वीडियो डाउनलोड करें", @"डाउनलोड हो रहा है…", @"Photos में सहेजा गया", @"डाउनलोड विफल" ],
    @"hu" : @[ @"GIF letöltése", @"Videó letöltése", @"Letöltés…", @"Mentve a Fotókba", @"A letöltés sikertelen" ],
    @"id" : @[ @"Unduh GIF", @"Unduh video", @"Mengunduh…", @"Disimpan ke Foto", @"Gagal mengunduh" ],
    @"it" : @[ @"Scarica GIF", @"Scarica video", @"Download…", @"Salvato in Foto", @"Download non riuscito" ],
    @"ja" : @[ @"GIFをダウンロード", @"動画をダウンロード", @"ダウンロード中…", @"写真に保存しました", @"ダウンロードに失敗しました" ],
    @"ko" : @[ @"GIF 다운로드", @"동영상 다운로드", @"다운로드 중…", @"사진에 저장됨", @"다운로드 실패" ],
    @"nb" : @[ @"Last ned GIF", @"Last ned video", @"Laster ned…", @"Lagret i Bilder", @"Nedlasting mislyktes" ],
    @"nl" : @[ @"GIF downloaden", @"Video downloaden", @"Downloaden…", @"Bewaard in Foto's", @"Downloaden mislukt" ],
    @"pl" : @[ @"Pobierz GIF", @"Pobierz wideo", @"Pobieranie…", @"Zapisano w Zdjęciach", @"Nie udało się pobrać" ],
    @"pt" : @[ @"Baixar GIF", @"Baixar vídeo", @"Baixando…", @"Salvo em Fotos", @"Falha ao baixar" ],
    @"ro" : @[ @"Descarcă GIF", @"Descarcă video", @"Se descarcă…", @"Salvat în Poze", @"Descărcare eșuată" ],
    @"ru" : @[ @"Скачать GIF", @"Скачать видео", @"Загрузка…", @"Сохранено в Фото", @"Не удалось скачать" ],
    @"sv" : @[ @"Ladda ner GIF", @"Ladda ner video", @"Laddar ner…", @"Sparat i Bilder", @"Nedladdningen misslyckades" ],
    @"th" : @[ @"ดาวน์โหลด GIF", @"ดาวน์โหลดวิดีโอ", @"กำลังดาวน์โหลด…", @"บันทึกลงในรูปภาพแล้ว", @"ดาวน์โหลดไม่สำเร็จ" ],
    @"tr" : @[ @"GIF'i indir", @"Videoyu indir", @"İndiriliyor…", @"Fotoğraflar'a kaydedildi", @"İndirilemedi" ],
    @"uk" : @[ @"Завантажити GIF", @"Завантажити відео", @"Завантаження…", @"Збережено у Фото", @"Не вдалося завантажити" ],
    @"vi" : @[ @"Tải GIF", @"Tải video", @"Đang tải…", @"Đã lưu vào Ảnh", @"Không tải được" ],
    @"zh-Hans" : @[ @"下载 GIF", @"下载视频", @"正在下载…", @"已存储到照片", @"下载失败" ],
    @"zh-Hant" : @[ @"下載 GIF", @"下載影片", @"正在下載…", @"已儲存到照片", @"下載失敗" ],
  };
  NSArray<NSString *> *strings = texts[appLanguageKey(texts)] ?: texts[@"en"];
  return strings[which];
}

static void showDownloadNotice(NSString *text) {
  dispatch_async(dispatch_get_main_queue(), ^{
    static UILabel *notice;
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
      if (![scene isKindOfClass:UIWindowScene.class]) continue;
      for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
        if (candidate.isKeyWindow) window = candidate;
      }
    }
    if (!window) return;
    if (!notice) {
      notice = [UILabel new];
      notice.font = [UIFont boldSystemFontOfSize:14];
      notice.textColor = UIColor.whiteColor;
      notice.textAlignment = NSTextAlignmentCenter;
      notice.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
      notice.clipsToBounds = YES;
      notice.userInteractionEnabled = NO;
    }
    notice.text = text;
    CGSize size = [notice sizeThatFits:CGSizeZero];
    CGFloat height = size.height + 18;
    notice.layer.cornerRadius = height / 2;
    CGFloat width = MIN(size.width + 32, CGRectGetWidth(window.bounds) - 32);
    notice.frame = CGRectMake((CGRectGetWidth(window.bounds) - width) / 2,
                              CGRectGetHeight(window.bounds) - window.safeAreaInsets.bottom - 110, width, height);
    notice.alpha = 1;
    [window addSubview:notice];
    static NSUInteger generation = 0;
    NSUInteger current = ++generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      if (current == generation) [notice removeFromSuperview];
    });
  });
}

static NSURL *temporaryFile(NSString *extension) {
  NSString *name = [NSUUID.UUID.UUIDString stringByAppendingPathExtension:extension];
  return [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
}

static void saveFileToPhotos(NSURL *file, BOOL isPhotoResource, NSArray<NSURL *> *temporary) {
  void (^finish)(BOOL) = ^(BOOL saved) {
    for (NSURL *url in temporary) [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    showDownloadNotice(downloadText(saved ? DownloadTextSaved : DownloadTextFailed));
  };
  // iOS ends the app if it asks for Photos access without declaring why in its Info.plist.
  NSDictionary *info = NSBundle.mainBundle.infoDictionary;
  if (!info[@"NSPhotoLibraryAddUsageDescription"] && !info[@"NSPhotoLibraryUsageDescription"]) {
    logDownload(@"no photos usage description");
    finish(NO);
    return;
  }
  [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly
                                             handler:^(PHAuthorizationStatus status) {
    if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) {
      logDownload(@"photos access denied");
      finish(NO);
      return;
    }
    [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
      PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
      [request addResourceWithType:isPhotoResource ? PHAssetResourceTypePhoto : PHAssetResourceTypeVideo
                           fileURL:file
                           options:nil];
    } completionHandler:^(BOOL success, NSError *error) {
      logDownload([NSString stringWithFormat:@"save success=%d error=%ld", success, (long)error.code]);
      finish(success);
    }];
  }];
}

// Downloads an address to a temporary file, reporting nil unless the server sent a media file.
static void downloadToFile(NSURL *url, void (^completion)(NSURL *file, NSString *mimeType)) {
  [[NSURLSession.sharedSession
      downloadTaskWithURL:url
        completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
          NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
                                 ? ((NSHTTPURLResponse *)response).statusCode
                                 : 0;
          NSString *type = response.MIMEType.lowercaseString ?: @"";
          logDownload([NSString stringWithFormat:@"%@ %@ status=%ld type=%@", url.host, url.lastPathComponent, (long)status, type]);
          BOOL isMedia = [type hasPrefix:@"video/"] || [type hasPrefix:@"image/"] || [type hasPrefix:@"audio/"] ||
                         [type containsString:@"mp4"];
          if (error || !location || status < 200 || status >= 300 || !isMedia) {
            completion(nil, nil);
            return;
          }
          NSURL *file = temporaryFile([type containsString:@"gif"] ? @"gif" : @"mp4");
          if (![NSFileManager.defaultManager moveItemAtURL:location toURL:file error:nil]) {
            completion(nil, nil);
            return;
          }
          completion(file, type);
        }] resume];
}

// Tries file names in order until one exists.
static void downloadFirstAvailable(NSURL *base, NSArray<NSString *> *names, NSUInteger index,
                                   void (^completion)(NSURL *file)) {
  if (index >= names.count) {
    completion(nil);
    return;
  }
  downloadToFile([base URLByAppendingPathComponent:names[index]], ^(NSURL *file, NSString *type) {
    if (file) completion(file);
    else downloadFirstAvailable(base, names, index + 1, completion);
  });
}

static void mergeAndSave(NSURL *video, NSURL *audio) {
  AVURLAsset *videoAsset = [AVURLAsset assetWithURL:video];
  AVURLAsset *audioAsset = [AVURLAsset assetWithURL:audio];
  AVAssetTrack *videoTrack = [videoAsset tracksWithMediaType:AVMediaTypeVideo].firstObject;
  AVAssetTrack *audioTrack = [audioAsset tracksWithMediaType:AVMediaTypeAudio].firstObject;
  NSArray<NSURL *> *sources = @[ video, audio ];
  if (!videoTrack || !audioTrack) {
    [NSFileManager.defaultManager removeItemAtURL:audio error:nil];
    saveFileToPhotos(video, NO, @[ video ]);
    return;
  }
  AVMutableComposition *composition = [AVMutableComposition composition];
  CMTimeRange range = CMTimeRangeMake(kCMTimeZero, videoAsset.duration);
  AVMutableCompositionTrack *videoOut = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
  AVMutableCompositionTrack *audioOut = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
  CMTimeRange audioRange = CMTimeRangeMake(kCMTimeZero, CMTimeMinimum(videoAsset.duration, audioAsset.duration));
  [videoOut insertTimeRange:range ofTrack:videoTrack atTime:kCMTimeZero error:nil];
  [audioOut insertTimeRange:audioRange ofTrack:audioTrack atTime:kCMTimeZero error:nil];
  videoOut.preferredTransform = videoTrack.preferredTransform;
  AVAssetExportSession *export = [AVAssetExportSession exportSessionWithAsset:composition presetName:AVAssetExportPresetPassthrough];
  NSURL *output = temporaryFile(@"mp4");
  export.outputURL = output;
  export.outputFileType = AVFileTypeMPEG4;
  [export exportAsynchronouslyWithCompletionHandler:^{
    logDownload([NSString stringWithFormat:@"merge status=%ld error=%ld", (long)export.status, (long)export.error.code]);
    if (export.status == AVAssetExportSessionStatusCompleted) {
      saveFileToPhotos(output, NO, [sources arrayByAddingObject:output]);
    } else {
      // A clip without its sound is better than no clip.
      [NSFileManager.defaultManager removeItemAtURL:audio error:nil];
      [NSFileManager.defaultManager removeItemAtURL:output error:nil];
      saveFileToPhotos(video, NO, @[ video ]);
    }
  }];
}

// Streaming clips cannot be saved as they are, but Reddit keeps plain video and audio files beside
// the playlist. The largest video that exists is used, joined with its sound if there is any.
static void downloadStreamingClip(NSURL *playlist) {
  NSURLComponents *components = [NSURLComponents componentsWithURL:playlist resolvingAgainstBaseURL:NO];
  components.query = nil;
  NSURL *base = components.URL.URLByDeletingLastPathComponent;
  NSMutableArray<NSString *> *videos = [NSMutableArray array];
  for (NSString *size in @[ @"1080", @"720", @"480", @"360", @"270", @"240", @"220" ]) {
    [videos addObject:[NSString stringWithFormat:@"CMAF_%@.mp4", size]];
    [videos addObject:[NSString stringWithFormat:@"DASH_%@.mp4", size]];
  }
  NSArray<NSString *> *audios = @[ @"CMAF_AUDIO_128.mp4", @"DASH_AUDIO_128.mp4", @"CMAF_AUDIO_64.mp4", @"DASH_AUDIO_64.mp4", @"DASH_audio.mp4" ];
  downloadFirstAvailable(base, videos, 0, ^(NSURL *video) {
    if (!video) {
      showDownloadNotice(downloadText(DownloadTextFailed));
      return;
    }
    downloadFirstAvailable(base, audios, 0, ^(NSURL *audio) {
      if (audio) mergeAndSave(video, audio);
      else saveFileToPhotos(video, NO, @[ video ]);
    });
  });
}

static void downloadClip(NSDictionary *clip) {
  NSURL *url = [NSURL URLWithString:clip[@"path"]];
  if (!url) {
    showDownloadNotice(downloadText(DownloadTextFailed));
    return;
  }
  showDownloadNotice(downloadText(DownloadTextProgress));
  if ([url.pathExtension.lowercaseString isEqualToString:@"m3u8"]) {
    downloadStreamingClip(url);
    return;
  }
  downloadToFile(url, ^(NSURL *file, NSString *type) {
    if (!file) {
      showDownloadNotice(downloadText(DownloadTextFailed));
      return;
    }
    saveFileToPhotos(file, [type hasPrefix:@"image/"], @[ file ]);
  });
}

static UIViewController *controllerOfView(UIView *view) {
  for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
    if ([responder isKindOfClass:UIViewController.class]) return (UIViewController *)responder;
  }
  return nil;
}

static NSDictionary *clipOfStack(UIView *stack) {
  if (!stack) return nil;
  NSString *longest = nil;
  NSString *key = findPostKey(stack, &longest, 0);
  if (!key) return nil;
  @synchronized(clearAddressesByTitle) {
    return clipsByTitle[key];
  }
}

@interface RedditLegacyCoverTarget : NSObject
- (void)coverTapped:(UITapGestureRecognizer *)recognizer;
- (void)downloadRowTapped:(UIControl *)row;
@end

@implementation RedditLegacyCoverTarget
- (void)downloadRowTapped:(UIControl *)row {
  NSDictionary *clip = objc_getAssociatedObject(row, &kRowClipKey);
  UIViewController *sheet = controllerOfView(row);
  while (sheet.parentViewController) sheet = sheet.parentViewController;
  if (!clip || !sheet) return;
  [sheet dismissViewControllerAnimated:YES completion:^{ downloadClip(clip); }];
}
- (void)coverTapped:(UITapGestureRecognizer *)recognizer {
  UIView *cover = recognizer.view;
  NSString *key = objc_getAssociatedObject(cover, &kPostKey);
  logTap();
  if (key) {
    @synchronized(revealedPosts) {
      [revealedPosts addObject:key];
    }
  }
  cover.hidden = YES;
  UIView *host = cover.superview;
  fetchClearImages(host, key);
  refreshFeedStackOf(host);
}
@end

static NSString *adultContentButtonText(void) {
  NSDictionary<NSString *, NSString *> *texts = @{
    @"ar" : @"عرض محتوى +18",
    @"cs" : @"Zobrazit obsah 18+",
    @"da" : @"Vis 18+ indhold",
    @"de" : @"18+ Inhalt ansehen",
    @"el" : @"Προβολή περιεχομένου 18+",
    @"en" : @"View 18+ content",
    @"es" : @"Ver contenido 18+",
    @"fi" : @"Näytä 18+ sisältö",
    @"fr" : @"Voir le contenu 18+",
    @"he" : @"הצגת תוכן 18+",
    @"hi" : @"18+ सामग्री देखें",
    @"hu" : @"18+ tartalom megtekintése",
    @"id" : @"Lihat konten 18+",
    @"it" : @"Mostra contenuti 18+",
    @"ja" : @"18+コンテンツを表示",
    @"ko" : @"18+ 콘텐츠 보기",
    @"nb" : @"Vis 18+ innhold",
    @"nl" : @"18+ inhoud bekijken",
    @"pl" : @"Pokaż treści 18+",
    @"pt" : @"Ver conteúdo 18+",
    @"ro" : @"Vezi conținut 18+",
    @"ru" : @"Показать контент 18+",
    @"sv" : @"Visa 18+ innehåll",
    @"th" : @"ดูเนื้อหา 18+",
    @"tr" : @"18+ içeriği göster",
    @"uk" : @"Показати вміст 18+",
    @"vi" : @"Xem nội dung 18+",
    @"zh-Hans" : @"查看 18+ 内容",
    @"zh-Hant" : @"查看 18+ 內容",
  };
  return texts[appLanguageKey(texts)] ?: texts[@"en"];
}

// The blur is drawn here, so it covers all 18+ media whether or not the server sent a blurred copy.
static UIView *makeCover(UIView *host, BOOL withBadge) {
  static RedditLegacyCoverTarget *target;
  if (!target) target = [RedditLegacyCoverTarget new];
  UIView *cover = [UIView new];
  cover.tag = kCoverTag;
  cover.clipsToBounds = YES;
  cover.layer.cornerRadius = withBadge ? 12 : 6;
  // Images finish loading after this runs, so the cover must stay above views added later.
  cover.layer.zPosition = 1000;
  cover.translatesAutoresizingMaskIntoConstraints = NO;
  [cover addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:target
                                                                      action:@selector(coverTapped:)]];
  UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark];
  UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:effect];
  blur.translatesAutoresizingMaskIntoConstraints = NO;
  blur.userInteractionEnabled = NO;
  [cover addSubview:blur];
  [host addSubview:cover];
  // The host has no final size yet at this point, so the layout is left to Auto Layout.
  [NSLayoutConstraint activateConstraints:@[
    [cover.topAnchor constraintEqualToAnchor:host.topAnchor],
    [cover.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
    [cover.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
    [cover.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
    [blur.topAnchor constraintEqualToAnchor:cover.topAnchor],
    [blur.bottomAnchor constraintEqualToAnchor:cover.bottomAnchor],
    [blur.leadingAnchor constraintEqualToAnchor:cover.leadingAnchor],
    [blur.trailingAnchor constraintEqualToAnchor:cover.trailingAnchor],
  ]];
  if (withBadge) {
    UILabel *badge = [UILabel new];
    badge.text = adultContentButtonText();
    badge.font = [UIFont boldSystemFontOfSize:13];
    badge.textColor = UIColor.whiteColor;
    badge.textAlignment = NSTextAlignmentCenter;
    badge.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
    badge.clipsToBounds = YES;
    badge.userInteractionEnabled = NO;
    CGSize size = [badge sizeThatFits:CGSizeZero];
    CGFloat height = size.height + 14;
    badge.layer.cornerRadius = height / 2;
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    [cover addSubview:badge];
    [NSLayoutConstraint activateConstraints:@[
      [badge.widthAnchor constraintEqualToConstant:size.width + 24],
      [badge.heightAnchor constraintEqualToConstant:height],
      [badge.centerXAnchor constraintEqualToAnchor:cover.centerXAnchor],
      [badge.centerYAnchor constraintEqualToAnchor:cover.centerYAnchor],
    ]];
  }
  return cover;
}

static CGFloat cornerRadiusOfContent(UIView *view, int depth);

static void updateCover(UIView *host, BOOL covered, NSString *key, BOOL withBadge) {
  UIView *cover = nil;
  for (UIView *child in host.subviews) {
    if (child.tag == kCoverTag) cover = child;
  }
  if (!covered) {
    cover.hidden = YES;
    return;
  }
  if (!cover) cover = makeCover(host, withBadge);
  cover.hidden = NO;
  CGFloat radius = cornerRadiusOfContent(host, 0);
  if (radius > 0) cover.layer.cornerRadius = radius;
  objc_setAssociatedObject(cover, &kPostKey, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

// The media container spans the whole feed width, with the image inset inside it. The cover goes
// on the inner view so it matches the image.
static UIView *mediaContentView(UIView *view, int depth) {
  if (depth > 6) return nil;
  NSString *name = NSStringFromClass(view.class);
  if (depth > 0 && ([name hasSuffix:@"ServerImageSliceView"] || [name hasSuffix:@"CarouselSliceView"] ||
                    [name hasSuffix:@"LegacyVideoSliceView"]))
    return view;
  for (UIView *child in view.subviews) {
    UIView *found = mediaContentView(child, depth + 1);
    if (found) return found;
  }
  return nil;
}

// Corners are rounded on the host or on a view just inside it.
static CGFloat cornerRadiusOfContent(UIView *view, int depth) {
  CGFloat radius = view.layer.cornerRadius;
  if (radius > 0 || depth > 4) return radius;
  for (UIView *child in view.subviews) {
    if (child.tag == kCoverTag) continue;
    radius = MAX(radius, cornerRadiusOfContent(child, depth + 1));
  }
  return radius;
}

static void updateMediaCover(UIView *media, BOOL isTagged, NSString *key) {
  BOOL isClip = [NSStringFromClass(media.class) containsString:@"LegacyVideo"];
  BOOL isRevealed = isPostRevealed(key);
  BOOL covered = isTagged && !isRevealed;
  NSArray<NSString *> *addresses = isClip ? nil : clearAddressesForPost(key);
  NSMutableArray<UIImageView *> *imageViews = [NSMutableArray array];
  collectImageViews(media, kMinMediaWidth, imageViews, 0);
  for (UIImageView *imageView in imageViews) {
    objc_setAssociatedObject(imageView, &kFeedMediaKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!isRevealed) continue;
    NSUInteger index = pageIndexOfImageView(imageView);
    UIImage *clear = index < addresses.count ? [revealedImages objectForKey:addresses[index]] : nil;
    if (clear && imageView.image != clear) {
      imageView.image = clear;
      logRevealApplied(index, imageViews.count, 1);
    }
  }
  if (isClip) {
    hideNativeClipBlur(media, media, 0);
    setClipBlocked(media, covered, 0);
  }
  UIView *content = mediaContentView(media, 0) ?: media;
  // The inner view can appear after a first pass that had to use the container.
  if (content != media) updateCover(media, NO, key, YES);
  updateCover(content, covered, key, YES);
  logCoverState(media, covered, addresses.count);
}

static void updateThumbnailCovers(UIView *view, BOOL covered, NSString *key) {
  NSMutableArray<UIImageView *> *imageViews = [NSMutableArray array];
  collectImageViews(view, kMinThumbnailWidth, imageViews, 0);
  for (UIImageView *imageView in imageViews) updateCover(imageView, covered, key, NO);
}

static void updatePostMedia(UIView *view, BOOL isTagged, NSString *key, int depth) {
  if (depth > 6) return;
  if (isBlurredMediaContainer(view)) {
    updateMediaCover(view, isTagged, key);
    return;
  }
  if ([NSStringFromClass(view.class) containsString:@"TitleWithThumbnailSliceView"]) {
    updateThumbnailCovers(view, isTagged && !isPostRevealed(key), key);
    return;
  }
  for (UIView *child in view.subviews) updatePostMedia(child, isTagged, key, depth + 1);
}

// The feed captures touches before they reach the cover, so it is handed them directly.
static UIView *visibleCoverAtPoint(UIView *view, UIView *stack, CGPoint point, int depth) {
  if (depth > 14 || view.hidden) return nil;
  if (view.tag == kCoverTag) {
    return [view pointInside:[stack convertPoint:point toView:view] withEvent:nil] ? view : nil;
  }
  for (UIView *child in view.subviews) {
    UIView *found = visibleCoverAtPoint(child, stack, point, depth + 1);
    if (found) return found;
  }
  return nil;
}

static UICollectionView *firstCollectionView(UIView *view, int depth) {
  if ([view isKindOfClass:UICollectionView.class]) return (UICollectionView *)view;
  if (depth > 10) return nil;
  for (UIView *child in view.subviews) {
    UICollectionView *found = firstCollectionView(child, depth + 1);
    if (found) return found;
  }
  return nil;
}

static void collectRowLabels(UIView *view, NSMutableArray<UILabel *> *found, int depth) {
  if (depth > 10) return;
  if ([view isKindOfClass:UILabel.class] && [NSStringFromClass(view.superview.class) containsString:@"LabelSliceView"]) {
    [found addObject:(UILabel *)view];
    return;
  }
  for (UIView *child in view.subviews) collectRowLabels(child, found, depth + 1);
}

static UIImageView *firstIconIn(UIView *view, int depth) {
  if ([view isKindOfClass:UIImageView.class] && CGRectGetWidth(view.bounds) > 0) return (UIImageView *)view;
  if (depth > 8) return nil;
  for (UIView *child in view.subviews) {
    UIImageView *found = firstIconIn(child, depth + 1);
    if (found) return found;
  }
  return nil;
}

// Finds the app's "Save" row by its word in the app's language. If the word isn't known, the second
// row is used, which is where that row normally sits.
static UILabel *saveRowLabel(NSArray<UILabel *> *labels) {
  NSArray<NSString *> *words = @[
    @"guardar", @"save", @"salvar", @"enregistrer", @"sauvegarder", @"speichern", @"salva", @"opslaan", @"spara",
    @"gem", @"lagre", @"tallenna", @"zapisz", @"uložit", @"kaydet", @"сохран", @"збере", @"保存", @"儲存", @"저장",
    @"حفظ", @"שמור", @"simpan", @"lưu", @"mentés", @"salvează", @"αποθήκευση", @"บันทึก", @"सहेज"
  ];
  for (UILabel *label in labels) {
    NSString *text = label.text.lowercaseString;
    for (NSString *word in words) {
      if ([text hasPrefix:word]) return label;
    }
  }
  return labels.count > 1 ? labels[1] : labels.firstObject;
}

static UICollectionViewCell *cellOfView(UIView *view) {
  while (view && ![view isKindOfClass:UICollectionViewCell.class]) view = view.superview;
  return (UICollectionViewCell *)view;
}

// Rows below the new one are moved down each time the list lays out, because it keeps reusing them
// while scrolling. A view's center ignores this offset, so it still gives the row's real place.
static void shiftRowsBelowDownloadRow(UICollectionView *list) {
  NSNumber *anchor = objc_getAssociatedObject(list, &kRowAnchorKey);
  NSNumber *height = objc_getAssociatedObject(list, &kRowHeightKey);
  if (!anchor) return;
  for (UIView *view in list.subviews) {
    if (![view isKindOfClass:UICollectionReusableView.class]) continue;
    view.transform = view.center.y > anchor.doubleValue ? CGAffineTransformMakeTranslation(0, height.doubleValue) : CGAffineTransformIdentity;
  }
}

// The sheet's rows are built from Swift data this tweak can't add to, so this row is placed in a gap
// opened under the app's "Save" row, with that row's look.
static void addDownloadRow(UICollectionView *list, NSDictionary *clip) {
  if ([list viewWithTag:kDownloadRowTag]) return;
  NSMutableArray<UILabel *> *labels = [NSMutableArray array];
  for (UICollectionViewCell *cell in list.visibleCells) collectRowLabels(cell, labels, 0);
  [labels sortUsingComparator:^NSComparisonResult(UILabel *a, UILabel *b) {
    CGFloat ay = [a convertPoint:CGPointZero toView:list].y;
    CGFloat by = [b convertPoint:CGPointZero toView:list].y;
    return ay < by ? NSOrderedAscending : ay > by ? NSOrderedDescending : NSOrderedSame;
  }];
  UILabel *model = saveRowLabel(labels);
  UICollectionViewCell *modelCell = cellOfView(model);
  if (!model || !modelCell) return;

  static RedditLegacyCoverTarget *target;
  if (!target) target = [RedditLegacyCoverTarget new];
  CGFloat height = CGRectGetHeight(modelCell.bounds);
  CGFloat anchor = modelCell.center.y + height / 2;
  CGRect labelFrame = [model convertRect:model.bounds toView:modelCell];
  UIImageView *modelIcon = firstIconIn(modelCell, 0);
  CGRect iconFrame = modelIcon ? [modelIcon convertRect:modelIcon.bounds toView:modelCell] : CGRectMake(16, (height - 24) / 2, 24, 24);

  UIControl *row = [[UIControl alloc] initWithFrame:CGRectMake(0, anchor, CGRectGetWidth(list.bounds), height)];
  row.tag = kDownloadRowTag;
  row.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  objc_setAssociatedObject(row, &kRowClipKey, clip, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [row addTarget:target action:@selector(downloadRowTapped:) forControlEvents:UIControlEventTouchUpInside];

  UIImageSymbolConfiguration *symbol = [UIImageSymbolConfiguration configurationWithPointSize:CGRectGetHeight(iconFrame) * 0.72];
  UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.down.to.line" withConfiguration:symbol]];
  icon.tintColor = modelIcon.tintColor ?: model.textColor;
  icon.contentMode = UIViewContentModeCenter;
  icon.frame = iconFrame;
  icon.userInteractionEnabled = NO;
  [row addSubview:icon];

  UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(CGRectGetMinX(labelFrame), CGRectGetMinY(labelFrame),
                                                             CGRectGetWidth(list.bounds) - CGRectGetMinX(labelFrame) - 16,
                                                             CGRectGetHeight(labelFrame))];
  label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  label.font = model.font;
  label.textColor = model.textColor;
  label.text = downloadText([clip[@"isGif"] boolValue] ? DownloadTextGif : DownloadTextVideo);
  label.userInteractionEnabled = NO;
  [row addSubview:label];

  [list addSubview:row];
  objc_setAssociatedObject(list, &kRowAnchorKey, @(anchor), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  objc_setAssociatedObject(list, &kRowHeightKey, @(height), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  UIEdgeInsets insets = list.contentInset;
  insets.bottom += height;
  list.contentInset = insets;
  shiftRowsBelowDownloadRow(list);
  logDownload([NSString stringWithFormat:@"sheet row under \"%@\" rows=%lu", model.text, (unsigned long)labels.count]);
}

// The list is built after the sheet is presented, so it is looked for over the first moments.
static void offerDownloadInSheet(UIViewController *sheet) {
  NSDictionary *clip = clipOfStack(lastTouchedStack);
  logDownload([NSString stringWithFormat:@"sheet clip=%d", clip != nil]);
  if (!clip) return;
  __weak UIViewController *weakSheet = sheet;
  for (NSNumber *delay in @[ @0.2, @0.45, @0.8, @1.3 ]) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      UIViewController *strongSheet = weakSheet;
      if (!strongSheet.isViewLoaded) return;
      UICollectionView *list = firstCollectionView(strongSheet.view, 0);
      if (list && CGRectGetWidth(list.bounds) > 0 && list.visibleCells.count > 0) addDownloadRow(list, clip);
    });
  }
}

static void refreshAdultBadges(UIView *stack) {
  NSString *longest = nil;
  NSString *key = findPostKey(stack, &longest, 0) ?: longest;
  updatePostMedia(stack, blurEnabled && hasAdultTag(stack, 0), key, 0);
}

// The online dot would stay alone next to the emptied count.
static void hideOnlineDot(UILabel *label) {
  __weak UILabel *weakLabel = label;
  dispatch_async(dispatch_get_main_queue(), ^{
    UIView *parent = weakLabel.superview;
    for (UIView *sibling in parent.subviews) {
      CGSize size = sibling.bounds.size;
      if (sibling != weakLabel && ![sibling isKindOfClass:UILabel.class] && size.width > 0 && size.width <= 14 &&
          size.height > 0 && size.height <= 14)
        sibling.hidden = YES;
    }
  });
}

// The online count is recognised by its text, and otherwise by where it sits: a short label starting
// with 0 in a subreddit's header or title bar. That keeps it working in any app language.
static BOOL isZeroOnline(UILabel *label, NSString *text) {
  if (text.length == 0 || text.length > 60) return NO;
  if (matches(zeroOnlineText, text)) return YES;
  if (text.length > 30 || !matches(zeroCountText, text)) return NO;
  for (UIView *view = label.superview; view; view = view.superview) {
    NSString *name = NSStringFromClass(view.class);
    if ([name containsString:@"SubredditHeaderView"] || [name containsString:@"SubredditScreenNavigationTitleView"]) return YES;
  }
  return NO;
}

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
  logAvatarRequest(request.URL);
  logRequestVersion(request, self);
  if (!handler || !shouldWrap(request.URL.host)) return %orig;
  probeOnlineCount(request);
  NSString *operation = operationName(request);
  testActiveCountSources(request, operation);
  void (^wrapped)(NSData *, NSURLResponse *, NSError *) =
      ^(NSData *data, NSURLResponse *response, NSError *error) {
        logResult(request, operation, response, error);
        logGameResponse(request, response, data);
        handler(error ? data : processResponse(request, operation, data), response, error);
      };
  return %orig(requestForGameServers(request), wrapped);
}
%end

%hook UIViewController
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(id)completion {
  logPresented(controller);
  %orig;
  if ([NSStringFromClass(controller.class) containsString:@"ShareOverflowBottomSheet"]) offerDownloadInSheet(controller);
}
%end

%hook UICollectionView
- (void)layoutSubviews {
  %orig;
  if (objc_getAssociatedObject(self, &kRowAnchorKey)) shiftRowsBelowDownloadRow(self);
}
%end

%hook UIImageView
- (void)setImage:(UIImage *)image {
  %orig;
  if (!objc_getAssociatedObject(self, &kFeedMediaKey)) return;
  __weak UIView *weakView = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    UIView *view = weakView;
    if (view) refreshFeedStackOf(view);
  });
}
%end

%hook UILabel
// Reddit no longer sends an online count, so the app always shows zero. Emptying the text
// also survives the app toggling the label's visibility, and reused cells simply get new text.
- (void)setText:(NSString *)text {
  logLabel(self, text);
  BOOL isZero = isZeroOnline(self, text);
  %orig(isZero ? @"" : text);
  if (isZero) hideOnlineDot(self);
}
- (void)setAttributedText:(NSAttributedString *)text {
  logLabel(self, text.string);
  BOOL isZero = isZeroOnline(self, text.string);
  %orig(isZero ? [[NSAttributedString alloc] initWithString:@""] : text);
  if (isZero) hideOnlineDot(self);
}
%end

@interface FeedStackSliceView : UIView
@end

%group AdultBadge
%hook FeedStackSliceView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
  UIView *stack = (UIView *)self;
  // Remembers the post being touched, because the "more actions" sheet doesn't say which one it's for.
  if ([stack pointInside:point withEvent:event]) lastTouchedStack = stack;
  UIView *cover = visibleCoverAtPoint(stack, stack, point, 0);
  return cover ?: %orig;
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

%hook UIContextMenuInteraction
- (instancetype)initWithDelegate:(id)delegate {
  logContextMenu(delegate);
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
  revealedPosts = [NSMutableSet set];
  clipsByTitle = [NSMutableDictionary dictionary];
  zeroCountText = [NSRegularExpression regularExpressionWithPattern:@"^[\\s•·]*0(\\s|\\p{L})" options:0 error:nil];
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
