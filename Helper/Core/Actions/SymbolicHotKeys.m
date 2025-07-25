//
// --------------------------------------------------------------------------
// SymbolicHotKeys.m
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2024
// Licensed under Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//

/**
    System features such as 'Open Mission Control' have an associated identifier which is called the *SymbolicHotKey* or SHK.
    In macOS' APIs, *SymbolicHotKeys* are used to map keyboard shortcuts and mouse buttons to the associated system features.
    
    We hijack the SHK system to trigger macOS features programmatically.
    
    Steps: (Nov 2024)
         1. Look up which keyboard shortcut is associated with the system feature we want to trigger
         2. (If there is no usable keyboard shortcut, modify the `keyboard shortcut -> system feature` map.)
         3. Simulate the keyboard shortcut – which will trigger the desired system feature
         4. (In case it was modified - reset the `keyboard shortcut -> system feature` map.)
         
    Alternatives:
        - There are also SHKs for mouse buttons – not only for keyboard shortcuts. We could possibly use those directly.
            (Src: the `type: button` entries inside ~/Library/Preferences/com.apple.symbolichotkeys.plist)
        - In IOKit there's `IOHIDEventCreateSymbolicHotKeyEvent()` - this sounds like a promising way to simplify triggering of SHKs
            (But we'd first have to figure out how to use that function and how to convert from `IOHIDEvent` to `CGEvent`, so it might take a while.)
            (Also see `CGEventHIDEventBridge.h`)
        - Public HIToolbox APIs such as`CopySymbolicHotKeys()`
            I think these are more for registering new SHKs for the current app, not for modifying/triggering global SHK – but I haven't tested them, yet.
    
     Discussion:
         We implemented the SymbolicHotKey stuff really early in development (for MMF 1) the Apple Note below documents some of our thinking at the time.
    
    ----------------------------------------------
    
     Original Apple Note from 22.11.2018:
     
        Switching Spaces through Private API

        - [x] SOLVED - using symbolic hotkey private api

        Ways to go forward:
        * Try to really understand how other apps do it
        * Use CGSConnection.h to create custom symbolic hotkey, which we then trigger via CGEvent
            * private API not fully documented, pretty sure that we’d have to overridde existing hotkey, and/or activate it globally
        * Find way to make CGSSpace.h work properly
            * feel like I tried everything
        * Try to find, reverse engineer and emulate executable that parses symbolic hotkeys
            * (**harrrrrd**)

        Keyboard Shortcut Preferences File
        /Users/Noah/Library/Preferences/com.apple.symbolichotkeys.plist

        control key mask:
        * 0x040000:	262144
        * 0x840000:	8650752

        * left space: 		79
        * right space:		81
        * mission control: 	32
        * show all windows: 	33

        GitHub Projects that can do it:

            * [Demo of Spaces API discovered through RE](https://gist.github.com/puffnfresh/4054059) - old, no switching
            * [Spaces.h](https://github.com/NUIKit/CGSInternal/blob/master/CGSSpace.h) - “header for private Spaces Routines”

            * [hs._asm.undocumented.spaces](https://github.com/asmagill/hs._asm.undocumented.spaces) - Hammerspoon module for Space Switching functionality (built on Spaces.h) - relies on killing Dock, no animtions
            * [Hammerspoon](https://github.com/Hammerspoon/hammerspoon/tree/0.9.70) - “bridge between macOS and Lua Lang” (built on hs._asm.)

            * [Silica](https://github.com/ianyh/Silica/blob/master/Silica/CGSSpaces.h) - “window management framework” (interacts with private API but doesn't do space switching I believe)
            * [Amethyst](https://github.com/ianyh/Amethyst) - “window manager app” - “built on Silica”

        Steer Mouse Reverse Engineering:
            PS804ActionClass

*/

#import "WannaBePrefixHeader.h"
#import "SymbolicHotKeys.h"
#import "HelperUtility.h"
#import <Carbon/Carbon.h>
#import "SharedUtility.h"
#import "EventLoggerForBradMacros.h"

@implementation SymbolicHotKeys

/// Define extern CGS function
///     All the other extern functions we need are already defined in `CGSHotKeys.h`
CG_EXTERN CGError CGSSetSymbolicHotKeyValue(CGSSymbolicHotKey hotKey, unichar keyEquivalent, CGKeyCode virtualKeyCode, CGSModifierFlags modifiers);


/**
    Define constants
     
        TODO: (This is a dependency of searchVKCForStr) Delete this when copying over KeyboardSimulator.h from EventLoggerForBrad.

 */

    #define kMFKeyEquivalentNull            ((unichar)65535)
    #define kMFModifierFlagsNull            (0)                          /// We're using this with the types `CGSModifierFlags` and `CGEventFlags`
    #define kMFVK_Null                      ((CGKeyCode)65535)
    #define kMFHIDUsage_KeyboardNull        ((uint16_t)0)                /// Related constants are defined in IOKit e.g. `kHIDUsage_KeyboardA`
    #define kMFVK_FirstAppleKey             0x80

