// Small helpers for text, languages and views, used by the other parts.
#import "RedditLegacy.h"

const NSInteger RLCoverTag = 0x52454444;
const NSInteger RLGameViewTag = 0x52454446;
const NSInteger RLDownloadRowTag = 0x52454445;

NSString *RLLanguageKey(NSDictionary *texts) {
  NSString *language = NSBundle.mainBundle.preferredLocalizations.firstObject ?: @"en";
  if (texts[language]) return language;
  if ([language hasPrefix:@"zh"]) {
    BOOL traditional = [language containsString:@"Hant"] || [language containsString:@"TW"] || [language containsString:@"HK"];
    return traditional ? @"zh-Hant" : @"zh-Hans";
  }
  NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@"-_"];
  NSString *base = [language componentsSeparatedByCharactersInSet:separators].firstObject;
  return texts[base] ? base : @"en";
}

NSString *RLNormalizedTitle(NSString *title) {
  NSArray<NSString *> *words = [title.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSPredicate *notEmpty = [NSPredicate predicateWithFormat:@"length > 0"];
  return [[words filteredArrayUsingPredicate:notEmpty] componentsJoinedByString:@" "];
}

NSString *RLTextOfView(UIView *view) {
  id text = [view respondsToSelector:@selector(text)] ? [(id)view text] : nil;
  if ([text isKindOfClass:NSString.class] && [text length]) return text;
  id attributed = [view respondsToSelector:@selector(attributedText)] ? [(id)view attributedText] : nil;
  if ([attributed isKindOfClass:NSAttributedString.class]) return [attributed string];
  return nil;
}

UIViewController *RLControllerOfView(UIView *view) {
  for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
    if ([responder isKindOfClass:UIViewController.class]) return (UIViewController *)responder;
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

UICollectionView *RLFirstCollectionView(UIView *view) {
  return firstCollectionView(view, 0);
}

Class RLFeedPostClass(void) {
  static Class feedPost;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ feedPost = NSClassFromString(@"FeedKit_Slices.FeedStackSliceView"); });
  return feedPost;
}

UIView *RLFeedPostOf(UIView *view) {
  Class feedPost = RLFeedPostClass();
  while (view && ![view isKindOfClass:feedPost]) view = view.superview;
  return view;
}

BOOL RLIsMediaContainer(UIView *view) {
  NSString *name = NSStringFromClass(view.class);
  return [name containsString:@"MediaInsetSliceView"] &&
         ([name containsString:@"ServerImage"] || [name containsString:@"Carousel"] || [name containsString:@"LegacyVideo"]);
}

void RLAfter(NSTimeInterval seconds, id object, void (^block)(id object)) {
  __weak id weakObject = object;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    id strongObject = weakObject;
    if (strongObject) block(strongObject);
  });
}
