// The "Download video" / "Download GIF" row in a post's "more actions" sheet.
//
// The sheet doesn't say which post it belongs to, so the post is worked out from where it opened:
// the video on screen in the full-screen player, the opened post, or the feed post last touched.
// Reddit's own videos are streams; the best video and audio files beside the stream are downloaded
// and joined. GIFs are saved from their original file rather than the shrunken preview.
#import "RedditLegacy.h"
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>

static char kRowClipKey;
static char kRowAnchorKey;
static char kRowHeightKey;
static __weak UIView *lastTouchedPost;

void RLRememberTouchedPost(UIView *post) {
  lastTouchedPost = post;
}

#pragma mark - Texts and notices

typedef NS_ENUM(NSUInteger, DownloadText) {
  DownloadTextGif,
  DownloadTextVideo,
  DownloadTextInProgress,
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
  return texts[RLLanguageKey(texts)][which];
}

static void showNotice(DownloadText which) {
  dispatch_async(dispatch_get_main_queue(), ^{
    static UILabel *notice;
    static NSUInteger generation;
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
      if (![scene isKindOfClass:UIWindowScene.class]) continue;
      for (UIWindow *candidate in ((UIWindowScene *)scene).windows)
        if (candidate.isKeyWindow) window = candidate;
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
    notice.text = downloadText(which);
    CGSize size = [notice sizeThatFits:CGSizeZero];
    CGFloat height = size.height + 18;
    CGFloat width = MIN(size.width + 32, CGRectGetWidth(window.bounds) - 32);
    notice.layer.cornerRadius = height / 2;
    notice.frame = CGRectMake((CGRectGetWidth(window.bounds) - width) / 2, CGRectGetHeight(window.bounds) - window.safeAreaInsets.bottom - 110, width, height);
    [window addSubview:notice];
    NSUInteger current = ++generation;
    RLAfter(3, notice, ^(UILabel *label) {
      if (current == generation) [label removeFromSuperview];
    });
  });
}

#pragma mark - Saving

static NSURL *temporaryFile(NSString *extension) {
  NSString *name = [NSUUID.UUID.UUIDString stringByAppendingPathExtension:extension];
  return [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
}

static void removeFiles(NSArray<NSURL *> *files) {
  for (NSURL *file in files) [NSFileManager.defaultManager removeItemAtURL:file error:nil];
}

// Saves `file` to Photos and then removes the temporary files.
static void saveToPhotos(NSURL *file, BOOL isPicture, NSArray<NSURL *> *temporary) {
  void (^finish)(BOOL) = ^(BOOL saved) {
    removeFiles(temporary);
    showNotice(saved ? DownloadTextSaved : DownloadTextFailed);
  };
  // iOS ends an app that asks for Photos access without saying why in its Info.plist.
  NSDictionary *info = NSBundle.mainBundle.infoDictionary;
  if (!info[@"NSPhotoLibraryAddUsageDescription"] && !info[@"NSPhotoLibraryUsageDescription"]) {
    finish(NO);
    return;
  }
  [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus status) {
    if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) {
      finish(NO);
      return;
    }
    [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
      PHAssetResourceType type = isPicture ? PHAssetResourceTypePhoto : PHAssetResourceTypeVideo;
      [[PHAssetCreationRequest creationRequestForAsset] addResourceWithType:type fileURL:file options:nil];
    } completionHandler:^(BOOL success, NSError *error) {
      finish(success);
    }];
  }];
}

// Downloads an address to a temporary file; nil unless the server sent a media file.
static void downloadFile(NSURL *url, void (^completion)(NSURL *file, NSString *type)) {
  [[NSURLSession.sharedSession downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
    NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
    NSString *type = response.MIMEType.lowercaseString ?: @"";
    BOOL isMedia = [type hasPrefix:@"video/"] || [type hasPrefix:@"image/"] || [type hasPrefix:@"audio/"] || [type containsString:@"mp4"];
    NSURL *file = temporaryFile([type containsString:@"gif"] ? @"gif" : @"mp4");
    if (error || !location || status < 200 || status >= 300 || !isMedia || ![NSFileManager.defaultManager moveItemAtURL:location toURL:file error:nil]) {
      completion(nil, nil);
      return;
    }
    completion(file, type);
  }] resume];
}

static void downloadFirstAvailable(NSURL *folder, NSArray<NSString *> *names, NSUInteger index, void (^completion)(NSURL *file)) {
  if (index >= names.count) {
    completion(nil);
    return;
  }
  downloadFile([folder URLByAppendingPathComponent:names[index]], ^(NSURL *file, NSString *type) {
    if (file) completion(file);
    else downloadFirstAvailable(folder, names, index + 1, completion);
  });
}

