//
//  AevonBoot.m — the only non-Swift file in the tweak.
//
//  Swift cannot declare a load-time constructor, and a dylib needs one.
//  So: three lines of C that call straight into Swift. Everything else,
//  including the gate check, is Swift.
//

#import <Foundation/Foundation.h>

extern void AevonStart(void);

__attribute__((constructor))
static void AevonBoot(void) {
    AevonStart();
}