/// Define 'outOfReach' vkc
    #define kMFVK_OutOfReach                ((CGKeyCode)400)             /// I don't think I've seen a vkc above 200 produced by my keyboard, but we use 400 just to be safely out of reach of a real kb


/// Define MFKeyboardType stuff
///     TODO: (This is a dependency of searchVKCForStr) Delete this when copying over MFKeyboardSimulationData.h from EventLoggerForBrad
typedef CGEventSourceKeyboardType MFKeyboardType;
extern MFKeyboardType SLSGetLastUsedKeyboardID(void); /// Not sure about sizeof(returnType). `LMGetKbdType()` is `UInt8`, but `CGEventSourceKeyboardType` is `uint32_t` - both seem to contain the same constants though.
#define MFKeyboardTypeCurrent() ((MFKeyboardType)SLSGetLastUsedKeyboardID())
const MFKeyboardType kMFKeyboardTypeNull = 0;

+ (void)post:(CGSSymbolicHotKey)shk {

    DDLogDebug(@"[SymbolicHotKeys +post:] called on thread: %@", NSThread.currentThread);
    
    MFCFRunLoopPerform(CFRunLoopGetMain(), nil, ^{ /// Should we use the `_sync` variant here? Might be more responsive? 
        
        /// Run everything on mainThread
        ///     Reasons:
        ///         1. Reason:To check which vkc we gotta simulate to trigger a given shk, we need to inspect the current keyboard layout. The relevant APIs for this (The `TIS` aka TextInputSources APIs) should only be called from the main thread according to the docs.
        ///             > And I've also seen a crash around this (Which is described elsewhere. Search for `kTISPropertyInputSourceIsASCIICapable`.)
        ///         2. Reason: We use an NSTimer below - the scheduling logic is simpler if this runs on the main runLoop.
        ///         -> Just dispatching everything to the mainthread here seems simplest.
        ///
        ///     Outdated notes on thread safety: (from before we dispatched everything to the mainThread.) (Last updated: Nov 2024)
        ///         AFAIK, the only shared mutable state are the `CGS` functions that modify the global SHK configuration. The only two 'entry points' of this file which could produce simultaneous accesses to this shared state are the `+post:` and `+restoreSymbolicHotkeyParameters_timerCallback:` methods.
        ///         If we locked those two 'entry points' with a mutex and then never acquire another lock while holding that mutex, then our code should be guaranteed race condition and deadlock free.
        ///         However, I don't know whether functions such as `CGSSetSymbolicHotKeyValue()` acquire a lock or not, so I'm not confident that there can never be a deadlock if we used mutexes here.
        ///         -> I think the better solution would be to make sure that all the 'entry points' simply run on the same runLoop/thread. Alternatively, we could async dispatch to a dispatchQueue, but controlling the runLoop would be simpler and cleaner I think.
        ///
        ///  TODO: Merge this note ^ and (the dispatching to the CFRunLoopGetMain()) into EventLoggerForBrad before we replace this.
       
        unichar             keq_fromSHKAPI;
        CGKeyCode           vkc_fromSHKAPI;
        CGSModifierFlags    mods_fromSHKAPI;
        CGSGetSymbolicHotKeyValue(shk, &keq_fromSHKAPI, &vkc_fromSHKAPI, &mods_fromSHKAPI);
        
        /// Find the vkc that will trigger the shk.
        ///     [Jul 2025] In EventLoggerForBrad, from what I see, we also handle "shiftKeyEquivalents" and different keyboard types in this search for. But that complicates the code and I think only improves behavior in very unlikely edge-cases.
        ///     [Jul 2025] Edge-cases, where this fails:
        ///         1. Set Mission Control to Shift-Control-Option-Command-X, then switch to Akan layout, then trigger Mission Control with MMF -> The shortcut gets deleted. This happens because the shortcut is not reachable on the Akan layout.
        ///         2. Set Mission Control to Option-', then switch to German layout, then trigger Mission Control with MMF -> The shortcut gets deleted. The shortcut is actually still reachable in German through Option-# (Since the #-key produces ' while holding shift.) This could be fixed by implementing the "shiftKeyEquivalent" stuff from EventLoggerForBrad.
        ///         3. Probably, if you switch keyboard type to JIS, and then assign a shortcut to one of the extra keys like the Yen key, and then switch back to ANSI, you can provoke a scenario where this deletes the shortcut, even though it could've just attached a different keyboard type to the event and then successfully reached the shk. But I can't manage to switch the keyboard type rn, so not testing this. There was some trick to it that I forgot for switching keyboard type – maybe restarting?
        ///         TODO: Maybe backport this commentary to EventLoggerForBrad, so we have a clearer picture of what the edgecases are that all that complication in the code actually solves (Right now I'm thinking: They're all really unlikely and perhaps don't justify putting that complexity into the codebase.)
        
        CGKeyCode vkc_reachable;
        {
            if (!CGSIsSymbolicHotKeyEnabled(shk))
                vkc_reachable = kMFVK_Null;
            else {
                if (keq_fromSHKAPI == kMFKeyEquivalentNull) /// If there is no `keyEquivalent` for a CGSHotKey then macOS will use the VKC instead and everything should work fine. Otherwise, the `keyEquivalent` needs to match.
                    vkc_reachable = vkc_fromSHKAPI;
                else {
                    CGKeyCode vkc_bestGuess = vkc_fromSHKAPI;
                    NSString *keq_toSearchFor = [NSString stringWithCharacters: &keq_fromSHKAPI length: 1];
                    CGKeyCode vkc_fromKBLayout = searchVKCForStr(MFKeyboardTypeCurrent(), getCurrentKeyboardLayoutForKbShortcuts(), vkc_bestGuess, keq_toSearchFor, kMFModifierFlagsNull);
                    vkc_reachable = vkc_fromKBLayout; /// This can be `kMFVK_Null`
                }
            }
        }
        
        DDLogDebug(@"[SymbolicHotKeys +post:] CurrentBinding: %@", vardesc(@(shk), @(keq_fromSHKAPI), @(vkc_fromSHKAPI), binarystring(mods_fromSHKAPI), @(vkc_reachable)));
        
        BOOL oldBindingIsUsable = vkc_reachable != kMFVK_Null;
        
        if (!oldBindingIsUsable) {
            
            /// Permantently set a usable binding for our shk and enable it
            ///     [Jul 2025] In older macOS versions, we tried to temporarily create this usable binding and then restore it. But this doesn't seem to reliably work under macOS 15 Sequoia, or macOS 26 Tahoe – so to achieve reliability we have to create a permanent binding, but one which is not reachable from a real keyboard, as not to change the user's keyboard's behavior.
            ///     TODO: [Jul 2025] IIRC, in EventLoggerForBrad, we still try to temporarily set a usable binding and then reset this – but that doesn't work so we should adopt the approach we're using here. (shkBindingIsUsable() was used for the old approach, but now deleted – should probably also be deleted from EventLoggerForBrad)
            
            CGSSetSymbolicHotKeyEnabled(shk, true);
            
            unichar          keq_new = kMFKeyEquivalentNull;
            CGKeyCode        vkc_new = (CGKeyCode)shk + kMFVK_OutOfReach;
            CGSModifierFlags mods_new = kCGSNumericPadKeyMask | kCGSFunctionKeyMask;
            /// ^ Why use fn flag? The fn flag indicates either the fn modifier being held or a function key being pressed.
            ///     1. Function keys can be directly mapped to features like Mission Control.
            ///     2. Normal keys like 'P' cannot be mapped to features like Mission Control without any modifiers being held.
            ///     -> The fn flag should solve both of these cases.
            ///     Testing: 0 (aka `kEmptyModifierFlags`) didn't work in my testing. Using fn or fn | numpad flags worked in my testing.
            ///     Note In older MMF versions, we used numpad | fn flags – probably because we saw that those are eternalmods of the arrow keys. But I don't think numpad really makes sense here (?) Still, it works, so we're leaving it.
            ///     Note:
            ///         In the new keyboard simulation code we built inside `EventLoggerForBrad`, we have more sophisticated logic for this stuff, which will completely replace this.
            ///         TODO: Maybe merge this note into EventLoggerForBrad before we replace this?
            
            CGError err = CGSSetSymbolicHotKeyValue(shk, keq_new, vkc_new, mods_new);
            if (err != kCGErrorSuccess) {
                DDLogError(@"[SymbolicHotKeys +post:] Error setting shk params: %d", err); /// We still post the keyboard events in this case, bc maybe it will still worked despite the error?
                assert(false);
            }
            /// Post keyboard events
            postKeyboardEventsForSymbolicHotKey(vkc_new, mods_new);
        } else {
            /// Post keyboard events
            postKeyboardEventsForSymbolicHotKey(vkc_reachable, mods_fromSHKAPI);
        }
    });
}

