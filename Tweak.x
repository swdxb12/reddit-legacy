// RedditLegacy keeps the official Reddit app (2025.32) usable on iOS 15:
//  - no ads, and no NSFW banner on subreddits;
//  - 18+ media in the feed is blurred behind a "View 18+ content" button; one tap shows it;
//  - Reddit games open inside the post, as in the current app;
//  - weekly visitors are shown where the retired online count was;
//  - a post's "more actions" sheet can save its video or GIF to Photos.
// Texts follow the language the app runs in. Nothing is stored outside memory.
//
// This file only holds the hooks into the app; the work is done in Sources/ (see RedditLegacy.h).
#import "Sources/RedditLegacy.h"

// Every API response passes through here, and is rewritten before the app reads it.
%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
  if (!handler || !RLIsAPIHost(request.URL.host)) return %orig;
  RLRememberAuthorization(request);
  return %orig(request, ^(NSData *data, NSURLResponse *response, NSError *error) {
    if (error) {
      handler(data, response, error);
      return;
    }
    RLFetchGameEntries(request, data);
    handler(RLProcessResponse(request, data), response, error);
  });
}
%end

// A post's "more actions" sheet gets the download row.
%hook UIViewController
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(id)completion {
  %orig;
  if ([NSStringFromClass(controller.class) containsString:@"ShareOverflowBottomSheet"]) RLOfferDownloadInSheet(controller);
}
%end

%hook UICollectionView
- (void)layoutSubviews {
  %orig;
  RLKeepDownloadRowInPlace(self);
}
%end

// The online count label shows weekly visitors instead of the zero Reddit sends now.
%hook UILabel
- (void)setText:(NSString *)text {
  if (!RLIsOnlineCount(self, text)) {
    %orig;
    return;
  }
  NSString *visitors = RLKnownVisitorsText(self);
  %orig(visitors ?: RLVisitorsPlaceholder);
  RLDidShowVisitors(self, visitors);
}
- (void)setAttributedText:(NSAttributedString *)text {
  if (!RLIsOnlineCount(self, text.string)) {
    %orig;
    return;
  }
  NSString *visitors = RLKnownVisitorsText(self);
  NSDictionary *attributes = text.length ? [text attributesAtIndex:0 effectiveRange:NULL] : nil;
  %orig([[NSAttributedString alloc] initWithString:visitors ?: RLVisitorsPlaceholder attributes:attributes]);
  RLDidShowVisitors(self, visitors);
}
%end

@interface FeedPost : UIView
@end

// Each post in a feed: its cover and game are brought up to date whenever it lays out.
%group FeedPosts
%hook FeedPost
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
  // The "more actions" sheet doesn't say which post it is for, so the touched post is remembered.
  if ([self pointInside:point withEvent:event]) RLRememberTouchedPost(self);
  // The feed takes touches before they reach the cover, so the cover is handed them first.
  return RLCoverAtPoint(self, point) ?: %orig;
}
- (void)layoutSubviews {
  %orig;
  RLUpdateFeedPost(self);
  // The 18+ tag and the post's data can arrive after this layout pass, so they are checked again.
  for (NSNumber *delay in @[ @0, @0.5, @1.5, @3 ]) {
    RLAfter(delay.doubleValue, self, ^(UIView *post) { RLUpdateFeedPost(post); });
  }
}
%end
%end

%ctor {
  %init;
  Class feedPost = RLFeedPostClass();
  if (feedPost) %init(FeedPosts, FeedPost = feedPost);
}
