// Weekly visitors where the online count used to be.
//
// Reddit no longer sends how many people are online, so this version of the app always shows zero.
// The current app shows the subreddit's weekly visitors in that place, next to the green dot, and so
// does this. The count is asked for with the account's own sign-in, once per subreddit.
#import "RedditLegacy.h"

NSString *const RLVisitorsPlaceholder = @"…";

static NSObject *lock;
static NSString *authorization;
static NSMutableDictionary<NSString *, NSNumber *> *visitorsBySubreddit;
static NSMutableSet<NSString *> *requestsInFlight;
static NSRegularExpression *zeroOnlineText;
static NSRegularExpression *zeroCountText;

__attribute__((constructor)) static void setUp(void) {
  lock = [NSObject new];
  visitorsBySubreddit = [NSMutableDictionary dictionary];
  requestsInFlight = [NSMutableSet set];
  zeroCountText = [NSRegularExpression regularExpressionWithPattern:@"^[\\s•·]*0(\\s|\\p{L})" options:0 error:nil];
  zeroOnlineText = [NSRegularExpression regularExpressionWithPattern:@"^[\\s•·]*(0|no|sin|ning[uú]n)\\s+((users?|usuarios?|personas?)\\s+)?"
                                                                     @"(online|conectad[oa]s?|en l[ií]nea)[\\s•·]*$"
                                                             options:NSRegularExpressionCaseInsensitive
                                                               error:nil];
}

void RLRememberAuthorization(NSURLRequest *request) {
  NSString *value = [request valueForHTTPHeaderField:@"Authorization"];
  if (![value hasPrefix:@"Bearer "]) return;
  @synchronized(lock) {
    authorization = value;
  }
}

static BOOL matches(NSRegularExpression *regex, NSString *text) {
  return [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)] != nil;
}

static BOOL isSubredditHeader(UIView *view) {
  NSString *name = NSStringFromClass(view.class);
  return [name containsString:@"SubredditHeaderView"] || [name containsString:@"SubredditScreenNavigationTitleView"];
}

// The subreddit's header or title bar that iew is in, if any.
static UIView *subredditHeaderOf(UIView *view) {
  for (; view; view = view.superview)
    if (isSubredditHeader(view)) return view;
  return nil;
}

// Recognised by its text, or otherwise by where it is: a short label starting with 0 in a
// subreddit's header or title bar. That keeps it working in any app language.
BOOL RLIsOnlineCount(UILabel *label, NSString *text) {
  if (text.length == 0 || text.length > 60) return NO;
  if (matches(zeroOnlineText, text)) return YES;
  return text.length <= 30 && matches(zeroCountText, text) && subredditHeaderOf(label) != nil;
}

