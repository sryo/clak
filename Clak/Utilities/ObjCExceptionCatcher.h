#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ObjCExceptionCatcher : NSObject

/// Executes a block and catches any Objective-C exception.
/// Returns the exception if one was thrown, nil otherwise.
+ (nullable NSException *)tryBlock:(void (NS_NOESCAPE ^)(void))block;

@end

NS_ASSUME_NONNULL_END