static void postKeyboardEventsForSymbolicHotKey(CGKeyCode vkc, CGSModifierFlags mods) {
    
    /// Constants
    const CGEventTapLocation tapLoc = kCGSessionEventTap;
    const CGEventSourceRef   source = NULL;
    
    /// Create key events
    CGEventRef keyDown = CGEventCreateKeyboardEvent(source, vkc, true);
    CGEventRef keyUp   = CGEventCreateKeyboardEvent(source, vkc, false);
    
    /// Set modifierFlags
    CGEventFlags originalModifierFlags = getModifierFlagsWithEvent(keyDown);
    CGEventSetFlags(keyDown, (CGEventFlags)mods);
    CGEventSetFlags(keyUp,   originalModifierFlags); /// Restore original keyboard modifier flags state on key up. This seems to fix `[Modifiers getCurrentModifiers]`
    
    /// Send key events
    CGEventPost(tapLoc, keyDown);
    CGEventPost(tapLoc, keyUp);
    
    CFRelease(keyDown);
    CFRelease(keyUp);
}

#pragma mark - Random helper macros

/// TODO: (This is a dependency of searchVKCForStr) Delete these when you copy over all the macros from EventLoggerForBrad

/// Convenience macro
#define MFTISInputSourcePropertyIsTrue(src, prop) ({ \
    CFTypeRef a = TISGetInputSourceProperty((src), (prop)); \
    bool b = a && CFEqual(a, kCFBooleanTrue); \
    b; \
})