static NSString *visitorsText(long long count) {
  NSDictionary<NSString *, NSArray<NSString *> *> *words = @{
    @"ar" : @[ @"زائر", @"زوار" ],                @"cs" : @[ @"návštěvník", @"návštěvníků" ],
    @"da" : @[ @"besøgende", @"besøgende" ],       @"de" : @[ @"Besucher", @"Besucher" ],
    @"el" : @[ @"επισκέπτης", @"επισκέπτες" ],     @"en" : @[ @"visitor", @"visitors" ],
    @"es" : @[ @"visitante", @"visitantes" ],      @"fi" : @[ @"kävijä", @"kävijää" ],
    @"fr" : @[ @"visiteur", @"visiteurs" ],        @"he" : @[ @"מבקר", @"מבקרים" ],
    @"hi" : @[ @"विज़िटर", @"विज़िटर" ],             @"hu" : @[ @"látogató", @"látogató" ],
    @"id" : @[ @"pengunjung", @"pengunjung" ],     @"it" : @[ @"visitatore", @"visitatori" ],
    @"ja" : @[ @"人の訪問者", @"人の訪問者" ],     @"ko" : @[ @"명 방문", @"명 방문" ],
    @"nb" : @[ @"besøkende", @"besøkende" ],       @"nl" : @[ @"bezoeker", @"bezoekers" ],
    @"pl" : @[ @"odwiedzający", @"odwiedzających" ], @"pt" : @[ @"visitante", @"visitantes" ],
    @"ro" : @[ @"vizitator", @"vizitatori" ],      @"ru" : @[ @"посетитель", @"посетителей" ],
    @"sv" : @[ @"besökare", @"besökare" ],         @"th" : @[ @"ผู้เยี่ยมชม", @"ผู้เยี่ยมชม" ],
    @"tr" : @[ @"ziyaretçi", @"ziyaretçi" ],       @"uk" : @[ @"відвідувач", @"відвідувачів" ],
    @"vi" : @[ @"khách truy cập", @"khách truy cập" ], @"zh-Hans" : @[ @"位访客", @"位访客" ],
    @"zh-Hant" : @[ @"位訪客", @"位訪客" ],
  };
  NSString *language = RLLanguageKey(words);
  NSNumberFormatter *formatter = [NSNumberFormatter new];
  formatter.locale = [NSLocale localeWithLocaleIdentifier:NSBundle.mainBundle.preferredLocalizations.firstObject ?: @"en"];
  formatter.numberStyle = NSNumberFormatterDecimalStyle;
  formatter.maximumFractionDigits = 1;
  NSString *number;
  if (count >= 1000000) number = [[formatter stringFromNumber:@(count / 100000 / 10.0)] stringByAppendingString:@"M"];
  else if (count >= 1000) number = [[formatter stringFromNumber:@(count / 100 / 10.0)] stringByAppendingString:@"K"];
  else number = [formatter stringFromNumber:@(count)];
  // These languages write the word right after the number.
  BOOL attached = [language isEqualToString:@"ja"] || [language isEqualToString:@"ko"] || [language hasPrefix:@"zh"];
  return [NSString stringWithFormat:attached ? @"%@%@" : @"%@ %@", number, words[language][count == 1 ? 0 : 1]];
}

// The header and the title bar both show "r/name" near the count.
static NSString *subredditNear(UILabel *label) {
  UIView *container = subredditHeaderOf(label) ?: label.superview;
  NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:container];
  while (queue.count) {
    UIView *view = queue.firstObject;
    [queue removeObjectAtIndex:0];
    NSString *text = [view isKindOfClass:UILabel.class] ? ((UILabel *)view).text : nil;
    if ([text hasPrefix:@"r/"] && text.length > 2) {
      return [[text substringFromIndex:2] componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].firstObject;
    }
    [queue addObjectsFromArray:view.subviews];
  }
  return nil;
}

static NSNumber *knownVisitors(NSString *subreddit) {
  if (!subreddit) return nil;
  @synchronized(lock) {
    return visitorsBySubreddit[subreddit.lowercaseString];
  }
}

NSString *RLKnownVisitorsText(UILabel *label) {
  NSNumber *count = knownVisitors(subredditNear(label));
  return count ? visitorsText(count.longLongValue) : nil;
}

