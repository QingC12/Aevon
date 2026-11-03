//
//  Aevon-Bridging-Header.h — SpringBoard side only.
//
//  The tweak target needs the same private icon selector the settings bundle
//  uses (RingIcons is compiled into both binaries so the two can never draw a
//  different ring). Only that one declaration belongs here: the tweak has no
//  business knowing about PSListController.
//
//  Everything is guarded by responds(to:) at the call site, so a system
//  without this selector falls back to the filesystem scan instead of crashing.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// AevonScene.m — the two private calls that carry more arguments than
/// `perform` can. Both return nil when the selector is absent, so the Swift
/// side treats "nil" as "this system will not do it" and logs it.
id _Nullable AevonCreateScene(id _Nullable manager,
                              id _Nullable definition,
                              id _Nullable settings,
                              id _Nullable clientSettings,
                              id _Nullable transitionContext,
                              id _Nullable remnant,
                              id _Nullable clientProvider,
                              void (^_Nullable completion)(id _Nullable scene,
                                                           id _Nullable error));

void AevonEnumerateScenes(id _Nullable manager, void (^_Nullable block)(id _Nullable scene));

/// Reading and rebuilding the pieces of a scene definition. Every one of these
/// answers nil/NO rather than trapping, and every attempt it makes is recorded
/// in the note buffer, which the caller drains with AevonTakeNotes before doing
/// anything that can take the process down.
NSString *_Nullable AevonTakeNotes(void);
NSString *_Nullable AevonClassCensus(NSString *_Nullable name, NSString *_Nullable keys);
id _Nullable AevonGetGetter(id _Nullable object, NSString *_Nullable name);
id _Nullable AevonGetIvar(id _Nullable object, NSString *_Nullable name);
BOOL AevonSetIvar(id _Nullable object, NSString *_Nullable name, id _Nullable value);
id _Nullable AevonMutableCopy(id _Nullable object);
id _Nullable AevonRenameIdentity(id _Nullable template, NSString *_Nullable identifier);
BOOL AevonSetIdentity(id _Nullable definition, id _Nullable identity);

id _Nullable AevonSceneManager(void);

/// 0.0.16 — the presenting route, which is the mother ship's own route: take a
/// live scene's `uiPresentationManager`, ask it for a presenter, take that
/// presenter's `presentationView`, and hand its layer to `_UIContextLayerHostView`.
/// None of these traps; a nil answer means "this system will not present it".
id _Nullable AevonCreatePresenter(id _Nullable manager,
                                  NSString *_Nullable identifier,
                                  NSInteger priority);
id _Nullable AevonLayerHost(id _Nullable layer);
BOOL AevonSetResizesHostedContext(id _Nullable view, BOOL flag);
BOOL AevonCan(id _Nullable object, NSString *_Nullable name);

@interface UIImage (AevonPrivateIcons)
+ (nullable UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleID
                                                       format:(NSInteger)format
                                                        scale:(CGFloat)scale
    NS_SWIFT_NAME(aevonAppIcon(bundleID:format:scale:));
@end

NS_ASSUME_NONNULL_END
