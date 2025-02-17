//
// --------------------------------------------------------------------------
// SharedUtility.h
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2020
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//

#import <CoreGraphics/CoreGraphics.h>
//#import <Foundation/Foundation.h>
#import "Constants.h"

// Import WannabePrefixHeader.h here so we don't have to manually include it in as many places (not sure if bad practise)
#import "WannabePrefixHeader.h"
#import "Shorthands.h"
#import "MFDefer.h"

#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// `threadlocal()` creates/gets an object whose state is retained between invocations of your method/function (if those invocations are running on the same thread)
///     This is pretty similar to a `static __thread` variable, but for objc objects instead of POD (plain old data)
///     Use mutable types for this to be useful.
///     Example usage:
///      ```
///      NSMutableArray *arr = threadlocal(NSMutableArray);
///      [arr addObject:@"a"];
///      NSLog("%@", arr); // Will print more and more "a" strings as this code is invoked multiple times on the same thread.
///      ```

#define threadlocal(__className) \
    (__className *) \
    ({ \
        static const uintptr_t dictKey = (uintptr_t)&dictKey; \
        __className *result = NSThread.currentThread.threadDictionary[@(dictKey)]; /** Boxing the dictKey every time might be a little inefficient */\
        if (result == nil || ![result isKindOfClass:[__className class]]) { /** This `isKindOfClass:` check is probably unnecessary and a bit inefficient */ \
            result = [[__className alloc] init]; \
            NSThread.currentThread.threadDictionary[@(dictKey)] = result; \
        } \
        result; \
    })

/// String (f)ormatting convenience.
#define stringf(format, ...) [NSString stringWithFormat:(format), ## __VA_ARGS__]

/// array count convenience
///     TODO: (This is a dependency of shkBindingIsUsable) Remove this when copying over EventLoggerForBrad macros
#define arrcount(x) (sizeof(x) / sizeof((x)[0]))

#define binarystring(__v) /** This is a macro to make this function generic. The output string's width will automatically match the byte count of the input type (by using sizeof()) */\
    (NSString *) \
    ({ \
        typeof(__v) m_value = __v; /** We call it `m_value` so there's no conflict in case `__v` is `value`. `m_` stands for `macro`. */ \
        int nibble_size = 8; \
        int nibble_count = sizeof(m_value)*8 / nibble_size; \
        int bit_str_len = (nibble_count * (nibble_size+1)) - 1; \
        char bit_str[bit_str_len + 1]; \
        bit_str[bit_str_len] = '\0'; /** Null terminator */ \
        for (int i = bit_str_len-1; i >= 0; i--) { \
            if (i % (nibble_size+1) == nibble_size) { /** Add a space every `nibble_size` bits for better legibility */ \
                bit_str[i] = ' '; \
            } else { \
                bit_str[i] = (m_value & 1) ? '1' : '0'; \
                m_value = m_value >> 1; \
            } \
        } \
        [NSString stringWithUTF8String:bit_str]; \
    })

/// Check if ptr is objc object
///     Copied from https://opensource.apple.com/source/CF/CF-635/CFInternal.h
#define CF_IS_TAGGED_OBJ(PTR)    ((uintptr_t)(PTR) & 0x1)
extern inline bool _objc_isTaggedPointer(const void *ptr);     /// Copied from https://blog.timac.org/2016/1124-testing-if-an-arbitrary-pointer-is-a-valid-objective-c-object/

@interface SharedUtility : NSObject

typedef void(*MFCTLCallback)(NSTask *task, NSPipe *output, NSError *error);

void MFCFRunLoopPerform(CFRunLoopRef _Nonnull rl, NSArray<NSRunLoopMode> *_Nullable modes, void (^_Nonnull workload)(void));
bool MFCFRunLoopPerform_sync(CFRunLoopRef _Nonnull rl, NSArray<NSRunLoopMode> *_Nullable modes, NSTimeInterval timeout, void (^_Nonnull workload)(void));
CFTimeInterval machTimeToSeconds(uint64_t tsMach);
uint64_t secondsToMachTime(CFTimeInterval tsSeconds);
NSException * _Nullable tryCatch(void (^tryBlock)(void));
void *offsetPointer(void *ptr, int byteOffset);
bool runningPreRelease(void);
bool runningMainApp(void);
bool runningHelper(void);
//bool runningAccomplice(void);

+ (id)getPrivateValueOf:(id)obj forName:(NSString *)name;
+ (NSString *)dumpClassInfo:(id)obj;
+ (NSString *)launchCLT:(NSURL *)executableURL withArguments:(NSArray<NSString *> *)arguments error:(NSError ** _Nullable)error;
+ (void)launchCLT:(NSURL *)commandLineTool withArgs:(NSArray <NSString *> *)arguments;
+ (FSEventStreamRef)scheduleFSEventStreamOnPaths:(NSArray<NSString *> *)urls withCallback:(FSEventStreamCallback)callback;
+ (void)destroyFSEventStream:(FSEventStreamRef)stream;
+ (NSPoint)quartzToCocoaScreenSpace_Point:(CGPoint)quartzPoint;
+ (CGPoint)cocoaToQuartzScreenSpace_Point:(NSPoint)cocoaPoint;
+ (NSRect)quartzToCocoaScreenSpace:(CGRect)quartzFrame;
+ (CGRect)cocoaToQuartzScreenSpace:(NSRect)cocoaFrame;
+ (id)deepMutableCopyOf:(id)object;
+ (id)deepCopyOf:(id)object;
+ (id<NSCoding>)deepCopyOf:(id<NSCoding>)original error:(NSError *_Nullable *_Nullable)error;
+ (NSString *)callerInfo;
+ (NSDictionary *)dictionaryWithOverridesAppliedFrom:(NSDictionary *)src to: (NSDictionary *)dst;
+ (CGEventType)CGEventTypeForButtonNumber:(MFMouseButtonNumber)button isMouseDown:(BOOL)isMouseDown;
+ (CGMouseButton)CGMouseButtonFromMFMouseButtonNumber:(MFMouseButtonNumber)button;
+ (int8_t)signOf:(double)x;
int8_t sign(double x);
+ (NSString *)currentDispatchQueueDescription;
+ (void)printInvocationCountWithId:(NSString *)strId;
+ (BOOL)button:(NSNumber * _Nonnull)button isPartOfModificationPrecondition:(NSDictionary *)modificationPrecondition;
+ (void)setupBasicCocoaLumberjackLogging;
+ (void)resetDispatchGroupCount:(dispatch_group_t)group;

@end

NS_ASSUME_NONNULL_END