// Joins a video file and its sound into one file, without re-encoding.
static void joinAndSave(NSURL *video, NSURL *audio) {
  AVURLAsset *videoAsset = [AVURLAsset assetWithURL:video];
  AVURLAsset *audioAsset = [AVURLAsset assetWithURL:audio];
  AVAssetTrack *videoTrack = [videoAsset tracksWithMediaType:AVMediaTypeVideo].firstObject;
  AVAssetTrack *audioTrack = [audioAsset tracksWithMediaType:AVMediaTypeAudio].firstObject;
  if (!videoTrack || !audioTrack) {
    saveToPhotos(video, NO, @[ video, audio ]);
    return;
  }
  AVMutableComposition *composition = [AVMutableComposition composition];
  AVMutableCompositionTrack *videoOut = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
  AVMutableCompositionTrack *audioOut = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
  [videoOut insertTimeRange:CMTimeRangeMake(kCMTimeZero, videoAsset.duration) ofTrack:videoTrack atTime:kCMTimeZero error:nil];
  [audioOut insertTimeRange:CMTimeRangeMake(kCMTimeZero, CMTimeMinimum(videoAsset.duration, audioAsset.duration)) ofTrack:audioTrack atTime:kCMTimeZero error:nil];
  videoOut.preferredTransform = videoTrack.preferredTransform;

  AVAssetExportSession *export = [AVAssetExportSession exportSessionWithAsset:composition presetName:AVAssetExportPresetPassthrough];
  NSURL *output = temporaryFile(@"mp4");
  export.outputURL = output;
  export.outputFileType = AVFileTypeMPEG4;
  [export exportAsynchronouslyWithCompletionHandler:^{
    if (export.status == AVAssetExportSessionStatusCompleted) {
      saveToPhotos(output, NO, @[ video, audio, output ]);
    } else {
      // A clip without its sound is better than no clip.
      removeFiles(@[ audio, output ]);
      saveToPhotos(video, NO, @[ video ]);
    }
  }];
}

// The names of the stream's video and audio files, best first. The video's own list of qualities
// (its DASH manifest) gives every file with its bit rate; common names follow in case it can't be read.
static void streamFileNames(NSURL *folder, void (^completion)(NSArray<NSString *> *videos, NSArray<NSString *> *audios)) {
  [[NSURLSession.sharedSession dataTaskWithURL:[folder URLByAppendingPathComponent:@"DASHPlaylist.mpd"]
                             completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    NSString *manifest = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    NSMutableArray<NSDictionary *> *videos = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *audios = [NSMutableArray array];
    for (NSString *representation in [manifest componentsSeparatedByString:@"<Representation"]) {
      NSRange open = [representation rangeOfString:@"<BaseURL>"];
      NSRange close = [representation rangeOfString:@"</BaseURL>"];
      if (open.location == NSNotFound || close.location == NSNotFound || close.location <= NSMaxRange(open)) continue;
      NSString *name = [[representation substringWithRange:NSMakeRange(NSMaxRange(open), close.location - NSMaxRange(open))]
          stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
      if (!name.length || [name containsString:@"/"]) continue;
      NSRange rate = [representation rangeOfString:@"bandwidth=\""];
      long long bitRate = rate.location == NSNotFound ? 0 : [[representation substringFromIndex:NSMaxRange(rate)] longLongValue];
      BOOL isAudio = [name rangeOfString:@"audio" options:NSCaseInsensitiveSearch].location != NSNotFound;
      [(isAudio ? audios : videos) addObject:@{ @"name" : name, @"rate" : @(bitRate) }];
    }
    NSArray *best = @[ [NSSortDescriptor sortDescriptorWithKey:@"rate" ascending:NO] ];
    NSMutableArray<NSString *> *videoNames = [[[videos sortedArrayUsingDescriptors:best] valueForKey:@"name"] mutableCopy];
    NSMutableArray<NSString *> *audioNames = [[[audios sortedArrayUsingDescriptors:best] valueForKey:@"name"] mutableCopy];
    for (NSString *size in @[ @"2160", @"1440", @"1080", @"720", @"480", @"360", @"270", @"240", @"220" ]) {
      for (NSString *prefix in @[ @"CMAF", @"DASH" ]) {
        NSString *name = [NSString stringWithFormat:@"%@_%@.mp4", prefix, size];
        if (![videoNames containsObject:name]) [videoNames addObject:name];
      }
    }
    for (NSString *name in @[ @"CMAF_AUDIO_128.mp4", @"DASH_AUDIO_128.mp4", @"CMAF_AUDIO_64.mp4", @"DASH_AUDIO_64.mp4", @"DASH_audio.mp4" ])
      if (![audioNames containsObject:name]) [audioNames addObject:name];
    completion(videoNames, audioNames);
  }] resume];
}