/// NULL-safe wrappers around common CF methods
#define MFCFRetain(cf)           (typeof(cf))  ({ __auto_type __cf = (cf); (!__cf ? NULL : CFRetain(__cf)); })                                                                  /// NULL-safe CFRetain || Note: Is a macro not a function for generic typing.
#define MFCFAutorelease(cf)      (typeof(cf))  ({ __auto_type __cf = (cf); (!__cf ? NULL : CFAutorelease(__cf)); })                                                             /// NULL-safe CFAutorelease || Dicussion: Probably use CFBridgingRelease() instead (it is already NULL safe I think.). Autorelease might be bad since autoreleasepools aren't available in all contexts. E.g. when using `dispatch_async` with a queue that doesn't autorelease. Or when running on a CFRunLoop which doesn't drain a pool after every iteration. (Like the mainLoop does) See Quinn "The Eskimo"s write up: https://developer.apple.com/forums/thread/716261
#define MFCFRelease(cf)          (void)        ({ __auto_type __cf = (cf); if (__cf) CFRelease(__cf); })                                                                        /// NULL-safe CFRelease
#define MFCFEqual(cf1, cf2)      (Boolean)     ({ __auto_type __cf1 = (cf1); __auto_type __cf2 = (cf2); ((__cf1 == __cf2) || (__cf1 && __cf2 && CFEqual(__cf1, __cf2))); })     /// NULL-safe CFEqual

#pragma mark - Keyboard layout helper function

CGKeyCode searchVKCForStr(MFKeyboardType keyboardType, const UCKeyboardLayout *keyboardLayout, CGKeyCode bestGuessResult, NSString *cr_unicodeString, CGEventFlags cr_flags) {
        
        /// TODO: Copied from EventLoggerForBrad – delete when we merge that.
        
        /// Inversion of  `getStrForVKC()`
        ///     - Given a `keyboardType` keyboard using the `keyboardLayout` layout – Finds the vkc for the key which produces `cr_unicodeString` when pressed while holding the modifier keys specified in `cr_flags`.
        ///         `cr_` stands for 'criterion'. The unicodeString and the flags are the criterion by which we search for vkc's.
        ///     - If the `bestGuessResult` is correct, that will speed up the operation.
        ///     - It does this by iterating all character-generating vkc's (Potentially slow?)
        ///     - Returns `kMFVK_Null` if no such vkc can be found.
    
        /// Make sure unicodeString exists.
        if (!cr_unicodeString || cr_unicodeString.length == 0) {
            return kMFVK_Null; /// Immediately give up since no keyboard-key can satisfy this empty/nil unicodeString criterion.
        }
        
        if (bestGuessResult != kMFVK_Null) {
            
            /// Validate
            if (!(bestGuessResult < kMFVK_FirstAppleKey)) {
                DDLogError(@"bestGuessResult seems to be an Apple key. (%d) Those don't generate unicodeStrings, which means we can't search for them using this function. [Dec 2024]", bestGuessResult);
                assert(false);
            }
            
            /// Check bestGuess
            NSString *str = getStrForVKC(keyboardType, keyboardLayout, bestGuessResult, cr_flags);
            if ([str isEqual:cr_unicodeString]) {
                return bestGuessResult; /// Criterion fulfilled by bestGuess
            }
        }
        
        /// Iterate potentially character-generating vkc's up to `kMFVK_FirstAppleKey`
        ///     On optimization: `kMFVK_FirstAppleKey` is 128 – iterating this many times feels slow, but I think it'll actually be super fast. Don't prematurely optimize.
        ///         If we reallyyy wanted to optimize this we could parallelize this I think?
        for (CGKeyCode vkc = 0; vkc < kMFVK_FirstAppleKey; vkc++) {
            NSString *str = getStrForVKC(keyboardType, keyboardLayout, vkc, cr_flags);
            if ([str isEqual:cr_unicodeString]) {
                return vkc;
            }
        }
        
        /// Return
        return kMFVK_Null;
}

