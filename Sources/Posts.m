// What the tweak remembers about posts, taken from Reddit's responses and kept in memory only.
//
// Feed posts are found again on screen by their title, which is the only thing both the
// response and the view share. For each title it keeps whether the server wanted the media
// blurred, the post's clip and game, and its id. Post details the app asks for on its own add
// each post's video by id, which compact posts don't carry in the feed.
#import "RedditLegacy.h"

static NSObject *lock;
static NSMutableDictionary<NSString *, NSDictionary *> *feedPostsByTitle;
static NSMutableDictionary<NSString *, NSString *> *postIdsByTitle;
static NSMutableDictionary<NSString *, NSDictionary *> *clipsByPostId;
static NSMutableSet<NSString *> *revealedPosts;
static NSString *openedPostId;

__attribute__((constructor)) static void setUp(void) {
  lock = [NSObject new];
  feedPostsByTitle = [NSMutableDictionary dictionary];
  postIdsByTitle = [NSMutableDictionary dictionary];
  clipsByPostId = [NSMutableDictionary dictionary];
  revealedPosts = [NSMutableSet set];
}

static NSString *stringOrNil(id value) {
  return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
}

#pragma mark - Feed posts

// The post's id appears somewhere in its cells, alone or inside a longer id.
static NSString *postIdInGroup(NSDictionary *group) {
  static NSRegularExpression *pattern;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ pattern = [NSRegularExpression regularExpressionWithPattern:@"t3_[a-z0-9]{4,12}" options:0 error:nil]; });
  NSData *data = [NSJSONSerialization dataWithJSONObject:group options:0 error:nil];
  NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
  NSTextCheckingResult *match = text ? [pattern firstMatchInString:text options:0 range:NSMakeRange(0, text.length)] : nil;
  return match ? [text substringWithRange:match.range] : nil;
}

static BOOL isServerBlurred(id source) {
  return [source isKindOfClass:NSDictionary.class] && [source[@"isObfuscated"] isEqual:@YES];
}

void RLRememberFeedPost(NSDictionary *group) {
  NSArray *cells = group[@"cells"];
  if (![cells isKindOfClass:NSArray.class]) return;
  // A crosspost carries the original post's cells inside one of its own.
  NSMutableArray *allCells = [cells mutableCopy];
  for (NSDictionary *cell in cells) {
    id inner = [cell isKindOfClass:NSDictionary.class] ? cell[@"innerPost"] : nil;
    if ([inner isKindOfClass:NSDictionary.class] && [inner[@"cells"] isKindOfClass:NSArray.class]) [allCells addObjectsFromArray:inner[@"cells"]];
  }

  NSString *title = nil;
  NSString *otherTitle = nil;
  NSDictionary *clip = nil;
  NSDictionary *game = nil;
  BOOL blurred = NO;
  for (NSDictionary *cell in allCells) {
    if (![cell isKindOfClass:NSDictionary.class]) continue;
    NSString *type = cell[@"__typename"];
    if ([type isEqual:@"TitleCell"]) {
      title = title ?: stringOrNil(cell[@"title"]);
    } else {
      // Some layouts have no title cell: the title is then in another cell, such as the video's,
      // or in a title cell nested inside a compact post's cell.
      NSDictionary *nested = [cell[@"titleCell"] isKindOfClass:NSDictionary.class] ? cell[@"titleCell"] : nil;
      otherTitle = otherTitle ?: stringOrNil(cell[@"title"]) ?: stringOrNil(nested[@"title"]);
    }
    NSDictionary *video = [type isEqual:@"LegacyVideoCell"] && [cell[@"media"] isKindOfClass:NSDictionary.class] ? cell[@"media"] : nil;
    if (!clip && stringOrNil(video[@"path"])) clip = @{ @"path" : video[@"path"], @"isGif" : @([cell[@"isGif"] boolValue]) };
    if ([type isEqual:@"ImageCell"] && isServerBlurred(cell[@"media"])) blurred = YES;
    if ([type isEqual:@"GalleryCell"] && [cell[@"pages"] isKindOfClass:NSArray.class]) {
      for (NSDictionary *page in cell[@"pages"])
        if ([page isKindOfClass:NSDictionary.class] && isServerBlurred(page[@"image"])) blurred = YES;
    }
    NSDictionary *devvit = [type isEqual:@"CustomPostCell"] && [cell[@"post"] isKindOfClass:NSDictionary.class] ? cell[@"post"][@"devvit"] : nil;
    if ([devvit isKindOfClass:NSDictionary.class] && stringOrNil(devvit[@"webViewBaseUrl"]) && stringOrNil(devvit[@"webbitToken"])) {
      game = @{ @"base" : devvit[@"webViewBaseUrl"], @"token" : devvit[@"webbitToken"], @"post" : cell[@"post"] };
    }
  }
  title = title ?: otherTitle;
  if (!title) return;

  NSString *key = RLNormalizedTitle(title);
  NSMutableDictionary *post = [NSMutableDictionary dictionaryWithObject:@(blurred) forKey:@"blurred"];
  if (clip) post[@"clip"] = clip;
  if (game) post[@"game"] = game;
  NSString *postId = postIdInGroup(group);
  @synchronized(lock) {
    feedPostsByTitle[key] = post;
    if (postId) postIdsByTitle[key] = postId;
  }
}

