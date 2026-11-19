// 正在播放读取组件：由系统自带的 /usr/bin/perl 加载运行。
// 从 macOS 15.4 起，第三方程序直接调用 MediaRemote 拿不到正在播放的信息；
// perl 属于系统程序，不受此限制（做法参考开源项目 mediaremote-adapter）。
//
// adapter_stream：注册变化通知，每次变化输出一行 JSON（封面变化时附带 base64），父进程退出后自动结束。
// adapter_command：发送媒体控制命令，命令编号取自环境变量 NP_COMMAND（0 播放、1 暂停、2 播放/暂停、4 下一首、5 上一首）。

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <unistd.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*GetIsPlayingFn)(dispatch_queue_t, void (^)(BOOL));
typedef void (*GetClientFn)(dispatch_queue_t, void (^)(id));
typedef NSString *(*ClientBundleFn)(id);
typedef void (*RegisterFn)(dispatch_queue_t);
typedef Boolean (*SendCommandFn)(int, NSDictionary *);
typedef id (*LocalOriginFn)(void);
typedef id (*PlayerPathFn)(id, id, id);
typedef void (*GetCommandsFn)(id, dispatch_queue_t, void (^)(NSArray *));
typedef int (*CommandOfFn)(id);
typedef Boolean (*CommandEnabledFn)(id);

static void *framework(void) {
    static void *handle;
    if (!handle) handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    return handle;
}

/// 当前“正在播放”的应用支持哪些命令（已启用的命令编号）；查不到时回调 nil。
/// 语音消息、网页视频等通常只支持播放 / 暂停，不支持上一首 / 下一首（4 / 5）。
static void supportedCommands(void (^done)(NSArray *)) {
    void *h = framework();
    LocalOriginFn origin = dlsym(h, "MRMediaRemoteGetLocalOrigin");
    PlayerPathFn makePath = dlsym(h, "MRNowPlayingPlayerPathCreate");
    GetCommandsFn getCommands = dlsym(h, "MRMediaRemoteGetSupportedCommandsForPlayer");
    CommandOfFn commandOf = dlsym(h, "MRMediaRemoteCommandInfoGetCommand");
    CommandEnabledFn enabledOf = dlsym(h, "MRMediaRemoteCommandInfoGetEnabled");
    if (!origin || !makePath || !getCommands || !commandOf || !enabledOf) { done(nil); return; }
    getCommands(makePath(origin(), nil, nil), dispatch_get_main_queue(), ^(NSArray *infos) {
        NSMutableArray *commands = [NSMutableArray array];
        for (id info in infos) if (enabledOf(info)) [commands addObject:@(commandOf(info))];
        done(infos ? commands : nil);
    });
}

static NSString *lastArtworkID;
static pid_t parentPID;

static void emit(void) {
    GetInfoFn getInfo = dlsym(framework(), "MRMediaRemoteGetNowPlayingInfo");
    GetIsPlayingFn getPlaying = dlsym(framework(), "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    GetClientFn getClient = dlsym(framework(), "MRMediaRemoteGetNowPlayingClient");
    ClientBundleFn bundleOf = dlsym(framework(), "MRNowPlayingClientGetBundleIdentifier");
    if (!getInfo) return;
    getInfo(dispatch_get_main_queue(), ^(NSDictionary *info) {
        void (^finish)(BOOL, NSString *) = ^(BOOL playing, NSString *bundle) {
            NSMutableDictionary *out = [NSMutableDictionary dictionary];
            NSDictionary *names = @{
                @"kMRMediaRemoteNowPlayingInfoTitle": @"title",
                @"kMRMediaRemoteNowPlayingInfoArtist": @"artist",
                @"kMRMediaRemoteNowPlayingInfoAlbum": @"album",
                @"kMRMediaRemoteNowPlayingInfoDuration": @"duration",
                @"kMRMediaRemoteNowPlayingInfoElapsedTime": @"elapsed",
                @"kMRMediaRemoteNowPlayingInfoPlaybackRate": @"rate",
                @"kMRMediaRemoteNowPlayingInfoMediaType": @"mediaType",
                @"kMRMediaRemoteNowPlayingInfoArtworkIdentifier": @"artworkID",
            };
            for (NSString *key in names) {
                id value = info[key];
                if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]]) out[names[key]] = value;
            }
            NSDate *timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
            if ([timestamp isKindOfClass:[NSDate class]]) out[@"timestamp"] = @([timestamp timeIntervalSince1970]);
            out[@"playing"] = @(playing);
            if (bundle) out[@"bundle"] = bundle;
            // 封面只在变化时输出（几十 KB），其余时候只带编号
            NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
            NSString *artworkID = out[@"artworkID"] ?: (artwork ? [NSString stringWithFormat:@"%lu", (unsigned long)artwork.hash] : nil);
            if ([artwork isKindOfClass:[NSData class]] && artwork.length > 0 && ![artworkID isEqual:lastArtworkID]) {
                out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
                lastArtworkID = artworkID;
            }
            if (artworkID) out[@"artworkID"] = artworkID;
            supportedCommands(^(NSArray *commands) {
                if (commands) out[@"commands"] = commands;
                NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
                if (fwrite(json.bytes, 1, json.length, stdout) != json.length || fputc('\n', stdout) == EOF) exit(0);
                fflush(stdout);
            });
        };
        void (^withBundle)(BOOL) = ^(BOOL playing) {
            if (getClient && bundleOf) {
                getClient(dispatch_get_main_queue(), ^(id client) { finish(playing, client ? bundleOf(client) : nil); });
            } else {
                finish(playing, nil);
            }
        };
        if (getPlaying) getPlaying(dispatch_get_main_queue(), withBundle); else withBundle(YES);
    });
}

void adapter_stream(void) {
    parentPID = getppid();
    RegisterFn registerFn = dlsym(framework(), "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (registerFn) registerFn(dispatch_get_main_queue());
    for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                             @"kMRMediaRemotePlayerSupportedCommandsDidChangeNotification"]) {
        [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) { emit(); }];
    }
    emit();
    // 封面常在信息之后才送达：开头补取两次
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ emit(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ emit(); });
    // 父进程（islet）退出后自动结束
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(timer, ^{ if (getppid() != parentPID) exit(0); });
    dispatch_resume(timer);
    CFRunLoopRun();
}

void adapter_command(void) {
    SendCommandFn send = dlsym(framework(), "MRMediaRemoteSendCommand");
    const char *command = getenv("NP_COMMAND");
    if (send && command) send(atoi(command), nil);
    // 命令是异步投递的：进程立刻退出会把它丢掉，留一点时间让系统送达
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.4, false);
}
