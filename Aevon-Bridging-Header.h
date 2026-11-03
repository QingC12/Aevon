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

/// AevonScene.m — the calls that carry more arguments than `perform` can, plus
/// the two that have to read a non-object return value. Every one of them
/// answers nil / -1 / 0 rather than trapping, and the Swift side treats that as
/// "this system will not do it" and logs it.
void AevonEnumerateScenes(id _Nullable manager, void (^_Nullable block)(id _Nullable scene));
id _Nullable AevonSceneManager(void);
NSString *_Nullable AevonTakeNotes(void);

/// 0.0.16 / 0.0.22 — the mother ship's route: a scene's `uiPresentationManager`
/// asked for a presenter. A nil answer means "this system will not present it".
id _Nullable AevonCreatePresenter(id _Nullable manager,
                                  NSString *_Nullable identifier,
                                  NSInteger priority);

/// 0.0.18 — a BOOL getter read with the right ABI, -1 for "no such method".
NSInteger AevonBoolOf(id _Nullable object, NSString *_Nullable name);

/// 0.0.20 — run a no-argument void method: 1 for "ran", 0 for "no such method".
/// A call that never happened and a call that returned nil are otherwise
/// indistinguishable from Swift.
NSInteger AevonCallVoid(id _Nullable object, NSString *_Nullable name);

/// 0.0.27 — the mother ship's mechanism, installed as replacements instead of
/// relied on as getters. `AevonHookInstall` answers its own notes (a multi-line
/// string the caller writes to the log, selftest included); the summary is the
/// call counters, which are the only honest answer to "is the hook live".
NSString *AevonHookInstall(void);
NSString *AevonHookSummary(void);

/// Which scene may be held awake. Empty means nothing is held, which is the
/// state before the target is known and the state after the card is taken down.
void AevonHookArm(NSString *_Nullable bundle);
void AevonHookDisarm(void);

/// `-_deactivationReasonsForScene:withSettings:` as a number, `ULLONG_MAX` when
/// this system does not answer it. Zero and "absent" are different facts.
unsigned long long AevonReasonsOf(id _Nullable scene);

@interface UIImage (AevonPrivateIcons)
+ (nullable UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleID
                                                       format:(NSInteger)format
                                                        scale:(CGFloat)scale
    NS_SWIFT_NAME(aevonAppIcon(bundleID:format:scale:));
@end

NS_ASSUME_NONNULL_END
