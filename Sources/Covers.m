// The "View 18+ content" cover over 18+ media in the feed.
//
// The cover is a blur with a button drawn by the tweak, over every image, gallery and clip of a post
// with the 18+ tag (or whose media the server sent blurred). One tap removes it for that post, which
// stays revealed while scrolling. A clip under a cover is kept hidden and paused, because its player
// draws over everything below it. Compact posts are left alone: their thumbnail is already the
// server's blurred copy, and a tap opens the post.
#import "RedditLegacy.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

static char kPostKey;

static NSString *buttonText(void) {
  NSDictionary<NSString *, NSString *> *texts = @{
    @"ar" : @"عرض محتوى +18",          @"cs" : @"Zobrazit obsah 18+",       @"da" : @"Vis 18+ indhold",
    @"de" : @"18+ Inhalt ansehen",     @"el" : @"Προβολή περιεχομένου 18+", @"en" : @"View 18+ content",
    @"es" : @"Ver contenido 18+",      @"fi" : @"Näytä 18+ sisältö",        @"fr" : @"Voir le contenu 18+",
    @"he" : @"הצגת תוכן 18+",          @"hi" : @"18+ सामग्री देखें",          @"hu" : @"18+ tartalom megtekintése",
    @"id" : @"Lihat konten 18+",       @"it" : @"Mostra contenuti 18+",     @"ja" : @"18+コンテンツを表示",
    @"ko" : @"18+ 콘텐츠 보기",          @"nb" : @"Vis 18+ innhold",          @"nl" : @"18+ inhoud bekijken",
    @"pl" : @"Pokaż treści 18+",       @"pt" : @"Ver conteúdo 18+",         @"ro" : @"Vezi conținut 18+",
    @"ru" : @"Показать контент 18+",   @"sv" : @"Visa 18+ innehåll",        @"th" : @"ดูเนื้อหา 18+",
    @"tr" : @"18+ içeriği göster",     @"uk" : @"Показати вміст 18+",       @"vi" : @"Xem nội dung 18+",
    @"zh-Hans" : @"查看 18+ 内容",      @"zh-Hant" : @"查看 18+ 內容",
  };
  return texts[RLLanguageKey(texts)];
}

@interface RLCoverTarget : NSObject
@end

@implementation RLCoverTarget
- (void)coverTapped:(UITapGestureRecognizer *)recognizer {
  UIView *cover = recognizer.view;
  RLMarkPostRevealed(objc_getAssociatedObject(cover, &kPostKey));
  cover.hidden = YES;
  UIView *post = RLFeedPostOf(cover);
  if (post) RLUpdateFeedPost(post);
}
@end

