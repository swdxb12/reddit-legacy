// Declarations shared by the parts of the tweak. Each part lives in its own file:
//
//   Tweak.x       the hooks into the app, and start-up
//   Responses.m   rewrites Reddit's API responses (ads, NSFW labels, blurred copies)
//   Posts.m       what the tweak remembers about posts, in memory only
//   Covers.m      the "View 18+ content" cover over 18+ media in the feed
//   Games.m       Reddit games, shown as the web pages they are today
//   Downloads.m   the "Download video / GIF" row in a post's "more actions" sheet
//   Visitors.m    weekly visitors where the retired online count used to be
//   Common.m      small helpers for text, languages and views
#import <UIKit/UIKit.h>

#pragma mark - Common.m

// Marks for the views this tweak adds, so they can be found again.
extern const NSInteger RLCoverTag;
extern const NSInteger RLGameViewTag;
extern const NSInteger RLDownloadRowTag;

// The key of `texts` for the language the app runs in (which can differ from the device's).
NSString *RLLanguageKey(NSDictionary *texts);
// A title in lower case with single spaces, so the same title always gives the same key.
NSString *RLNormalizedTitle(NSString *title);
// The text a view shows, whether it is a label, a text view or any view with a text property.
NSString *RLTextOfView(UIView *view);
UIViewController *RLControllerOfView(UIView *view);
UICollectionView *RLFirstCollectionView(UIView *view);
// The app's container for one post in a feed.
Class RLFeedPostClass(void);
UIView *RLFeedPostOf(UIView *view);
// The media part of a feed post: an image, a gallery or a clip.
BOOL RLIsMediaContainer(UIView *view);
// Runs `block` on the main thread after `seconds`, if `object` still exists then.
void RLAfter(NSTimeInterval seconds, id object, void (^block)(id object));

#pragma mark - Responses.m

BOOL RLIsAPIHost(NSString *host);
NSString *RLOperationName(NSURLRequest *request);
NSData *RLProcessResponse(NSURLRequest *request, NSData *data);
// Whether the account has "blur NSFW media" on, as the app reports it.
BOOL RLBlurEnabled(void);

#pragma mark - Posts.m

void RLRememberFeedPost(NSDictionary *group);
void RLRememberPostDetails(NSDictionary *post);
void RLRememberOpenedPost(NSString *postId);
// The key of the first known post title inside `view`; `longestText` gets the longest text seen.
NSString *RLPostKeyIn(UIView *view, NSString **longestText);
BOOL RLServerBlurredPost(NSString *key);
NSDictionary *RLClipOfPost(NSString *key);
NSDictionary *RLClipOfOpenedPost(void);
NSDictionary *RLGameOfPost(NSString *key);
void RLMarkPostRevealed(NSString *key);
BOOL RLIsPostRevealed(NSString *key);

#pragma mark - Covers.m

// Brings one feed post up to date: its 18+ cover, and its game if it has one.
void RLUpdateFeedPost(UIView *post);
void RLUpdateAllFeedPosts(void);
// The cover under `point`, which takes the touch before the feed does.
UIView *RLCoverAtPoint(UIView *post, CGPoint point);

#pragma mark - Games.m

void RLUpdateGameView(UIView *container, NSString *key);
void RLFetchGameEntries(NSURLRequest *request, NSData *response);

#pragma mark - Downloads.m

void RLRememberTouchedPost(UIView *post);
void RLOfferDownloadInSheet(UIViewController *sheet);
void RLKeepDownloadRowInPlace(UICollectionView *list);

#pragma mark - Visitors.m

extern NSString *const RLVisitorsPlaceholder;
void RLRememberAuthorization(NSURLRequest *request);
// Whether `text` is the online count, which Reddit always sends as zero now.
BOOL RLIsOnlineCount(UILabel *label, NSString *text);
NSString *RLKnownVisitorsText(UILabel *label);
// Called after the label got the known count or the placeholder.
void RLDidShowVisitors(UILabel *label, NSString *visitors);
