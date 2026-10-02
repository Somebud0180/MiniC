#import "CompilerBridge.h"
#import <dlfcn.h>
#import <stdio.h>
#import <unistd.h>
#import <stdlib.h>
#import <TargetConditionals.h>

#if TARGET_OS_IOS
#import <signal.h>
static void *compilerHandles[2];
__attribute__((visibility("default"), used))
int MCCompilerEntry(int argc, char **argv) {
    if (argc < 1) return 127;
    int index;
    if (strcmp(argv[0], "clang") == 0) index = 0;
    else if (strcmp(argv[0], "wasm-ld") == 0) index = 1;
    else return 127;
    int (*entry)(int, char **) = dlsym(compilerHandles[index], "main");
    return entry ? entry(argc, argv) : 127;
}
#endif

NSString *MCInvokeCompiler(NSString *directory, NSArray<NSString *> *arguments, NSString *working, int *status) {
    *status = -1;
#if TARGET_OS_IOS
    static void *ioHandle;
    static NSString *loadError;
    static FILE *input, *output;
    static const char session[] = "MiniC-offline-compiler";
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        input = fopen("/dev/null", "r"); output = tmpfile();
        if (!input || !output) { loadError = @"Cannot open compiler streams"; return; }
        for (NSString *name in @[@"ios_system"]) {
            NSString *path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.framework/%@", name, name]];
            void *handle = dlopen(path.UTF8String, RTLD_NOW | RTLD_GLOBAL | RTLD_FIRST);
            if (!handle) { loadError = [NSString stringWithFormat:@"Cannot load %@: %s", name, dlerror()]; break; }
            if ([name isEqualToString:@"ios_system"]) ioHandle = handle;
        }
    });
    if (loadError) return loadError;
    // The command-oriented LLVM 14 tools destroy shared LLVM state on return.
    // Reload their libraries per stage so passes and signal callbacks start fresh.
    const int watched[] = {SIGHUP, SIGINT, SIGQUIT, SIGILL, SIGTRAP, SIGABRT, SIGBUS, SIGFPE, SIGSEGV, SIGPIPE, SIGSYS, SIGTERM, SIGXCPU, SIGXFSZ};
    const size_t signalCount = sizeof(watched) / sizeof(watched[0]);
    struct sigaction saved[signalCount];
    for (size_t i = 0; i < signalCount; ++i) sigaction(watched[i], NULL, &saved[i]);
    void *llvm = NULL;
    for (NSString *name in @[@"libLLVM", @"clang", @"lld"]) {
        NSString *path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.framework/%@", name, name]];
        void *handle = dlopen(path.UTF8String, RTLD_NOW | RTLD_GLOBAL | RTLD_FIRST);
        if (!handle) {
            NSString *failure = [NSString stringWithFormat:@"Cannot load %@: %s", name, dlerror()];
            if (compilerHandles[1]) dlclose(compilerHandles[1]);
            if (compilerHandles[0]) dlclose(compilerHandles[0]);
            if (llvm) dlclose(llvm);
            compilerHandles[0] = compilerHandles[1] = NULL;
            return failure;
        }
        if ([name isEqualToString:@"libLLVM"]) llvm = handle;
        if ([name isEqualToString:@"clang"]) compilerHandles[0] = handle;
        if ([name isEqualToString:@"lld"]) compilerHandles[1] = handle;
    }
#define FN(name, result, ...) result (*name)(__VA_ARGS__) = (result (*)(__VA_ARGS__))dlsym(ioHandle, #name)
    FN(initializeEnvironment, void, void);
    FN(ios_switchSession, void, const void *);
    FN(ios_setStreams, void, FILE *, FILE *, FILE *);
    FN(ios_setContext, void, const void *);
    FN(ios_setDirectoryURL, void, NSURL *);
    FN(ios_system, int, const char *);
    FN(ios_getCommandStatus, int, void);
    if (!initializeEnvironment || !ios_switchSession || !ios_setStreams || !ios_setContext || !ios_setDirectoryURL || !ios_system || !ios_getCommandStatus) return @"Missing ios_system entry points";
    // ios_system keeps caller TLS stream pointers between commands. Keep one
    // session and one pair of streams alive for the compiler's lifetime.
    // a-Shell's patched Driver constructor reads SYSROOT before parsing argv.
    for (NSString *word in arguments) {
        if ([word hasPrefix:@"--sysroot="]) setenv("SYSROOT", [word substringFromIndex:10].UTF8String, 1);
    }
    initializeEnvironment();
    NSString *previousDirectory = NSFileManager.defaultManager.currentDirectoryPath;
    ios_switchSession(session);
    ios_setStreams(input, output, output);
    ios_setContext(session);
    fflush(output); ftruncate(fileno(output), 0); rewind(output); clearerr(output);
    ios_setDirectoryURL([NSURL fileURLWithPath:working isDirectory:YES]);
    NSMutableArray *words = [NSMutableArray new];
    for (NSString *word in arguments) {
        // ios_system parses commands; never allow user text to become shell syntax.
        NSString *escaped = [word stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
        [words addObject:[NSString stringWithFormat:@"'%@'", escaped]];
    }
    ios_system([[words componentsJoinedByString:@" "] UTF8String]);
    *status = ios_getCommandStatus();
    fflush(output);
    ios_setDirectoryURL([NSURL fileURLWithPath:previousDirectory isDirectory:YES]);
    rewind(output);
    NSMutableData *data = [NSMutableData new];
    char buffer[4096]; size_t count;
    while ((count = fread(buffer, 1, sizeof buffer, output)) > 0) {
        if (data.length < 256 * 1024) [data appendBytes:buffer length:MIN(count, 256 * 1024 - data.length)];
    }
    for (size_t i = 0; i < signalCount; ++i) sigaction(watched[i], &saved[i], NULL);
    dlclose(compilerHandles[1]); dlclose(compilerHandles[0]); dlclose(llvm);
    compilerHandles[0] = compilerHandles[1] = NULL;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"Compiler returned non-UTF8 diagnostics";

#else
    return @"Native compiler frameworks require iOS. Use the desktop WASI SDK driver for host tests.";
#endif
}