static void pinToEdges(UIView *view, UIView *container) {
  view.translatesAutoresizingMaskIntoConstraints = NO;
  [NSLayoutConstraint activateConstraints:@[
    [view.topAnchor constraintEqualToAnchor:container.topAnchor],
    [view.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
    [view.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
    [view.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
  ]];
}

static UIView *makeCover(UIView *host) {
  static RLCoverTarget *target;
  if (!target) target = [RLCoverTarget new];
  UIView *cover = [UIView new];
  cover.tag = RLCoverTag;
  cover.clipsToBounds = YES;
  cover.layer.cornerRadius = 12;
  // Images finish loading after this, so the cover is kept above views added later.
  cover.layer.zPosition = 1000;
  [cover addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:target action:@selector(coverTapped:)]];

  UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
  blur.userInteractionEnabled = NO;
  [cover addSubview:blur];

  UILabel *button = [UILabel new];
  button.text = buttonText();
  button.font = [UIFont boldSystemFontOfSize:13];
  button.textColor = UIColor.whiteColor;
  button.textAlignment = NSTextAlignmentCenter;
  button.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
  button.clipsToBounds = YES;
  button.userInteractionEnabled = NO;
  CGSize size = [button sizeThatFits:CGSizeZero];
  CGFloat height = size.height + 14;
  button.layer.cornerRadius = height / 2;
  button.translatesAutoresizingMaskIntoConstraints = NO;
  [cover addSubview:button];

  // The host has no final size yet, so the layout is left to Auto Layout.
  [host addSubview:cover];
  pinToEdges(cover, host);
  pinToEdges(blur, cover);
  [NSLayoutConstraint activateConstraints:@[
    [button.widthAnchor constraintEqualToConstant:size.width + 24],
    [button.heightAnchor constraintEqualToConstant:height],
    [button.centerXAnchor constraintEqualToAnchor:cover.centerXAnchor],
    [button.centerYAnchor constraintEqualToAnchor:cover.centerYAnchor],
  ]];
  return cover;
}

// Corners are rounded on the host or on a view just inside it.
static CGFloat cornerRadiusOfContent(UIView *view, int depth) {
  CGFloat radius = view.layer.cornerRadius;
  if (radius > 0 || depth > 4) return radius;
  for (UIView *child in view.subviews) {
    if (child.tag != RLCoverTag) radius = MAX(radius, cornerRadiusOfContent(child, depth + 1));
  }
  return radius;
}

static void setCover(UIView *host, BOOL covered, NSString *key) {
  UIView *cover = nil;
  for (UIView *child in host.subviews)
    if (child.tag == RLCoverTag) cover = child;
  if (!covered) {
    cover.hidden = YES;
    return;
  }
  if (!cover) cover = makeCover(host);
  cover.hidden = NO;
  CGFloat radius = cornerRadiusOfContent(host, 0);
  if (radius > 0) cover.layer.cornerRadius = radius;
  objc_setAssociatedObject(cover, &kPostKey, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

// The media container spans the feed's width with the media inset inside it; the cover goes on the
// inner view so it matches the media.
static UIView *mediaContentView(UIView *view, int depth) {
  if (depth > 6) return nil;
  NSString *name = NSStringFromClass(view.class);
  if (depth > 0 && ([name hasSuffix:@"ServerImageSliceView"] || [name hasSuffix:@"CarouselSliceView"] || [name hasSuffix:@"LegacyVideoSliceView"]))
    return view;
  for (UIView *child in view.subviews) {
    UIView *found = mediaContentView(child, depth + 1);
    if (found) return found;
  }
  return nil;
}

static AVPlayerLayer *playerLayerIn(CALayer *layer, int depth) {
  if ([layer isKindOfClass:AVPlayerLayer.class]) return (AVPlayerLayer *)layer;
  if (depth > 3) return nil;
  for (CALayer *sublayer in layer.sublayers) {
    AVPlayerLayer *found = playerLayerIn(sublayer, depth + 1);
    if (found) return found;
  }
  return nil;
}

// A clip's player draws over everything below it, so it is hidden and paused while covered.
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

// The app can draw its own blur across a clip, which would stay after the cover is gone. Small
// blurred buttons in the player controls are left alone.
static void hideAppClipBlur(UIView *view, CGFloat clipWidth, int depth) {
  if (depth > 10 || view.tag == RLCoverTag) return;
  if ([view isKindOfClass:UIVisualEffectView.class]) {
    if (CGRectGetWidth(view.bounds) >= clipWidth * 0.8) view.hidden = YES;
    return;
  }
  for (UIView *child in view.subviews) hideAppClipBlur(child, clipWidth, depth + 1);
}

static BOOL isInsideOpenedPost(UIView *view) {
  for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
    if ([responder isKindOfClass:UIViewController.class] && [NSStringFromClass(responder.class) containsString:@"PDP"]) return YES;
  }
  return NO;
}

static void updateMedia(UIView *media, BOOL isTagged, NSString *key) {
  BOOL isClip = [NSStringFromClass(media.class) containsString:@"LegacyVideo"];
  BOOL serverBlurred = !isClip && RLServerBlurredPost(key);
  BOOL covered = (isTagged || serverBlurred) && !RLIsPostRevealed(key);
  // A post opened from a compact post shows the server's blurred copy with the app's own way of
  // revealing it; a cover on top would only leave that blur behind.
  if (!isClip && !serverBlurred && isInsideOpenedPost(media)) covered = NO;
  if (isClip) {
    hideAppClipBlur(media, CGRectGetWidth(media.bounds), 0);
    setClipBlocked(media, covered, 0);
  }
  UIView *content = mediaContentView(media, 0) ?: media;
  // The inner view can appear after a first pass that had to use the container.
  if (content != media) setCover(media, NO, key);
  setCover(content, covered, key);
}

static void updatePart(UIView *view, BOOL isTagged, NSString *key, int depth) {
  if (depth > 6) return;
  if (RLIsMediaContainer(view)) {
    updateMedia(view, isTagged, key);
    return;
  }
  NSString *name = NSStringFromClass(view.class);
  if ([name containsString:@"CustomPostOverlayContainerSliceView"]) {
    RLUpdateGameView(view, key);
    return;
  }
  if ([name containsString:@"TitleWithThumbnailSliceView"]) return;
  for (UIView *child in view.subviews) updatePart(child, isTagged, key, depth + 1);
}

static BOOL hasAdultTag(UIView *view, int depth) {
  if (depth > 12 || RLIsMediaContainer(view)) return NO;
  if ([view isKindOfClass:UILabel.class] && [((UILabel *)view).text containsString:@"18+"] &&
      [NSStringFromClass(view.superview.class) containsString:@"ContentTag"])
    return YES;
  for (UIView *child in view.subviews)
    if (hasAdultTag(child, depth + 1)) return YES;
  return NO;
}

void RLUpdateFeedPost(UIView *post) {
  NSString *longest = nil;
  // Without a known title, the post's longest text keeps a revealed post revealed while scrolling.
  NSString *key = RLPostKeyIn(post, &longest) ?: longest;
  updatePart(post, RLBlurEnabled() && hasAdultTag(post, 0), key, 0);
}

static void updateFeedPostsIn(UIView *view, int depth) {
  if (depth > 40) return;
  if ([view isKindOfClass:RLFeedPostClass()]) {
    RLUpdateFeedPost(view);
    return;
  }
  for (UIView *child in view.subviews) updateFeedPostsIn(child, depth + 1);
}

void RLUpdateAllFeedPosts(void) {
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class]) continue;
    for (UIWindow *window in ((UIWindowScene *)scene).windows) updateFeedPostsIn(window, 0);
  }
}

static UIView *coverAtPoint(UIView *view, UIView *post, CGPoint point, int depth) {
  if (depth > 14 || view.hidden) return nil;
  if (view.tag == RLCoverTag) return [view pointInside:[post convertPoint:point toView:view] withEvent:nil] ? view : nil;
  for (UIView *child in view.subviews) {
    UIView *found = coverAtPoint(child, post, point, depth + 1);
    if (found) return found;
  }
  return nil;
}

UIView *RLCoverAtPoint(UIView *post, CGPoint point) {
  return coverAtPoint(post, post, point, 0);
}
