// Reddit games, shown inside the post as the web pages they are today.
//
// This version of the app draws games with a renderer whose service Reddit has retired, so it only
// shows an "update the app" notice. The current app opens each game's web page in an embedded web
// view instead, and so does this:
//  - The feed query of this version leaves out which page a game opens with. The current app's
//    version of the same query includes it, so the request is sent again with that query's id,
//    and the answer is remembered by each game's base address.
//  - The page's start-up script reads who is playing, which post it is and a signed permission from
//    the address fragment, as the current app passes them. The fragment never leaves the phone.
#import "RedditLegacy.h"
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

static char kLoadedPageKey;
static NSObject *lock;
static NSMutableDictionary<NSString *, NSDictionary *> *gamesByBase;
static NSMutableSet<NSData *> *askedRequests;

__attribute__((constructor)) static void setUp(void) {
  lock = [NSObject new];
  gamesByBase = [NSMutableDictionary dictionary];
  askedRequests = [NSMutableSet set];
}

// The current app's (2026.13) ids for the feed queries that can hold games.
static NSDictionary<NSString *, NSString *> *currentFeedQueries(void) {
  return @{
    @"SubredditFeedSdui" : @"c4f5e78a7891cca72695fb05157198b2d7daf112a539feeae35075de72d69cb3",
    @"HomeFeedSdui" : @"3de9015565ef62183a06148145a8bb660fa746cb8eedc91b62626600697ecb35",
    @"MultiredditPostsSdui" : @"3109db313b59556d8b6e77e54b7d48359496bef46dfec1433fc4e49c8223081a",
  };
}

#pragma mark - Finding each game's page

static void rememberGames(id object, int depth) {
  if (depth > 40) return;
  if ([object isKindOfClass:NSDictionary.class]) {
    NSString *base = object[@"webViewBaseUrl"];
    NSString *entry = object[@"entrypointUrl"];
    if ([base isKindOfClass:NSString.class] && [entry isKindOfClass:NSString.class] && entry.length) {
      @synchronized(lock) {
        gamesByBase[base] = object;
      }
    }
    for (id value in [object allValues]) rememberGames(value, depth + 1);
  } else if ([object isKindOfClass:NSArray.class]) {
    for (id item in object) rememberGames(item, depth + 1);
  }
}

static BOOL containsText(NSData *data, NSString *text) {
  NSData *needle = [text dataUsingEncoding:NSUTF8StringEncoding];
  return [data rangeOfData:needle options:0 range:NSMakeRange(0, data.length)].location != NSNotFound;
}

void RLFetchGameEntries(NSURLRequest *original, NSData *response) {
  NSData *body = original.HTTPBody;
  if (!body || !response || ![original.URL.host hasPrefix:@"gql"] || !containsText(response, @"CustomPostCell")) return;
  // The repeated request carries one of the current ids itself, and isn't repeated again.
  for (NSString *query in currentFeedQueries().allValues)
    if (containsText(body, query)) return;
  NSString *currentQuery = currentFeedQueries()[RLOperationName(original) ?: @""];
  if (!currentQuery) return;
  @synchronized(lock) {
    if ([askedRequests containsObject:body]) return;
    [askedRequests addObject:body];
  }

  NSMutableDictionary *json = [NSJSONSerialization JSONObjectWithData:body options:NSJSONReadingMutableContainers error:nil];
  NSMutableDictionary *persisted = [json isKindOfClass:NSMutableDictionary.class] ? [json valueForKeyPath:@"extensions.persistedQuery"] : nil;
  if (![persisted isKindOfClass:NSMutableDictionary.class]) return;
  persisted[@"sha256Hash"] = currentQuery;
  NSMutableURLRequest *request = [original mutableCopy];
  request.HTTPBody = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
  [request setValue:nil forHTTPHeaderField:@"Content-Length"];
  [[NSURLSession.sharedSession dataTaskWithRequest:request
                                 completionHandler:^(NSData *data, NSURLResponse *answer, NSError *error) {
    id games = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (!games) return;
    rememberGames(games, 0);
    dispatch_async(dispatch_get_main_queue(), ^{ RLUpdateAllFeedPosts(); });
  }] resume];
}

#pragma mark - The game's address