#pragma mark - Post details

// The first address under `object` that passes `accept`. Blurred copies are skipped.
static NSString *findAddress(id object, BOOL (^accept)(NSURL *url), int depth) {
  if (depth > 8) return nil;
  if ([object isKindOfClass:NSDictionary.class]) {
    for (NSString *key in object) {
      if ([key hasPrefix:@"obfuscated"]) continue;
      NSString *found = findAddress(object[key], accept, depth + 1);
      if (found) return found;
    }
  } else if ([object isKindOfClass:NSArray.class]) {
    for (id item in object) {
      NSString *found = findAddress(item, accept, depth + 1);
      if (found) return found;
    }
  } else if ([object isKindOfClass:NSString.class] && [object hasPrefix:@"http"]) {
    NSURL *url = [NSURL URLWithString:object];
    if (url && accept(url)) return object;
  }
  return nil;
}

static BOOL hasTrueFlag(id object, NSString *flag, int depth) {
  if (depth > 6 || ![object isKindOfClass:NSDictionary.class]) return NO;
  if ([object[flag] isEqual:@YES]) return YES;
  for (NSString *key in object)
    if (hasTrueFlag(object[key], flag, depth + 1)) return YES;
  return NO;
}

// A post's video or GIF, or nil. The video itself comes first; "animated" is only a moving preview
// and "still" a picture, so neither decides what kind of post it is.
static NSDictionary *clipOfMedia(NSDictionary *media) {
  NSArray<NSString *> *videoParts = @[ @"streaming", @"video", @"packagedMedia", @"download" ];
  NSString *type = [media[@"typeHint"] isKindOfClass:NSString.class] ? [media[@"typeHint"] uppercaseString] : @"";
  BOOL isGif = [type containsString:@"GIF"];
  for (NSString *part in videoParts)
    if (hasTrueFlag(media[part], @"isGif", 0)) isGif = YES;

  // Reddit's own videos: any of their addresses leads to the whole set of streams.
  for (NSString *part in videoParts) {
    NSString *address = findAddress(media[part], ^BOOL(NSURL *url) { return [url.host isEqualToString:@"v.redd.it"] && url.pathComponents.count > 1; }, 0);
    if (address) {
      NSString *videoId = [NSURL URLWithString:address].pathComponents[1];
      return @{ @"path" : [NSString stringWithFormat:@"https://v.redd.it/%@/HLSPlaylist.m3u8", videoId], @"isGif" : @(isGif) };
    }
  }
  BOOL (^isVideoFile)(NSURL *) = ^BOOL(NSURL *url) {
    NSString *extension = url.pathExtension.lowercaseString;
    return [extension isEqualToString:@"mp4"] || [extension isEqualToString:@"m3u8"];
  };
  for (NSString *part in videoParts) {
    NSString *address = findAddress(media[part], isVideoFile, 0);
    if (address) return @{ @"path" : address, @"isGif" : @(isGif) };
  }
  // Only a post that really is a GIF is saved from its animated version.
  if ([type containsString:@"VIDEO"] && !isGif) return nil;
  NSString *animated = findAddress(media[@"animated"], isVideoFile, 0);
  if (animated) return @{ @"path" : animated, @"isGif" : @YES };
  NSString *gif = findAddress(media[@"animated"], ^BOOL(NSURL *url) { return [url.pathExtension.lowercaseString isEqualToString:@"gif"]; }, 0);
  if (gif && (isGif || [type containsString:@"IMAGE"] || type.length == 0)) return @{ @"path" : gif, @"isGif" : @YES };
  return nil;
}