/// TODO: (This is a dependency of searchVKCForStr) Remove this when copying over KeyboardSimulator.m from EventLoggerForBrad

NSString *getStrForVKC(MFKeyboardType keyboardType, const UCKeyboardLayout *keyboardLayout, CGKeyCode vkc, CGEventFlags flags) {

    /// Get chars for a virtualKeyCode
    ///     Wrapper around `UCKeyTranslate()`
    ///     This is a pure function with no dependencies on any state except the passed-in args (as of Dec 2024)
    /// Usage:
    ///     For the arg `keyboardType`: default to using `kMFKeyboardTypeCurrent`
    /// Nil returns:
    ///     Return `nil` to indicate `failure`.
    ///     Return `@""` for virtualKeyCodes of non-character-generating keys, e.g. delete, leftarrow, F11, command, control (while UCKeyTranslate() returns weird Control characters for those keys.)
    /// Alternatives for UCKeyTranslate:
    ///     1. `CGEventKeyboardGetUnicodeString()` – seems to give the same results as UCKeyTranslate, except that it doesn't work with deadKeys..
    ///     2. `[NSEvent -charactersByApplyingModifiers:]` - I think it's better suited for higher-level UI code. Read more below under  """If we use `[NSEvent -charactersByApplyingModifiers:]`"""
    /// Notes:
    ///     - The MASShortcut code which we're using in MMF also implements a UCKeyTranslate() wrapper. Maybe we should use that?
    /// - Based on:
    ///     - https://stackoverflow.com/a/8263841/10601702 (ended up in OpenEmu)
    ///     - https://chromium.googlesource.com/chromium/src/+/66.0.3359.158/ui/events/keycodes/keyboard_code_conversion_mac.mm (Chromium usage of UCKeyTranslate())
    
    /// NULL safety
    if (keyboardType == kMFKeyboardTypeNull || keyboardLayout == NULL || vkc == kMFVK_Null) { /// Not sure if necessary (UCKeyTranslate might fail anyways?)
        DDLogError(@"Some input is unexpectedly NULL, %d, %p, %d", keyboardType, keyboardLayout, vkc);
        assert(false);
        return nil;
    }
    
    /// Get modifierKeyState
    ///     See UCKeyTranslate() docs.
    UInt32 modifierKeyState = 0;
    if (flags & kCGEventFlagMaskCommand)    modifierKeyState |= cmdKey;
    if (flags & kCGEventFlagMaskShift)      modifierKeyState |= shiftKey;
    if (flags & kCGEventFlagMaskAlphaShift) modifierKeyState |= alphaLock;
    if (flags & kCGEventFlagMaskAlternate)  modifierKeyState |= optionKey;
    if (flags & kCGEventFlagMaskControl)    modifierKeyState |= controlKey;
    modifierKeyState = (modifierKeyState >> 8) & 0xFF;
    
    /// Get other input params
    UInt16 keyAction = kUCKeyActionDisplay;    /// Note: Not sure whether to use `kUCKeyActionDown` or `kUCKeyActionDisplay`. Some SO poster said `Down` works better, but in my testing `Display` returns the unicode of dead keys immediately, without having to translate `kVK_Space` right after to get the dead key's unicode char.
    OptionBits keyTranslateOptions = 0; /*kUCKeyTranslateNoDeadKeysMask*/; /// Dont' forget: Don't use `kUCKeyTranslateNoDeadKeysBit` directly, it's just 0. (Use the mask instead) || Not sure we need deadKey states when using `kUCKeyActionDisplay`
    
    /// Declare return buffers
    UInt32 deadKeyState = 0;
    const UniCharCount maxStringLength = 255; /// I've never seen this be more than 1. I guess some Chinese characters would perhaps take up more than one 16 bit codepoint? Or maybe this is larger for combined chars involving dead keys? Docs say "This may be a value of up to 255, although it would be rare to get more than 4 characters."
    UniCharCount actualStringLength = 0;
    UniChar unicodeString[maxStringLength+1];
    
    /// Translate
    OSStatus r = UCKeyTranslate(keyboardLayout, vkc, keyAction, modifierKeyState, keyboardType, keyTranslateOptions, &deadKeyState, maxStringLength, &actualStringLength, unicodeString);
    
    /// Handle deadKeys
    ///     Afaik, dead keys are keyPresses that don't produce a character, but instead modify the character produced by the next keyPress.
    ///     An example is the accent key next to the backspace key on the German QWERTZ layout.
    ///         See: https://stackoverflow.com/questions/8263618/convert-virtual-key-code-to-unicode-string/8263841#8263841
    ///     On macOS, you can enter the unicode character of the deadKey itself by pressing space after pressing the deadKey.
    ///     That's why we're passing `kVK_Space` to UCKeyTranslate here – it gives us the unicode character for the deadKey
    ///         -> Based on my testing, when using `kUCKeyActionDisplay` instead of `kUCKeyActionDown` then this is not necessary – at least for the aforementioned accent key on the German layout.
    
    if (deadKeyState && keyAction != kUCKeyActionDisplay) {
        DDLogDebug(@"KeyboardSimulator.m: DeadKeyState is non-zero. Translating space to produce the character for the dead key. String so far: '%@' (Should be empty), deadKeyState: %d\n", [NSString stringWithCharacters:unicodeString length:actualStringLength], deadKeyState);
        r = UCKeyTranslate(keyboardLayout, kVK_Space, kUCKeyActionDown, modifierKeyState, keyboardType, keyTranslateOptions, &deadKeyState, maxStringLength, &actualStringLength, unicodeString);
    }
    
    /// Check errors
    if (r != noErr) {
        DDLogError(@"KeyboardSimulator.m: UCKeyTranslate() failed with error code: %d", r);
        return nil;
    }
    
    /// Handle controlCharacters
    ///     Notes:
    ///     - UCKeyTranslate returns controlCharacters for all non-character-generating keys except modifier keys – e.g. F11, enter, delete, arrow keys, esc, pagedown, etc...
    ///     - If we create an NSString directly with the controlCharacters it prints using ASCII caret notation. e.g. `kFunctionKeyCharCode` prints as `\^P` (See Wikipedia: https://en.wikipedia.org/wiki/Caret_notation)
    ///     - Interesting: All the ASCII control characters I've seen UCKeyTranslate output correspond with 'MacRoman' character codes found in an HIToolbox enum. The 'MacRoman' character names also seem to correspond with the pressed key.
    ///         - E.g. Pressing F11 produces the `kFunctionKeyCharCode` MacRoman character.
    ///         - Many of the MacRoman characters also line up with the ASCII control characters semantically. E.g. `kReturnCharCode == 13 == (carriage return)`
    ///             (where `kReturnCharCode` is the macRoman character and `(carriage return)` is an ASCII control character.)
    ///
    ///     - If we use `[NSEvent -charactersByApplyingModifiers:]` instead of UCKeyTranslate, we get `NS` constants instead of these macRoman characters when pressing non-character-generating keys. E.g. `NSBackspaceCharacter` or `NSF7FunctionKey`.
    ///         - Use cases: These `NS` constants seem well-suited for displaying a kb-key / shortcut in the UI for users (Maybe we can use it in place of the code we copied from MASShortcut in MMF?). The HIToolBox MacRoman constants don't really seem useful for much – so we're filtering them out.
    ///         - My feeling: For our lower-level, non-UI, kb-shortcut code, I think we should use vkc's to identify non-character-generating keys. And ignore the output of UCKeyTranslate unless it outputs a normal ascii character that can be used to trigger a kb shortcut independent of the current keyboard layout.
    ///             IIRC, This is also how macOS seems to handle things – at least for system-wide keyboard shortcuts – looking at the output of `CGSGetSymbolicHotKeyValue()` – it seems to set the keyEquivalent to `UINT16_MAX` unless it's a normal ascii character, and otherwise uses the VKC (IIRC). On the other hand, NSMenuItem, which implements in-app kb shortcuts has a Unicode character associated with every key on the keyboard, and shortcuts seem to only be defined in terms of these characters. So not sure.

    const bool filterOutControlCharacters = true; /// Set this to 'false' for debugging
    static NSString *macRomanCharToPlaceholderMap[] = {
      [kNullCharCode]                           = @"<Null>",
      [kHomeCharCode]                           = @"<Home>",
      [kEnterCharCode]                          = @"<Enter>",
      [kEndCharCode]                            = @"<End>",
      [kHelpCharCode]                           = @"<Help>",
      [kBellCharCode]                           = @"<Bell>",
      [kBackspaceCharCode]                      = @"<Backspace>",
      [kTabCharCode]                            = @"<Tab>",
      [kLineFeedCharCode]                       = @"<LineFeed>",
      [kVerticalTabCharCode|kPageUpCharCode]    = @"<VerticalTab|PageUp>",
      [kFormFeedCharCode|kPageDownCharCode]     = @"<FormFeed|PageDown>",
      [kReturnCharCode]                         = @"<Return>",
      [kFunctionKeyCharCode]                    = @"<FunctionKey>",
      [kCommandCharCode]                        = @"<Command>",
      [kCheckCharCode]                          = @"<Check>",
      [kDiamondCharCode]                        = @"<Diamond>",
      [kAppleLogoCharCode]                      = @"<AppleLogo>",
      [kEscapeCharCode|kClearCharCode]          = @"<Escape|Clear>",
      [kLeftArrowCharCode]                      = @"<LeftArrow>",
      [kRightArrowCharCode]                     = @"<RightArrow>",
      [kUpArrowCharCode]                        = @"<UpArrow>",
      [kDownArrowCharCode]                      = @"<DownArrow>",
      [kSpaceCharCode]                          = @"<Space>", /// This is not a control character, it's unicode ' ' (space)
      [kDeleteCharCode]                         = @"<Delete>",
      [kBulletCharCode]                         = @"<Bullet>", /// This is not a control character, it:s unicode '¥'
      [kNonBreakingSpaceCharCode]               = @"<NonBreakingSpace>", /// This is not a control character, it's unicode 'Ê' || Note: kNonBreakingSpaceCharCode is 202, which makes the map a bit memory inefficient.
    };
    
    if (actualStringLength > 0) {
        unichar c = unicodeString[0];
        if ([NSCharacterSet.controlCharacterSet characterIsMember:c]) {
            if (filterOutControlCharacters) {
                return @""; /// emptyString matches the return value we see from UCKeyTranslate for modifier keys. That way all non-character-generating keys output emptyString.
            } else {
                if (c < arrcount(macRomanCharToPlaceholderMap) && macRomanCharToPlaceholderMap[c] != NULL) {
                    return macRomanCharToPlaceholderMap[c]; /// Output a placeholder based on our MacRoman character map
                } else {
                    DDLogError(@"Control character %c not covered by our macRoman map.", c);
                    assert(false);
                    return [NSString stringWithCharacters:unicodeString length:actualStringLength]; /// Output the UCKeyTranslate output directly. The control character will print (at least in the console) using ASCII caret notation.
                }
            }
        }
    }
    
    /// Return
    NSString *result = [NSString stringWithCharacters:unicodeString length:actualStringLength];
    return result;
}