static void fetchVisitors(NSString *subreddit, void (^completion)(BOOL found)) {
  NSString *key = subreddit.lowercaseString;
  NSString *signIn;
  @synchronized(lock) {
    if ([requestsInFlight containsObject:key]) return;
    [requestsInFlight addObject:key];
    signIn = authorization;
  }
  if (!signIn) {
    @synchronized(lock) {
      [requestsInFlight removeObject:key];
    }
    dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
    return;
  }
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://gql-fed.reddit.com/?SubredditInfoByName"]];
  request.HTTPMethod = @"POST";
  [request setValue:signIn forHTTPHeaderField:@"Authorization"];
  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  // The query reddit.com uses for a subreddit's details, which include its weekly visitors.
  NSDictionary *body = @{
    @"operationName" : @"SubredditInfoByName",
    @"variables" : @{ @"subredditName" : subreddit, @"filterGated" : @NO, @"includeRecapFields" : @NO, @"includeWelcomePage" : @NO, @"includeDevvitData" : @NO },
    @"extensions" : @{ @"persistedQuery" : @{ @"version" : @1, @"sha256Hash" : @"6b9c1679e69097e1c6df364adc11183afe6e2b6545dd1c0c1cc8f7490448c3e5" } },
  };
  request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
  [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    id count = [json isKindOfClass:NSDictionary.class] ? [json valueForKeyPath:@"data.subredditInfoByName.communityStats.weeklyActiveUsersCount"] : nil;
    BOOL found = [count isKindOfClass:NSNumber.class];
    @synchronized(lock) {
      [requestsInFlight removeObject:key];
      if (found) visitorsBySubreddit[key] = count;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ completion(found); });
  }] resume];
}

// Without a count, the green dot would stand alone next to an empty label.
static void hideOnlineDot(UILabel *label) {
  label.text = @"";
  RLAfter(0, label, ^(UILabel *strongLabel) {
    for (UIView *sibling in strongLabel.superview.subviews) {
      CGSize size = sibling.bounds.size;
      if (sibling != strongLabel && ![sibling isKindOfClass:UILabel.class] && size.width > 0 && size.width <= 14 && size.height > 0 && size.height <= 14)
        sibling.hidden = YES;
    }
  });
}

// The app sized the label for its old text, so its width is set again: through its own width
// constraint when it has one, or through its frame.
static void fitLabelWidth(UILabel *label) {
  CGFloat needed = ceil([label sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)].width);
  if (needed <= CGRectGetWidth(label.bounds)) return;
  BOOL adjusted = NO;
  for (NSLayoutConstraint *constraint in label.constraints) {
    if (constraint.firstItem == label && !constraint.secondItem && constraint.firstAttribute == NSLayoutAttributeWidth &&
        constraint.relation != NSLayoutRelationGreaterThanOrEqual) {
      constraint.constant = needed;
      adjusted = YES;
    }
  }
  if (!adjusted && label.translatesAutoresizingMaskIntoConstraints) {
    CGRect frame = label.frame;
    frame.size.width = needed;
    label.frame = frame;
  }
}

static void showVisitors(UILabel *label, NSString *text) {
  label.text = text;
  label.hidden = NO;
  label.alpha = 1;
  [label invalidateIntrinsicContentSize];
  fitLabelWidth(label);
  for (UIView *view = label.superview; view; view = view.superview) {
    [view setNeedsLayout];
    if (isSubredditHeader(view)) {
      [view layoutIfNeeded];
      break;
    }
  }
}

void RLDidShowVisitors(UILabel *label, NSString *visitors) {
  RLAfter(0, label, ^(UILabel *strongLabel) {
    if (visitors) {
      // Known already: only the size needs fixing, once the label has been laid out.
      if ([strongLabel.text isEqualToString:visitors]) showVisitors(strongLabel, visitors);
      return;
    }
    if (![strongLabel.text isEqualToString:RLVisitorsPlaceholder]) return;
    NSString *subreddit = subredditNear(strongLabel);
    if (!subreddit) {
      hideOnlineDot(strongLabel);
      return;
    }
    NSNumber *known = knownVisitors(subreddit);
    if (known) {
      showVisitors(strongLabel, visitorsText(known.longLongValue));
      return;
    }
    __weak UILabel *weakLabel = strongLabel;
    fetchVisitors(subreddit, ^(BOOL found) {
      UILabel *again = weakLabel;
      if (![again.text isEqualToString:RLVisitorsPlaceholder]) return;
      NSNumber *count = knownVisitors(subredditNear(again));
      if (found && count) showVisitors(again, visitorsText(count.longLongValue));
      else if (!found) hideOnlineDot(again);
    });
  });
}