void RLRememberPostDetails(NSDictionary *post) {
  NSString *postId = stringOrNil(post[@"id"]);
  NSDictionary *media = post[@"media"];
  if (![postId hasPrefix:@"t3_"] || ![media isKindOfClass:NSDictionary.class]) return;
  NSDictionary *clip = clipOfMedia(media);
  NSString *title = stringOrNil(post[@"title"]);
  @synchronized(lock) {
    if (clip) clipsByPostId[postId] = clip;
    if (title && !postIdsByTitle[RLNormalizedTitle(title)]) postIdsByTitle[RLNormalizedTitle(title)] = postId;
  }
}

void RLRememberOpenedPost(NSString *postId) {
  @synchronized(lock) {
    openedPostId = postId;
  }
}

#pragma mark - Questions

static NSString *postKeyIn(UIView *view, NSString **longestText, int depth) {
  if (depth > 16 || RLIsMediaContainer(view)) return nil;
  NSString *text = RLTextOfView(view);
  if (text.length) {
    NSString *title = RLNormalizedTitle(text);
    @synchronized(lock) {
      if (feedPostsByTitle[title] || postIdsByTitle[title]) return title;
    }
    if (longestText && title.length > (*longestText).length) *longestText = title;
  }
  for (UIView *child in view.subviews) {
    NSString *found = postKeyIn(child, longestText, depth + 1);
    if (found) return found;
  }
  return nil;
}

NSString *RLPostKeyIn(UIView *view, NSString **longestText) {
  return postKeyIn(view, longestText, 0);
}

BOOL RLServerBlurredPost(NSString *key) {
  if (!key) return NO;
  @synchronized(lock) {
    return [feedPostsByTitle[key][@"blurred"] boolValue];
  }
}

// The post details' clip comes first: it tells videos and GIFs apart best.
NSDictionary *RLClipOfPost(NSString *key) {
  if (!key) return nil;
  @synchronized(lock) {
    NSString *postId = postIdsByTitle[key];
    return (postId ? clipsByPostId[postId] : nil) ?: feedPostsByTitle[key][@"clip"];
  }
}

NSDictionary *RLClipOfOpenedPost(void) {
  @synchronized(lock) {
    return openedPostId ? clipsByPostId[openedPostId] : nil;
  }
}

NSDictionary *RLGameOfPost(NSString *key) {
  if (!key) return nil;
  @synchronized(lock) {
    return feedPostsByTitle[key][@"game"];
  }
}

void RLMarkPostRevealed(NSString *key) {
  if (!key) return;
  @synchronized(lock) {
    [revealedPosts addObject:key];
  }
}

BOOL RLIsPostRevealed(NSString *key) {
  if (!key) return NO;
  @synchronized(lock) {
    return [revealedPosts containsObject:key];
  }
}