#pragma mark - Keyboard layouts
/// Helper functions
/// TODO: (This is a dependency of searchVKCForStr) Delete this when you copy over KeyboardSimulator.m from EventLoggerForBrad

const UCKeyboardLayout *getCurrentKeyboardLayoutForKbShortcuts(void) {
    
    /// Convenience wrapper around lower-level functions
    
    /// Get keyboardLayout inputSource
    TISInputSourceRef inputSource = TISCopyCurrentKeyboardLayoutInputSource();
    MFDefer ^{ MFCFRelease(inputSource); };
    
    /// Get keyboardShortcut inputSource
    TISInputSourceRef inputSource2 = MFTISCopyKeyboardShortcutInputSourceForKeyboardLayoutInputSource(inputSource);
    MFDefer ^{ MFCFRelease(inputSource2); };
    
    /// Extract layout ptr
    const UCKeyboardLayout *layout = MFTISGetLayoutPointerFromInputSource(inputSource2);
    assert(layout != NULL);
    
    /// Return
    return layout;
}

const UCKeyboardLayout *getKeyboardLayoutForKbShortcutsWithID(NSString *keyboardLayoutInputSourceID) {
    
    /// Convenience wrapper around lower-level functions
    
    /// Get inputSource for passed-in ID
    TISInputSourceRef keyboardLayoutInputSource = MFTISCopyInputSourceWithID(keyboardLayoutInputSourceID);
    MFDefer ^{ MFCFRelease(keyboardLayoutInputSource); };
    
    /// Validate
    
    /// Check NULL
    if (!keyboardLayoutInputSource) {
        assert(false);
        return NULL;
    }
    /// Check if the passed-in inputSource is really a keyboardLayout
    #define isKeyboardLayout(__src) \
        MFCFEqual(kTISTypeKeyboardLayout, TISGetInputSourceProperty(__src, kTISPropertyInputSourceType))
    
    if (!isKeyboardLayout(keyboardLayoutInputSource)) {
        assert(false);
        return NULL;
    }
    
    /// Get keyboardShortcut inputSource
    TISInputSourceRef keyboardShortcutInputSource = MFTISCopyKeyboardShortcutInputSourceForKeyboardLayoutInputSource(keyboardLayoutInputSource);
    MFDefer ^{ MFCFRelease(keyboardShortcutInputSource); };
    
    /// Extract layout ptr
    const UCKeyboardLayout *result = MFTISGetLayoutPointerFromInputSource(keyboardShortcutInputSource);
    assert(result != NULL);
    
    /// Return
    return result;
}


