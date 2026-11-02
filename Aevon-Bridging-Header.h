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

id _Nullable AevonCreatePresenter(id _Nullable manager,
                                  id _Nullable identifier,
                                  long long priority);

BOOL AevonAnswers(id _Nullable object, NSString *_Nullable name, NSInteger arguments);

void AevonEnumerateScenes(id _Nullable manager, void (^_Nullable block)(id _Nullable scene));

id _Nullable AevonSceneManager(void);

@interface UIImage (AevonPrivateIcons)
+ (nullable UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleID
                                                       format:(NSInteger)format
                                                        scale:(CGFloat)scale
    NS_SWIFT_NAME(aevonAppIcon(bundleID:format:scale:));
@end

NS_ASSUME_NONNULL_END
