#import "ObjCExceptionCatcher.h"

@implementation ObjCExceptionCatcher

+ (nullable NSException *)tryBlock:(void (NS_NOESCAPE ^)(void))block {
    @try {
        block();
    }
    @catch (NSException *exception) {
        return exception;
    }
    return nil;
}

@end
