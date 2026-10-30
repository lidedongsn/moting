#import "MOTryCatch.h"

NSString *_Nullable MOTryCatch(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *e) {
        return e.reason ?: e.name;
    }
}