static id parsedJSON(id value) {
  if (![value isKindOfClass:NSString.class]) return value;
  return [NSJSONSerialization JSONObjectWithData:[value dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] ?: value;
}

static NSString *contextFragment(NSDictionary *game, NSDictionary *details) {
  NSMutableDictionary *context = [NSMutableDictionary dictionary];
  context[@"client"] = @2;  // iOS
  context[@"nativeVersion"] = @{ @"yyyy" : @2026, @"release" : @13, @"build" : @0 };
  for (NSString *name in @[ @"signedRequestContext", @"webbitToken" ]) {
    if ([details[name] isKindOfClass:NSString.class]) context[name] = details[name];
  }
  for (NSString *name in @[ @"webViewContext", @"postData", @"shareParam", @"appPermissionState" ]) {
    id value = details[name];
    if (value && value != NSNull.null) context[name] = parsedJSON(value);
  }
  id clientData = parsedJSON(details[@"webViewClientData"]);
  if ([clientData isKindOfClass:NSDictionary.class]) context[@"webViewClientData"] = clientData;
  if (!context[@"webbitToken"]) context[@"webbitToken"] = game[@"token"];

  // Without a signed context the page can still start from the post's own ids.
  NSDictionary *post = game[@"post"];
  NSDictionary *subreddit = [post[@"subreddit"] isKindOfClass:NSDictionary.class] ? post[@"subreddit"] : nil;
  if (!context[@"signedRequestContext"] && !context[@"webViewContext"] && [post[@"id"] isKindOfClass:NSString.class] &&
      [subreddit[@"id"] isKindOfClass:NSString.class]) {
    NSMutableDictionary *view = [NSMutableDictionary dictionaryWithDictionary:@{ @"postId" : post[@"id"], @"subredditId" : subreddit[@"id"] }];
    if ([subreddit[@"name"] isKindOfClass:NSString.class]) view[@"subredditName"] = subreddit[@"name"];
    context[@"webViewContext"] = view;
  }

  NSData *data = [NSJSONSerialization dataWithJSONObject:context options:0 error:nil];
  NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
  return [text stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet];
}

static NSURL *gameAddress(NSDictionary *game) {
  NSDictionary *details;
  @synchronized(lock) {
    details = gamesByBase[game[@"base"]];
  }
  NSString *entry = details[@"entrypointUrl"];
  if (![entry isKindOfClass:NSString.class] || !entry.length) return nil;
  NSURL *page = [entry containsString:@"://"] ? [NSURL URLWithString:entry] : [NSURL URLWithString:entry relativeToURL:[NSURL URLWithString:game[@"base"]]];
  NSURLComponents *components = [NSURLComponents componentsWithURL:page.absoluteURL resolvingAgainstBaseURL:YES];
  if (!components) return nil;
  NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray arrayWithArray:components.queryItems ?: @[]];
  [items addObject:[NSURLQueryItem queryItemWithName:@"webbit_token" value:game[@"token"]]];
  components.queryItems = items;
  components.percentEncodedFragment = contextFragment(game, details);
  return components.URL;
}

#pragma mark - The web view

static WKWebView *makeGameView(void) {
  WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
  configuration.allowsInlineMediaPlayback = YES;
  configuration.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
  // The page expects to run in a frame and sends its host messages through window.parent. There is
  // no host page here, and the messages (telemetry, live updates) need no answer.
  NSString *script = @"window.parent = window; window.postMessage = function () {};";
  [configuration.userContentController addUserScript:[[WKUserScript alloc] initWithSource:script
                                                                            injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                                         forMainFrameOnly:NO]];
  WKWebView *view = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
  view.tag = RLGameViewTag;
  view.opaque = NO;
  view.backgroundColor = UIColor.clearColor;
  view.scrollView.bounces = NO;
  view.layer.zPosition = 1000;
  view.translatesAutoresizingMaskIntoConstraints = NO;
  return view;
}

void RLUpdateGameView(UIView *container, NSString *key) {
  NSDictionary *game = RLGameOfPost(key);
  WKWebView *view = (WKWebView *)[container viewWithTag:RLGameViewTag];
  if (!game) {
    view.hidden = YES;
    return;
  }
  if (!view) {
    view = makeGameView();
    [container addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
      [view.topAnchor constraintEqualToAnchor:container.topAnchor],
      [view.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
      [view.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
      [view.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
    ]];
  }
  view.hidden = NO;
  NSURL *address = gameAddress(game);
  if (!address) return;
  // Cells are reused for other posts, so the page is loaded again only when it changes.
  NSString *page = [key stringByAppendingString:address.path ?: @""];
  if ([objc_getAssociatedObject(view, &kLoadedPageKey) isEqualToString:page]) return;
  objc_setAssociatedObject(view, &kLoadedPageKey, page, OBJC_ASSOCIATION_COPY_NONATOMIC);
  [view loadRequest:[NSURLRequest requestWithURL:address]];
}
