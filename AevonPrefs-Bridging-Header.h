//
//  AevonPrefs-Bridging-Header.h
//
//  Declared, never linked. Preferences.framework is already loaded inside the
//  Settings process, and linking it would only add an install-time dependency.
//  Explicit nullability keeps the Swift import predictable, which matters
//  because we override two of these methods.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface PSSpecifier : NSObject
- (nullable id)propertyForKey:(NSString *)key;
- (void)setProperty:(nullable id)value forKey:(NSString *)key;
@end

@interface PSListController : UIViewController
- (nullable NSArray *)specifiers;
- (void)reloadSpecifiers;
- (nullable id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(nullable id)value specifier:(PSSpecifier *)specifier;
@end

NS_ASSUME_NONNULL_END
