// What any player is playing, and steering it, for Muna (Linux's media widget sees every player
// through MPRIS). macOS keeps its "now playing" (MediaRemote) for Apple's own programs since 15.4;
// /usr/bin/perl is one of them, so Muna loads this library into it (DynaLoader) and calls:
//   muna_now_playing  prints one JSON line: title, artist, album, duration, elapsed, playing, app,
//                     artwork (a file it writes the cover to, named after the track)
//   muna_send         MUNA_COMMAND: "playpause", "next", "previous", "play", "pause" or "seek <seconds>"
// Both take perl's two XSUB arguments and leave its stack alone.
#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (*GetInfo)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*GetPlaying)(dispatch_queue_t, void (^)(Boolean));
typedef void (*GetClient)(dispatch_queue_t, void (^)(id));
typedef CFStringRef (*ClientBundle)(id);
typedef Boolean (*SendCommand)(int, CFDictionaryRef);
typedef void (*SetElapsed)(double);

static void *remote(void) {
    static void *handle;
    if (!handle) handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    return handle;
}

static NSString *text(NSDictionary *info, NSString *key) {
    id value = info[key];
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static double number(NSDictionary *info, NSString *key) {
    id value = info[key];
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : 0;
}

void muna_now_playing(void *perl, void *cv) {
    @autoreleasepool {
        void *h = remote();
        GetInfo getInfo = h ? (GetInfo)dlsym(h, "MRMediaRemoteGetNowPlayingInfo") : NULL;
        GetPlaying getPlaying = h ? (GetPlaying)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") : NULL;
        GetClient getClient = h ? (GetClient)dlsym(h, "MRMediaRemoteGetNowPlayingClient") : NULL;
        ClientBundle bundleOf = h ? (ClientBundle)dlsym(h, "MRNowPlayingClientGetBundleIdentifier") : NULL;
        ClientBundle parentOf = h ? (ClientBundle)dlsym(h, "MRNowPlayingClientGetParentAppBundleIdentifier") : NULL;
        if (!getInfo) { printf("{}\n"); fflush(stdout); return; }
        dispatch_queue_t queue = dispatch_queue_create("muna.nowplaying", DISPATCH_QUEUE_SERIAL);
        dispatch_group_t group = dispatch_group_create();
        __block NSDictionary *info = nil;
        __block BOOL playing = NO;
        __block NSString *app = @"";
        dispatch_group_enter(group);
        getInfo(queue, ^(CFDictionaryRef dict) { info = [(__bridge NSDictionary *)dict copy]; dispatch_group_leave(group); });
        if (getPlaying) {
            dispatch_group_enter(group);
            getPlaying(queue, ^(Boolean on) { playing = on; dispatch_group_leave(group); });
        }
        if (getClient && bundleOf) {
            dispatch_group_enter(group);
            getClient(queue, ^(id client) {
                if (client) {
                    CFStringRef parent = parentOf ? parentOf(client) : NULL;
                    CFStringRef own = bundleOf(client);
                    if (parent) app = [(__bridge NSString *)parent copy];
                    else if (own) app = [(__bridge NSString *)own copy];
                }
                dispatch_group_leave(group);
            });
        }
        dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        if (info.count == 0) { printf("{}\n"); fflush(stdout); return; }
        NSString *title = text(info, @"kMRMediaRemoteNowPlayingInfoTitle");
        NSString *artist = text(info, @"kMRMediaRemoteNowPlayingInfoArtist");
        NSString *album = text(info, @"kMRMediaRemoteNowPlayingInfoAlbum");
        double duration = number(info, @"kMRMediaRemoteNowPlayingInfoDuration");
        double elapsed = number(info, @"kMRMediaRemoteNowPlayingInfoElapsedTime");
        double rate = number(info, @"kMRMediaRemoteNowPlayingInfoPlaybackRate");
        id stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
        if (playing && rate > 0 && [stamp isKindOfClass:[NSDate class]]) elapsed += -[stamp timeIntervalSinceNow] * rate;
        NSString *artwork = @"";
        id data = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        if ([data isKindOfClass:[NSData class]] && [data length] > 0) {
            NSString *name = [NSString stringWithFormat:@"muna-cover-%lx-%lu.img", (unsigned long)[[title stringByAppendingString:album] hash], (unsigned long)[data length]];
            artwork = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
            if (![[NSFileManager defaultManager] fileExistsAtPath:artwork]) [data writeToFile:artwork atomically:YES];
        }
        NSDictionary *out = @{ @"title": title, @"artist": artist, @"album": album, @"duration": @(duration),
                               @"elapsed": @(elapsed), @"playing": @(playing), @"app": app, @"artwork": artwork };
        NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
        fwrite(json.bytes, 1, json.length, stdout);
        printf("\n");
        fflush(stdout);
    }
}

void muna_send(void *perl, void *cv) {
    @autoreleasepool {
        void *h = remote();
        if (!h) return;
        const char *raw = getenv("MUNA_COMMAND");
        NSString *command = raw ? [NSString stringWithUTF8String:raw] : @"";
        if ([command hasPrefix:@"seek "]) {
            SetElapsed seek = (SetElapsed)dlsym(h, "MRMediaRemoteSetElapsedTime");
            if (seek) seek([[command substringFromIndex:5] doubleValue]);
            return;
        }
        NSDictionary *codes = @{ @"play": @0, @"pause": @1, @"playpause": @2, @"next": @4, @"previous": @5 };
        NSNumber *code = codes[command];
        SendCommand send = (SendCommand)dlsym(h, "MRMediaRemoteSendCommand");
        if (code && send) send(code.intValue, NULL);
    }
}
