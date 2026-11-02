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

// Only the first two members are ever used (the diagnostic fallback group),
// and they are the ones that have never moved since iOS 3. The rest of the
// enum is deliberately not redeclared: guessing PSChildPaneSpecifier's value
// on a modern iOS is exactly the kind of guess that produces a broken list.
typedef NS_ENUM(NSInteger, PSCellType) {
    PSGroupCell = 0,
    PSLinkCell = 1,
    PSLinkListCell = 2,
    PSListItemCell = 3,
    PSTitleValueCell = 4,
    PSSliderCell = 5,
    PSSwitchCell = 6,
    PSStaticTextCell = 7,
    PSEditTextCell = 8,
    PSSegmentCell = 9,
    PSGiantIconCell = 10,
    PSGiantCell = 11,
    PSSecureEditTextCell = 12,
    PSButtonCell = 13,
    PSEditTextViewCell = 14,
    PSSpinnerCell = 15
};

@interface PSSpecifier : NSObject
+ (instancetype)emptyGroupSpecifier;
+ (instancetype)groupSpecifierWithName:(nullable NSString *)name;
- (nullable id)propertyForKey:(NSString *)key;
- (void)setProperty:(nullable id)value forKey:(NSString *)key;
@end

@interface PSListController : UIViewController

// `specifiers` is a real property backed by an ivar that Preferences reads
// directly in rowsForGroup: / specifierAtIndex:, so writing it through the
// setter is what actually makes rows appear. Overriding the getter alone
// leaves the ivar nil and the table empty — that was the 0.0.3 black screen.
// Declared nullable on purpose: the ivar really is nil until we fill it, and a
// nonnull annotation would make Swift force-unwrap it on first read.
@property (nonatomic, retain, nullable) NSMutableArray *specifiers;

- (nullable NSMutableArray *)loadSpecifiersFromPlistName:(NSString *)name
                                                  target:(nullable id)target;
- (nullable NSMutableArray *)loadSpecifiersFromPlistName:(NSString *)name
                                                  target:(nullable id)target
                                                  bundle:(nullable NSBundle *)bundle;

- (void)reload;
- (void)reloadSpecifiers;
- (nullable id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(nullable id)value specifier:(PSSpecifier *)specifier;

@end

NS_ASSUME_NONNULL_END