static void downloadStream(NSURL *playlist) {
  NSURLComponents *components = [NSURLComponents componentsWithURL:playlist resolvingAgainstBaseURL:NO];
  components.query = nil;
  NSURL *folder = components.URL.URLByDeletingLastPathComponent;
  streamFileNames(folder, ^(NSArray<NSString *> *videos, NSArray<NSString *> *audios) {
    downloadFirstAvailable(folder, videos, 0, ^(NSURL *video) {
      if (!video) {
        showNotice(DownloadTextFailed);
        return;
      }
      downloadFirstAvailable(folder, audios, 0, ^(NSURL *audio) {
        if (audio) joinAndSave(video, audio);
        else saveToPhotos(video, NO, @[ video ]);
      });
    });
  });
}

static void downloadSingleFile(NSURL *url, void (^failed)(void)) {
  downloadFile(url, ^(NSURL *file, NSString *type) {
    if (file) saveToPhotos(file, [type hasPrefix:@"image/"], @[ file ]);
    else failed();
  });
}

static void downloadClip(NSDictionary *clip) {
  NSURL *url = [NSURL URLWithString:clip[@"path"]];
  if (!url) {
    showNotice(DownloadTextFailed);
    return;
  }
  showNotice(DownloadTextInProgress);
  if ([url.pathExtension.lowercaseString isEqualToString:@"m3u8"]) {
    downloadStream(url);
    return;
  }
  void (^failed)(void) = ^{ showNotice(DownloadTextFailed); };
  // A GIF's preview address gives a shrunken copy; the original is on i.redd.it under the same name.
  if ([url.host isEqualToString:@"preview.redd.it"] && [url.pathExtension.lowercaseString isEqualToString:@"gif"]) {
    NSURL *original = [NSURL URLWithString:[@"https://i.redd.it/" stringByAppendingString:url.lastPathComponent]];
    downloadSingleFile(original, ^{ downloadSingleFile(url, failed); });
    return;
  }
  downloadSingleFile(url, failed);
}

#pragma mark - The row in the sheet

@interface RLDownloadRowTarget : NSObject
@end

@implementation RLDownloadRowTarget
- (void)rowTapped:(UIControl *)row {
  NSDictionary *clip = objc_getAssociatedObject(row, &kRowClipKey);
  UIViewController *sheet = RLControllerOfView(row);
  while (sheet.parentViewController) sheet = sheet.parentViewController;
  if (!clip || !sheet) return;
  [sheet dismissViewControllerAnimated:YES completion:^{ downloadClip(clip); }];
}
@end

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

// The app's "Save" row, found by its word in the app's language. If the word isn't known, the
// second row is used, which is where that row normally is.
static UILabel *saveRowLabel(NSArray<UILabel *> *labels) {
  NSArray<NSString *> *words = @[
    @"guardar", @"save", @"salvar", @"enregistrer", @"sauvegarder", @"speichern", @"salva", @"opslaan", @"spara", @"gem",
    @"lagre", @"tallenna", @"zapisz", @"uložit", @"kaydet", @"сохран", @"збере", @"保存", @"儲存", @"저장", @"حفظ", @"שמור",
    @"simpan", @"lưu", @"mentés", @"salvează", @"αποθήκευση", @"บันทึก", @"सहेज",
  ];
  for (UILabel *label in labels) {
    NSString *text = label.text.lowercaseString;
    for (NSString *word in words)
      if ([text hasPrefix:word]) return label;
  }
  return labels.count > 1 ? labels[1] : labels.firstObject;
}

static UICollectionViewCell *cellOfView(UIView *view) {
  while (view && ![view isKindOfClass:UICollectionViewCell.class]) view = view.superview;
  return (UICollectionViewCell *)view;
}

