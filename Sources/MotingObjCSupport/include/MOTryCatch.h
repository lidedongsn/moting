#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 执行 block 并捕获其中抛出的 Objective-C 异常（Swift 无法捕获，会直接终止进程）。
/// 有异常时返回异常原因，没有则返回 nil
NSString *_Nullable MOTryCatch(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