TISInputSourceRef MFTISCopyKeyboardShortcutInputSourceForKeyboardLayoutInputSource(TISInputSourceRef _Nonnull inputSource) {
    
    /// Given a keyboardLayout-containing inputSource A, gets the inputSource B containing the keyboardLayout that is used by macOS to resolve keyboard shortcuts.
    ///     - As of [Dec 2024] this implements the `ABC Layout Fallback Mechanism` which is extensively discussed elsewhere.
    ///         > Basically: If `inputSource` arg is 'ASCIICapable' we will return it as is, otherwise it will return the `ABC` inputSource.
    ///     - Note: The returned inputSource will have +1 reference count and needs to be released by the caller.
    
    /// Check ASCII capability
    /// TODO: Keep these notes when merging EventLoggerForBrad into this.
    /// `Crash`:
    ///     I've seen this crash due to a `dispatch_assert_queue` inside TSMGetInputSourceProperty().
    ///     Message: `BUG IN CLIENT OF LIBDISPATCH: Assertion failed: Block was expected to execute on queue [com.apple.main-thread (0x20870fdc0)]`
    ///     However, I only saw this happen, if:
    ///         - I have a debugger attached (weird)
    ///         - This is running on the `com.nuebling.mac-mouse-fix.buttons` queue. (make sense I think? Cause otherwise it was running on the mainthread I think.)
    ///     Relevant note from Apple's TextInputSources.h:
    ///         Mac OS X threading:
    ///         TextInputSources API is not thread safe. If you are a UI application, you must call TextInputSources API on the main thread.
    ///         If you are a non-UI application (such as a cmd-line tool or a launchagent that does not run an event loop), you must not call TextInputSources API from multiple
    ///         threads concurrently.
    ///             > Noah's comment: ... But shouldn't reading an immutable property, such as 'ASCIICapable' be fine, even if the API is not technically thread safe?
    
    bool isASCIICapable = MFTISInputSourcePropertyIsTrue(inputSource, kTISPropertyInputSourceIsASCIICapable);
    
    /// Get result
    TISInputSourceRef result = NULL;
    if (isASCIICapable) {
        /// Use the passed-in inputSource
        result = (void *)CFRetain(inputSource); /// Retain so that `result` has the expected +1 reference count
    } else {
        /// Fallback to 'ABC' layout
        result = MFTISCopyInputSourceWithID(@"com.apple.keylayout.ABC");
    }
    
    /// Validate
    ///     We could fallback to the 'current' (aka most-recently-used in my testing) ascii capable layout using `TISCopyCurrentASCIICapableKeyboardLayoutInputSource()`
    assert(result != NULL); /// Don't think this can happen.
    
    /// Return
    return result;
}