// The rows below the new one are moved down each time the list lays out, because it keeps reusing
// them. A view's center ignores this offset, so it still gives the row's real place.
void RLKeepDownloadRowInPlace(UICollectionView *list) {
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
  if ([list viewWithTag:RLDownloadRowTag]) return;
  NSMutableArray<UILabel *> *labels = [NSMutableArray array];
  for (UICollectionViewCell *cell in list.visibleCells) collectRowLabels(cell, labels, 0);
  [labels sortUsingComparator:^NSComparisonResult(UILabel *a, UILabel *b) {
    return [@([a convertPoint:CGPointZero toView:list].y) compare:@([b convertPoint:CGPointZero toView:list].y)];
  }];
  UILabel *model = saveRowLabel(labels);
  UICollectionViewCell *modelCell = cellOfView(model);
  if (!model || !modelCell) return;

  static RLDownloadRowTarget *target;
  if (!target) target = [RLDownloadRowTarget new];
  CGFloat width = CGRectGetWidth(list.bounds);
  CGFloat height = CGRectGetHeight(modelCell.bounds);
  CGFloat anchor = modelCell.center.y + height / 2;
  CGRect labelFrame = [model convertRect:model.bounds toView:modelCell];
  UIImageView *modelIcon = firstIconIn(modelCell, 0);
  CGRect iconFrame = modelIcon ? [modelIcon convertRect:modelIcon.bounds toView:modelCell] : CGRectMake(16, (height - 24) / 2, 24, 24);

  UIControl *row = [[UIControl alloc] initWithFrame:CGRectMake(0, anchor, width, height)];
  row.tag = RLDownloadRowTag;
  row.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  objc_setAssociatedObject(row, &kRowClipKey, clip, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [row addTarget:target action:@selector(rowTapped:) forControlEvents:UIControlEventTouchUpInside];

  UIImageSymbolConfiguration *symbol = [UIImageSymbolConfiguration configurationWithPointSize:CGRectGetHeight(iconFrame) * 0.72];
  UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.down.to.line" withConfiguration:symbol]];
  icon.tintColor = modelIcon.tintColor ?: model.textColor;
  icon.contentMode = UIViewContentModeCenter;
  icon.frame = iconFrame;
  icon.userInteractionEnabled = NO;
  [row addSubview:icon];

  UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(CGRectGetMinX(labelFrame), CGRectGetMinY(labelFrame),
                                                             width - CGRectGetMinX(labelFrame) - 16, CGRectGetHeight(labelFrame))];
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
  RLKeepDownloadRowInPlace(list);
}

// The list is built after the sheet appears, so it is looked for over the first moments.
static void showDownloadRow(UIViewController *sheet, NSDictionary *clip) {
  for (NSNumber *delay in @[ @0, @0.2, @0.45, @0.8, @1.3 ]) {
    RLAfter(delay.doubleValue, sheet, ^(UIViewController *strongSheet) {
      if (!strongSheet.isViewLoaded) return;
      UICollectionView *list = RLFirstCollectionView(strongSheet.view);
      if (list && CGRectGetWidth(list.bounds) > 0 && list.visibleCells.count > 0) addDownloadRow(list, clip);
    });
  }
}

#pragma mark - Which post the sheet is for

static UIViewController *visibleController(UIViewController *controller, NSString *name, UIViewController *except, int depth) {
  if (!controller || controller == except || depth > 12) return nil;
  if ([NSStringFromClass(controller.class) containsString:name] && controller.viewIfLoaded.window) return controller;
  for (UIViewController *child in controller.childViewControllers) {
    UIViewController *found = visibleController(child, name, except, depth + 1);
    if (found) return found;
  }
  return visibleController(controller.presentedViewController, name, except, depth + 1);
}

// The full-screen player pages through videos; the one filling the screen is the current one.
static NSDictionary *clipOfVideoPlayer(UIViewController *player) {
  UICollectionView *list = RLFirstCollectionView(player.view);
  UIView *page = list ? nil : player.view;
  CGPoint center = CGPointMake(CGRectGetMidX(list.bounds), CGRectGetMidY(list.bounds));
  for (UICollectionViewCell *cell in list.visibleCells)
    if (CGRectContainsPoint(cell.frame, center)) page = cell;
  return page ? RLClipOfPost(RLPostKeyIn(page, NULL)) : nil;
}

void RLOfferDownloadInSheet(UIViewController *sheet) {
  UIViewController *root = sheet.presentingViewController;
  while (root.presentingViewController) root = root.presentingViewController;

  NSDictionary *clip = nil;
  UIViewController *player = visibleController(root, @"Video_FBP", sheet, 0);
  if (player) clip = clipOfVideoPlayer(player);
  if (!clip && visibleController(root, @"PDPViewController", sheet, 0)) clip = RLClipOfOpenedPost();
  if (!clip && lastTouchedPost.window) clip = RLClipOfPost(RLPostKeyIn(lastTouchedPost, NULL));
  if (clip) showDownloadRow(sheet, clip);
}
