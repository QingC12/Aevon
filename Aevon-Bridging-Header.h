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

/// 0.0.17 — the device, not a string table, answers what exists. Returns one
/// class name per line for every runtime class whose name contains one of the
/// comma-separated keys. Sends no message to any class.
NSString *_Nullable AevonFindClasses(NSString *_Nullable keys, NSInteger limit);

/// 0.0.18 — the mother ship's own chain, located instead of remembered.
/// `AevonSelectorHome` answers "which classes implement these selectors" with
/// `class_getInstanceMethod`, which sends no message; `AevonFullCensus` lists a
/// class's own methods with no filter; `AevonBoolOf` reads a BOOL getter with
/// the right ABI and returns -1 for "no such method".
NSString *_Nullable AevonSelectorHome(NSString *_Nullable selectors, NSInteger limit);
NSString *_Nullable AevonFullCensus(NSString *_Nullable name, NSInteger limit);
NSInteger AevonBoolOf(id _Nullable object, NSString *_Nullable name);

/// 0.0.19 — the mother ship was written for iOS 16 and this phone runs 17, so
/// every name she uses is a question rather than an assumption.
/// `AevonLayerNameScan` lists every method in the process whose selector
/// mentions a scene layer, a layer host or a context layer, with its real type
/// encoding; `AevonSelectorInfo` reports one selector on one class, the
/// encoding, and the class in the chain that actually defines it.
NSString *_Nullable AevonLayerNameScan(NSInteger limit);
NSString *_Nullable AevonSelectorInfo(NSString *_Nullable className,
                                      NSString *_Nullable selectors);

@interface UIImage (AevonPrivateIcons)
+ (nullable UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleID
                                                       format:(NSInteger)format
                                                        scale:(CGFloat)scale
    NS_SWIFT_NAME(aevonAppIcon(bundleID:format:scale:));
@end

NS_ASSUME_NONNULL_END