const UCKeyboardLayout * MFTISGetLayoutPointerFromInputSource(TISInputSourceRef inputSource) {
    
    /// I feel like there's probably some private function which does this faster / easier.
    ///     Notes:
    ///     - According to the `kTISPropertyUnicodeKeyLayoutData` docs, this will simply return NULL if the inputSource is not of type `kTISTypeKeyboardLayout`.
    
    const UCKeyboardLayout *layout = NULL;
    if (inputSource) {
        CFDataRef layoutData = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData);
        if (layoutData) {
            layout = (const UCKeyboardLayout *)CFDataGetBytePtr(layoutData);
        }
    }
    
    assert(layout && "KeyboardSimulator.m: Failed to get UCKeyboardLayout"); /// I think this can only happen if: We pass in NULL or an invalid inputSource, or an inputSource that is not of type keyboardLayout.
    
    return layout; /// Based on my testing, there's no memory corruption errors by returning the pointer to the layout. Even if we store the layoutPointer and then change the input source  – the pointer stays valid. ––– However it might be safer to malloc the layout or return the CFDataRef instead of this.
}

TISInputSourceRef MFTISCopyInputSourceWithID(NSString *inputSourceID) {

    /// Helper function for `getCurrentKeyboardLayoutForKbShortcuts()`

    static const Boolean includeAllInstalled = true;
    NSDictionary *matchingDict = @{ (id)kTISPropertyInputSourceID: inputSourceID };
    
    NSArray *inputSourceList = CFBridgingRelease(TISCreateInputSourceList((__bridge CFDictionaryRef)matchingDict, includeAllInstalled));
    TISInputSourceRef result = (void *)CFBridgingRetain([inputSourceList firstObject]);
    
    return result;
}

@end
