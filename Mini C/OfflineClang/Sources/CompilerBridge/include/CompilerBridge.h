#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Must be called serially. Loads only signed frameworks from the app bundle.
NSString * MCInvokeCompiler(NSString *frameworkDirectory, NSArray<NSString *> *arguments,
                            NSString *workingDirectory, int *status);
NS_ASSUME_NONNULL_END
