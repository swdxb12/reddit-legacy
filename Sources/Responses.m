// Rewrites Reddit's API responses before the app reads them:
//  - ads are emptied out;
//  - subreddits lose their NSFW label (it brings up a banner), while posts keep theirs;
//  - the app's own grey veil over 18+ images and clips is turned off, because Covers.m draws a
//    blur that one tap removes (the app's veil would stay behind it and need a second tap).
// Along the way it tells Posts.m about every post it sees.
#import "RedditLegacy.h"

static const NSUInteger kMaxResponseBytes = 20 * 1024 * 1024;
static const int kMaxDepth = 64;

static BOOL blurEnabled = YES;

BOOL RLBlurEnabled(void) {
  return blurEnabled;
}

BOOL RLIsAPIHost(NSString *host) {
  return [host hasSuffix:@"reddit.com"] && ([host hasPrefix:@"gql"] || [host hasPrefix:@"oauth"]);
}

NSString *RLOperationName(NSURLRequest *request) {
  NSString *name = [request valueForHTTPHeaderField:@"x-apollo-operation-name"];
  if (name.length) return name;
  if (!request.HTTPBody) return nil;
  id body = [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:nil];
  if ([body isKindOfClass:NSDictionary.class] && [body[@"operationName"] isKindOfClass:NSString.class]) return body[@"operationName"];
  return nil;
}

// Ad containers are emptied in place. Each field keeps its JSON type, because the app rejects a
// response whose field types change.
static BOOL removeAds(NSMutableDictionary *dict) {
  BOOL changed = NO;
  if ([dict[@"__typename"] isEqual:@"AdPost"] && ![dict[@"isHidden"] isEqual:@YES]) {
    dict[@"isHidden"] = @YES;
    changed = YES;
  }
  id cells = dict[@"cells"];
  if ([dict[@"adPayload"] isKindOfClass:NSDictionary.class] && [cells isKindOfClass:NSArray.class] && [cells count] > 0) {
    dict[@"cells"] = @[];
    changed = YES;
  }
  for (NSString *key in @[ @"adPosts", @"commentsPageAds", @"commentTreeAds", @"pdpCommentsAds" ]) {
    id ads = dict[key];
    if ([ads isKindOfClass:NSArray.class] && [ads count] > 0) {
      dict[key] = @[];
      changed = YES;
    }
  }
  return changed;
}

static BOOL isSubreddit(NSDictionary *dict, NSString *path) {
  if ([dict[@"__typename"] isEqual:@"Subreddit"]) return YES;
  return [[path componentsSeparatedByString:@"."].lastObject hasPrefix:@"subreddit"];
}

// Highlight cards show an NSFW circle instead of the avatar when the author's profile is NSFW, even
// if the post isn't. The post's own 18+ tag is what should say so.
static BOOL isHighlightAuthorProfile(NSString *path) {
  return [path containsString:@"highlightedPosts"] && [path hasSuffix:@"authorInfo.profile"];
}

// The image and clip sources of a feed cell that the app may draw its own veil over.
static NSArray *mediaSourcesOfCell(NSDictionary *cell) {
  NSString *type = cell[@"__typename"];
  NSMutableArray *sources = [NSMutableArray array];
  if ([type isEqual:@"LegacyVideoCell"]) {
    if (cell[@"media"]) [sources addObject:cell[@"media"]];
    if (cell[@"preview"]) [sources addObject:cell[@"preview"]];
  } else if ([type isEqual:@"ImageCell"]) {
    if (cell[@"media"]) [sources addObject:cell[@"media"]];
  } else if ([type isEqual:@"GalleryCell"] && [cell[@"pages"] isKindOfClass:NSArray.class]) {
    for (NSDictionary *page in cell[@"pages"])
      if ([page isKindOfClass:NSDictionary.class] && page[@"image"]) [sources addObject:page[@"image"]];
  }
  return sources;
}

static BOOL rewrite(id object, NSString *path, int depth) {
  if (depth > kMaxDepth) return NO;
  BOOL changed = NO;
  if ([object isKindOfClass:NSArray.class]) {
    for (id item in (NSArray *)object)
      if (rewrite(item, path, depth + 1)) changed = YES;
    return changed;
  }
  if (![object isKindOfClass:NSMutableDictionary.class]) return NO;
  NSMutableDictionary *dict = object;

  if (removeAds(dict)) changed = YES;
  if ([dict[@"__typename"] isEqual:@"CellGroup"]) RLRememberFeedPost(dict);
  if (dict[@"media"]) RLRememberPostDetails(dict);
  if ([path isEqualToString:@"$.data.postInfoById"] && [dict[@"id"] isKindOfClass:NSString.class]) RLRememberOpenedPost(dict[@"id"]);

  for (NSString *key in dict.allKeys) {
    id value = dict[key];
    NSString *keyPath = [path stringByAppendingFormat:@".%@", key];
    if ([key isEqualToString:@"isNsfwMediaBlocked"] && [value isKindOfClass:NSNumber.class]) blurEnabled = [value boolValue];
    BOOL isNsfwLabel = [key isEqualToString:@"isNsfw"] && [value isEqual:@YES];
    if (isNsfwLabel && (isSubreddit(dict, path) || isHighlightAuthorProfile(path))) {
      dict[key] = @NO;
      changed = YES;
    } else if (rewrite(value, keyPath, depth + 1)) {
      changed = YES;
    }
  }

  // Highlight cards also take an NSFW mark from their thumbnail's own flag, which can be set for
  // posts that aren't NSFW. The post's flag is the one that counts.
  NSMutableDictionary *thumbnail = dict[@"thumbnailV2"];
  if ([thumbnail isKindOfClass:NSMutableDictionary.class] && [dict[@"isNsfw"] isEqual:@NO] && [thumbnail[@"isObfuscatedDefault"] isEqual:@YES]) {
    thumbnail[@"isObfuscatedDefault"] = @NO;
    changed = YES;
  }

  for (NSMutableDictionary *source in mediaSourcesOfCell(dict)) {
    if ([source isKindOfClass:NSMutableDictionary.class] && [source[@"isObfuscated"] isEqual:@YES]) {
      source[@"isObfuscated"] = @NO;
      changed = YES;
    }
  }
  return changed;
}

NSData *RLProcessResponse(NSURLRequest *request, NSData *data) {
  if (!RLIsAPIHost(request.URL.host) || data.length == 0 || data.length > kMaxResponseBytes) return data;
  id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
  if (!json || !rewrite(json, @"$", 0)) return data;
  // If the rewrite can't be encoded, the original response is used, so the request still works.
  return [NSJSONSerialization dataWithJSONObject:json options:0 error:nil] ?: data;
}
