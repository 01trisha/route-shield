#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import <Network/Network.h>
#import <ServiceManagement/ServiceManagement.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <UserNotifications/UserNotifications.h>
#include <arpa/inet.h>
#include <cerrno>
#include <cstdio>
#include <fcntl.h>
#include <sys/file.h>

static NSString *const GuardBundleID = @"local.vpnguard";
static NSString *const GuardName = @"Route Shield";
static NSString *const RepositoryURL = @"https://github.com/01trisha/route-shield";
static NSString *const TargetBundleIDKey = @"VPNGuardTargetBundleIdentifier";
static NSString *const NotifyIPChangesKey = @"NotifyIPChanges";
static NSString *const ForceCloseOnIPChangeKey = @"ForceCloseOnIPChange";
static NSString *const LanguageKey = @"InterfaceLanguage";

static NSUserDefaults *LanguagePreferences() {
    if (![NSBundle.mainBundle objectForInfoDictionaryKey:TargetBundleIDKey]) {
        return NSUserDefaults.standardUserDefaults;
    }

    // Dock shortcuts have separate bundle IDs and read the main app's preference.
    static NSUserDefaults *preferences;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        preferences = [[NSUserDefaults alloc] initWithSuiteName:GuardBundleID];
    });
    return preferences;
}

static NSString *L(NSString *russian) {
    if (![[LanguagePreferences() stringForKey:LanguageKey] isEqualToString:@"en"]) return russian;
    static NSBundle *english;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *resources = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"en.lproj" isDirectory:YES];
        english = [NSBundle bundleWithURL:resources];
    });
    return [english localizedStringForKey:russian value:russian table:nil] ?: russian;
}

static NSURL *ConfigURL() {
    return [NSURL fileURLWithPath:[NSHomeDirectory()
        stringByAppendingPathComponent:@"Library/Application Support/VPN Guard/.env"]];
}

static NSURL *LaunchersURL() {
    return [NSURL fileURLWithPath:[NSHomeDirectory()
        stringByAppendingPathComponent:@"Applications/Route Shield"] isDirectory:YES];
}

static NSString *Trim(NSString *value) {
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *ReadConfig(NSURL *url, NSString **problem) {
    NSError *error = nil;
    NSString *contents = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:&error];
    if (contents) return contents;
    if ([error.domain isEqualToString:NSCocoaErrorDomain] && error.code == NSFileReadNoSuchFileError) {
        return @"";
    }
    *problem = [NSString stringWithFormat:L(@"Не удалось прочитать .env. %@"), error.localizedDescription];
    return nil;
}

static BOOL IsTargetID(NSString *identifier) {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"];
    NSString *lowercase = identifier.lowercaseString;
    return identifier.length > 0 &&
           [identifier rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound &&
           ![lowercase isEqualToString:GuardBundleID] &&
           ![lowercase hasPrefix:[GuardBundleID stringByAppendingString:@"."]];
}

static NSArray<NSString *> *ParseApps(NSString *contents, NSRange *valueRange, NSString **problem) {
    NSMutableOrderedSet<NSString *> *identifiers = [NSMutableOrderedSet orderedSet];
    NSUInteger offset = 0;
    BOOL foundApps = NO;
    for (NSString *rawLine in [contents componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSUInteger lineStart = offset;
        offset += rawLine.length + 1;
        NSString *line = [[rawLine componentsSeparatedByString:@"#"] firstObject];
        if (Trim(line).length == 0) continue;
        NSRange equals = [line rangeOfString:@"="];
        if (equals.location == NSNotFound || foundApps ||
            ![Trim([line substringToIndex:equals.location]) isEqualToString:@"APPS"]) {
            *problem = L(@"В .env нужна одна строка APPS= со списком Bundle ID через запятую.");
            return nil;
        }

        foundApps = YES;
        NSString *rawValue = [line substringFromIndex:NSMaxRange(equals)];
        NSString *value = Trim(rawValue);
        if (valueRange) {
            NSUInteger start = value.length ? [rawValue rangeOfString:value options:NSLiteralSearch].location : 0;
            *valueRange = NSMakeRange(lineStart + NSMaxRange(equals) + start, value.length);
        }
        if (value.length >= 2 && (([value hasPrefix:@"\""] && [value hasSuffix:@"\""]) ||
                                  ([value hasPrefix:@"'"] && [value hasSuffix:@"'"]))) {
            value = Trim([value substringWithRange:NSMakeRange(1, value.length - 2)]);
        }
        if (value.length == 0) continue;
        for (NSString *rawID in [value componentsSeparatedByString:@","]) {
            NSString *identifier = Trim(rawID);
            if (!IsTargetID(identifier)) {
                *problem = [NSString stringWithFormat:L(@"Недопустимый Bundle ID в .env (%@)."), identifier];
                return nil;
            }
            [identifiers addObject:identifier];
        }
    }
    return identifiers.array;
}

static NSArray<NSString *> *ReadApps(NSString **problem) {
    NSString *contents = ReadConfig(ConfigURL(), problem);
    return contents ? ParseApps(contents, nullptr, problem) : nil;
}

static NSUInteger AddApps(NSURL *config, NSArray<NSString *> *droppedIDs, NSString **problem) {
    NSURL *directory = config.URLByDeletingLastPathComponent;
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory
           withIntermediateDirectories:YES attributes:nil error:&error]) {
        *problem = error.localizedDescription;
        return 0;
    }

    // Lock the directory so the lock survives atomic replacement of .env.
    int fd = open(directory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd == -1) {
        *problem = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil].localizedDescription;
        return 0;
    }
    __attribute__((objc_precise_lifetime)) NSFileHandle *lock =
        [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
    if (flock(lock.fileDescriptor, LOCK_EX) == -1) {
        *problem = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil].localizedDescription;
        return 0;
    }

    NSString *contents = ReadConfig(config, problem);
    NSRange range = NSMakeRange(NSNotFound, 0);
    NSArray<NSString *> *existing = contents ? ParseApps(contents, &range, problem) : nil;
    if (!existing) return 0;

    NSMutableOrderedSet<NSString *> *merged = [NSMutableOrderedSet orderedSetWithArray:existing];
    [merged addObjectsFromArray:droppedIDs];
    NSUInteger added = merged.count - existing.count;
    if (added == 0) return 0;

    NSString *value = [merged.array componentsJoinedByString:@","];
    NSString *updated;
    if (range.location == NSNotFound) {
        NSString *newline = contents.length > 0 &&
            ![NSCharacterSet.newlineCharacterSet characterIsMember:[contents characterAtIndex:contents.length - 1]]
            ? @"\n" : @"";
        updated = [contents stringByAppendingFormat:@"%@APPS=%@\n", newline, value];
    } else {
        NSString *original = [contents substringWithRange:range];
        if ([original hasPrefix:@"\""] || [original hasPrefix:@"'"]) {
            NSString *quote = [original substringToIndex:1];
            value = [NSString stringWithFormat:@"%@%@%@", quote, value, quote];
        }
        updated = [contents stringByReplacingCharactersInRange:range withString:value];
    }

    if (![updated writeToURL:config atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        *problem = error.localizedDescription;
        return 0;
    }
    return added;
}

static NSString *BundleIDAtURL(NSURL *url) {
    if (!url.isFileURL || ![url.pathExtension.lowercaseString isEqualToString:@"app"]) return nil;
    return [NSBundle bundleWithURL:url].bundleIdentifier;
}

static BOOL IsAppWithID(NSURL *url, NSString *identifier) {
    return [BundleIDAtURL(url) isEqualToString:identifier];
}

static NSURL *FindApp(NSString *identifier) {
    NSURL *registered = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:identifier];
    if (IsAppWithID(registered, identifier)) return registered;

    // An installed app may not yet be registered with Launch Services.
    NSArray<NSString *> *directories = @[[NSHomeDirectory() stringByAppendingPathComponent:@"Applications"],
        @"/Applications", @"/System/Applications"];
    for (NSString *directory in directories) {
        NSURL *root = [NSURL fileURLWithPath:directory isDirectory:YES];
        for (NSURL *url in [NSFileManager.defaultManager enumeratorAtURL:root includingPropertiesForKeys:nil
             options:NSDirectoryEnumerationSkipsPackageDescendants | NSDirectoryEnumerationSkipsHiddenFiles
             errorHandler:nil]) {
            if (IsAppWithID(url, identifier)) return url;
        }
    }
    return nil;
}

static NSString *AppName(NSURL *url) {
    NSBundle *bundle = [NSBundle bundleWithURL:url];
    return [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?:
           [bundle objectForInfoDictionaryKey:@"CFBundleName"] ?:
           url.URLByDeletingPathExtension.lastPathComponent;
}

static BOOL WriteICNS(NSImage *icon, NSURL *destination) {
    const NSInteger sizes[] = {16, 32, 128, 256, 512};
    CGImageDestinationRef writer = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)destination, CFSTR("com.apple.icns"), sizeof(sizes) / sizeof(sizes[0]), nullptr);
    if (!writer) return NO;
    for (NSInteger size : sizes) {
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr
            pixelsWide:size pixelsHigh:size bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
            colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
        NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationHigh;
        [icon drawInRect:NSMakeRect(0, 0, size, size) fromRect:NSZeroRect
            operation:NSCompositingOperationCopy fraction:1.0];
        [NSGraphicsContext restoreGraphicsState];
        CGImageDestinationAddImage(writer, bitmap.CGImage, nullptr);
    }
    BOOL saved = CGImageDestinationFinalize(writer);
    CFRelease(writer);
    return saved;
}

static BOOL WriteLauncherIcon(NSURL *target, NSURL *destination, NSError **error) {
    NSBundle *bundle = [NSBundle bundleWithURL:target];
    NSString *iconFile = [bundle objectForInfoDictionaryKey:@"CFBundleIconFile"];
    if ([iconFile isKindOfClass:NSString.class] && [iconFile isEqualToString:iconFile.lastPathComponent]) {
        NSString *name = iconFile.pathExtension.length ? iconFile : [iconFile stringByAppendingPathExtension:@"icns"];
        NSURL *source = [[bundle.resourceURL URLByAppendingPathComponent:name] URLByResolvingSymlinksInPath];
        NSFileManager *files = NSFileManager.defaultManager;
        if ([name.pathExtension.lowercaseString isEqualToString:@"icns"] && [files fileExistsAtPath:source.path]) {
            return [files copyItemAtURL:source toURL:destination error:error];
        }
    }

    // Asset catalogs don't always include a standalone icon file.
    return WriteICNS([NSWorkspace.sharedWorkspace iconForFile:target.path], destination);
}

static NSString *LauncherBundleID(NSString *identifier) {
    return [NSString stringWithFormat:@"%@.launcher.%@", GuardBundleID, identifier];
}

static BOOL OwnsLauncher(NSURL *url, NSString *identifier) {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:
        [url URLByAppendingPathComponent:@"Contents/Info.plist"]];
    return [info[TargetBundleIDKey] isEqualToString:identifier] &&
           [info[@"CFBundleIdentifier"] isEqualToString:LauncherBundleID(identifier)];
}

static BOOL InstallLauncher(NSURL *target, NSString *identifier, NSURL *destination,
                           NSBundle *guardBundle, BOOL replace, NSError **error) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *stage = [destination.URLByDeletingLastPathComponent URLByAppendingPathComponent:
        [@"." stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
    NSURL *launcher = [stage URLByAppendingPathComponent:destination.lastPathComponent];
    NSURL *plist = [launcher URLByAppendingPathComponent:@"Contents/Info.plist"];
    NSURL *binFolder = [launcher URLByAppendingPathComponent:@"Contents/MacOS" isDirectory:YES];
    NSURL *resources = [launcher URLByAppendingPathComponent:@"Contents/Resources" isDirectory:YES];
    NSMutableDictionary *info = [guardBundle.infoDictionary mutableCopy];
    info[@"CFBundleIdentifier"] = LauncherBundleID(identifier);
    info[@"CFBundleName"] = [NSString stringWithFormat:@"%@ — %@", AppName(target), GuardName];
    info[@"CFBundleDisplayName"] = info[@"CFBundleName"];
    info[@"CFBundleIconFile"] = @"Target.icns";
    info[TargetBundleIDKey] = identifier;

    BOOL ready = [files createDirectoryAtURL:binFolder withIntermediateDirectories:YES attributes:nil error:error] &&
        [files createDirectoryAtURL:resources withIntermediateDirectories:YES attributes:nil error:error] &&
        [files copyItemAtURL:[guardBundle.resourceURL URLByAppendingPathComponent:@"en.lproj"]
            toURL:[resources URLByAppendingPathComponent:@"en.lproj"] error:error] &&
        [files copyItemAtURL:[guardBundle.resourceURL URLByAppendingPathComponent:@"LICENSE"]
            toURL:[resources URLByAppendingPathComponent:@"LICENSE"] error:error] &&
        [files copyItemAtURL:guardBundle.executableURL
            toURL:[binFolder URLByAppendingPathComponent:guardBundle.executableURL.lastPathComponent] error:error] &&
        WriteLauncherIcon(target, [resources URLByAppendingPathComponent:@"Target.icns"], error) &&
        [info writeToURL:plist error:error];
    if (ready) {
        NSTask *sign = [[NSTask alloc] init];
        sign.executableURL = [NSURL fileURLWithPath:@"/usr/bin/codesign"];
        sign.arguments = @[@"--force", @"--sign", @"-", launcher.path];
        ready = [sign launchAndReturnError:error];
        if (ready) {
            [sign waitUntilExit];
            ready = sign.terminationStatus == 0;
        }
    }

    BOOL installed = NO;
    if (ready && !replace) {
        installed = [files moveItemAtURL:launcher toURL:destination error:error];
    } else if (ready && OwnsLauncher(destination, identifier)) {
        // Preserve the path used by existing Dock items. The old bundle ends up in stage.
        installed = renamex_np(launcher.fileSystemRepresentation, destination.fileSystemRepresentation, RENAME_SWAP) == 0;
        if (!installed) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    }
    [files removeItemAtURL:stage error:nil];
    return installed;
}

static void ShowMessage(NSString *title, NSString *detail) {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = detail ?: L(@"macOS не сообщила причину.");
    [alert addButtonWithTitle:@"OK"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

static NSString *LookupIP(int family) {
    NSTask *curl = [[NSTask alloc] init];
    curl.executableURL = [NSURL fileURLWithPath:@"/usr/bin/curl"];
    // Use a fixed source per family so a provider change can't trigger an IP change.
    NSString *endpoint = family == AF_INET ? @"https://api.ipify.org" : @"https://ifconfig.me/ip";
    curl.arguments = @[@"-q", family == AF_INET ? @"-4" : @"-6", @"--noproxy", @"*",
        @"--fail", @"--silent", @"--connect-timeout", @"3", @"--max-time", @"6",
        @"--max-filesize", @"1024", endpoint];
    NSPipe *pipe = [NSPipe pipe];
    curl.standardOutput = pipe;
    if (![curl launchAndReturnError:nil]) {
        return L(@"Не удалось запустить curl");
    }
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [curl waitUntilExit];
    if (curl.terminationStatus != 0) {
        return [NSString stringWithFormat:L(@"Не удалось получить (curl %d)"), curl.terminationStatus];
    }

    NSString *address = Trim([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
    struct in6_addr parsed = {};
    char normalized[INET6_ADDRSTRLEN];
    if (address.length == 0 || inet_pton(family, address.UTF8String, &parsed) != 1 ||
        !inet_ntop(family, &parsed, normalized, sizeof(normalized))) {
        return L(@"Сервис не вернул адрес этого семейства");
    }
    return [NSString stringWithUTF8String:normalized];
}

static void CheckIPs(void (^complete)(NSString *, NSString *)) {
    dispatch_group_t checks = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    __block NSString *ipv4 = nil;
    __block NSString *ipv6 = nil;
    dispatch_group_async(checks, queue, ^{ ipv4 = LookupIP(AF_INET); });
    dispatch_group_async(checks, queue, ^{ ipv6 = LookupIP(AF_INET6); });
    dispatch_group_notify(checks, queue, ^{
        // Deliver results even while AppKit is tracking the open menu.
        CFRunLoopRef mainLoop = CFRunLoopGetMain();
        NSArray *modes = @[NSRunLoopCommonModes, NSEventTrackingRunLoopMode];
        CFRunLoopPerformBlock(mainLoop, (__bridge CFArrayRef)modes, ^{ complete(ipv4, ipv6); });
        CFRunLoopWakeUp(mainLoop);
    });
}

static BOOL UpdateKnownAddress(NSString *sample, int family, NSString *__strong *previous) {
    struct in6_addr parsed = {};
    if (sample.length == 0 || inet_pton(family, sample.UTF8String, &parsed) != 1) return NO;
    BOOL changed = *previous && ![*previous isEqualToString:sample];
    *previous = sample;
    return changed;
}

@interface IPMonitor : NSObject
- (instancetype)initWithHandler:(void (^)(NSArray<NSString *> *))handler;
- (void)checkWithResult:(void (^)(NSString *, NSString *))result;
- (void)stop;
- (void)networkChanged;
@end

static void NetworkChanged(SCDynamicStoreRef store, CFArrayRef keys, void *info) {
    (void)store;
    (void)keys;
    [(__bridge IPMonitor *)info networkChanged];
}

@implementation IPMonitor {
    void (^_handler)(NSArray<NSString *> *);
    void (^_showResult)(NSString *, NSString *);
    SCDynamicStoreRef _store;
    CFRunLoopSourceRef _source;
    nw_path_monitor_t _pathMonitor;
    NSTimer *_periodic;
    NSTimer *_debounce;
    id _wakeObserver;
    NSString *_lastIPv4;
    NSString *_lastIPv6;
    NSUInteger _networkRevision;
    BOOL _checking;
    BOOL _checkAgain;
}

- (instancetype)initWithHandler:(void (^)(NSArray<NSString *> *))handler {
    self = [super init];
    if (!self) return nil;
    _handler = [handler copy];

    SCDynamicStoreContext context = {};
    context.info = (__bridge void *)self;
    _store = SCDynamicStoreCreate(nullptr, (__bridge CFStringRef)GuardName, NetworkChanged, &context);
    NSArray *patterns = @[@"State:/Network/(Global|Service/[^/]+|Interface/[^/]+)/(IPv4|IPv6|DNS|Link|PPP|IPSec|VPN|Proxies)$"];
    if (_store && SCDynamicStoreSetNotificationKeys(_store, nullptr, (__bridge CFArrayRef)patterns)) {
        _source = SCDynamicStoreCreateRunLoopSource(nullptr, _store, 0);
        if (_source) CFRunLoopAddSource(CFRunLoopGetMain(), _source, kCFRunLoopCommonModes);
    }

    __weak IPMonitor *weakSelf = self;
    _pathMonitor = nw_path_monitor_create();
    nw_path_monitor_set_queue(_pathMonitor, dispatch_get_main_queue());
    __block BOOL receivedInitialPath = NO;
    nw_path_monitor_set_update_handler(_pathMonitor, ^(nw_path_t path) {
        (void)path;
        if (receivedInitialPath) [weakSelf networkChanged];
        receivedInitialPath = YES;
    });
    nw_path_monitor_start(_pathMonitor);
    _wakeObserver = [NSWorkspace.sharedWorkspace.notificationCenter
        addObserverForName:NSWorkspaceDidWakeNotification object:nil queue:NSOperationQueue.mainQueue
        usingBlock:^(NSNotification *notification) {
            (void)notification;
            [weakSelf networkChanged];
        }];
    _periodic = [NSTimer timerWithTimeInterval:120 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf check];
    }];
    _periodic.tolerance = 10;
    [NSRunLoop.mainRunLoop addTimer:_periodic forMode:NSRunLoopCommonModes];
    [self check];
    return self;
}

- (void)stop {
    _handler = nil;
    _showResult = nil;
    if (_pathMonitor) {
        nw_path_monitor_cancel(_pathMonitor);
        _pathMonitor = nil;
    }
    [_periodic invalidate];
    [_debounce invalidate];
    if (_wakeObserver) {
        [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:_wakeObserver];
        _wakeObserver = nil;
    }
    if (_source) {
        CFRunLoopSourceInvalidate(_source);
        CFRelease(_source);
        _source = nullptr;
    }
    if (_store) {
        CFRelease(_store);
        _store = nullptr;
    }
}

- (void)networkChanged {
    if (!_handler) return;
    _networkRevision++;
    [_debounce invalidate];
    __weak IPMonitor *weakSelf = self;
    _debounce = [NSTimer timerWithTimeInterval:1 repeats:NO block:^(NSTimer *timer) {
        (void)timer;
        IPMonitor *monitor = weakSelf;
        if (!monitor) return;
        monitor->_debounce = nil;
        [monitor check];
    }];
    [NSRunLoop.mainRunLoop addTimer:_debounce forMode:NSRunLoopCommonModes];
}

- (void)checkWithResult:(void (^)(NSString *, NSString *))result {
    _showResult = [result copy];
    if (!_checking) [self check];
}

- (void)check {
    if (!_handler || _debounce.valid) return;
    if (_checking) {
        _checkAgain = YES;
        return;
    }
    _checking = YES;
    _checkAgain = NO;
    NSUInteger revision = _networkRevision;
    __weak IPMonitor *weakSelf = self;
    CheckIPs(^(NSString *ipv4, NSString *ipv6) {
        IPMonitor *monitor = weakSelf;
        if (!monitor || !monitor->_handler) return;
        monitor->_checking = NO;
        if (revision == monitor->_networkRevision) {
            NSMutableArray<NSString *> *changed = [NSMutableArray array];
            if (UpdateKnownAddress(ipv4, AF_INET, &monitor->_lastIPv4)) {
                [changed addObject:[@"IPv4   " stringByAppendingString:ipv4]];
            }
            if (UpdateKnownAddress(ipv6, AF_INET6, &monitor->_lastIPv6)) {
                [changed addObject:[@"IPv6   " stringByAppendingString:ipv6]];
            }
            if (changed.count) monitor->_handler(changed);
            void (^showResult)(NSString *, NSString *) = monitor->_showResult;
            monitor->_showResult = nil;
            if (showResult) showResult(ipv4, ipv6);
        }
        if (monitor->_checkAgain) [monitor check];
    });
}
@end

@interface GuardApp : NSObject <NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, NSDraggingDestination,
    UNUserNotificationCenterDelegate>
@property (copy) NSString *shortcutTarget;
@property (strong) NSStatusItem *statusItem;
@property (strong) NSPanel *addPanel;
@property (strong) NSWindow *settingsWindow;
@property (strong) NSBox *dropBox;
@property (strong) NSTextField *dropStatus;
@property (strong) NSWindow *prompt;
@property (strong) NSTextField *ipv4;
@property (strong) NSTextField *ipv6;
@property (strong) NSButton *refreshButton;
@property (strong) NSButton *openButton;
@property (copy) NSString *pendingTarget;
@property BOOL opening;
@property BOOL requestingNotifications;
@property (strong) IPMonitor *ipMonitor;
@property (copy) NSString *lastIPEvent;
@end

@implementation GuardApp

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    (void)notification;
    if (![NSBundle.mainBundle objectForInfoDictionaryKey:TargetBundleIDKey]) {
        UNUserNotificationCenter.currentNotificationCenter.delegate = self;
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.shortcutTarget = [NSBundle.mainBundle objectForInfoDictionaryKey:TargetBundleIDKey];
    if (self.shortcutTarget) {
        [self askToOpen:self.shortcutTarget];
        return;
    }

    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.image = [NSImage imageWithSystemSymbolName:@"shield" accessibilityDescription:GuardName];
    self.statusItem.button.toolTip = GuardName;
    self.statusItem.menu = [[NSMenu alloc] initWithTitle:GuardName];
    self.statusItem.menu.delegate = self;
    self.statusItem.menu.autoenablesItems = NO;
    [self updateIPMonitoring];
}

- (NSMenuItem *)addItem:(NSString *)title action:(SEL)action toMenu:(NSMenu *)menu {
    NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    item.enabled = action != nullptr;
    return item;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    [self addItem:L(@"Текущее соединение") action:nullptr toMenu:menu];
    NSMenuItem *ipv4Item = [self addItem:L(@"IPv4   Проверяю…") action:nullptr toMenu:menu];
    NSMenuItem *ipv6Item = [self addItem:L(@"IPv6   Проверяю…") action:nullptr toMenu:menu];
    NSMenuItem *monitorItem = nil;
    if (self.ipMonitor) {
        monitorItem = [self addItem:self.lastIPEvent ?: L(@"Мониторинг включён · смена IP ещё не обнаружена")
            action:nullptr toMenu:menu];
    }
    __weak GuardApp *weakSelf = self;
    void (^display)(NSString *, NSString *) = ^(NSString *ipv4, NSString *ipv6) {
        ipv4Item.title = [@"IPv4   " stringByAppendingString:ipv4];
        ipv6Item.title = [@"IPv6   " stringByAppendingString:ipv6];
        monitorItem.title = weakSelf.lastIPEvent ?: L(@"Мониторинг включён · смена IP ещё не обнаружена");
    };
    if (self.ipMonitor) {
        [self.ipMonitor checkWithResult:display];
    } else {
        CheckIPs(display);
    }
    [menu addItem:NSMenuItem.separatorItem];

    NSString *problem = nil;
    NSArray<NSString *> *identifiers = ReadApps(&problem);
    if (identifiers.count == 0) {
        [self addItem:problem ?: L(@"Список приложений пуст") action:nullptr toMenu:menu];
    }
    for (NSString *identifier in identifiers) {
        NSURL *url = FindApp(identifier);
        NSString *title = url ? AppName(url) : [identifier stringByAppendingString:L(@" (не найдено)")];
        NSMenuItem *item = [self addItem:title action:url ? @selector(selectApp:) : nullptr toMenu:menu];
        item.representedObject = identifier;
    }

    [menu addItem:NSMenuItem.separatorItem];
    [self addItem:L(@"Добавить приложения…") action:@selector(showAddPanel) toMenu:menu];
    [self addItem:L(@"Открыть .env") action:@selector(editConfig) toMenu:menu];
    [self addItem:L(@"Создать или обновить ярлыки для Dock")
        action:identifiers.count ? @selector(createLaunchers) : nullptr toMenu:menu];
    [menu addItem:NSMenuItem.separatorItem];
    [self addItem:L(@"Настройки…") action:@selector(showSettings) toMenu:menu];
    [self addItem:[L(@"Выйти из ") stringByAppendingString:GuardName] action:@selector(quit) toMenu:menu];
}

- (void)showSettings {
    if (!self.settingsWindow) {
        self.settingsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 340)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        self.settingsWindow.releasedWhenClosed = NO;
        [self.settingsWindow center];
    }
    [self refreshSettings];
    [NSApp activateIgnoringOtherApps:YES];
    [self.settingsWindow makeKeyAndOrderFront:nil];
}

- (void)refreshSettings {
    if (!self.settingsWindow) return;
    self.settingsWindow.title = L(@"Настройки Route Shield");
    NSUserDefaults *settings = NSUserDefaults.standardUserDefaults;

    NSPopUpButton *languages = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [languages addItemsWithTitles:@[@"Русский", @"English"]];
    [languages selectItemAtIndex:[[LanguagePreferences() stringForKey:LanguageKey] isEqualToString:@"en"] ? 1 : 0];
    languages.target = self;
    languages.action = @selector(changeLanguage:);
    [languages setAccessibilityLabel:L(@"Язык интерфейса")];
    NSStackView *languageRow = [NSStackView stackViewWithViews:
        @[[NSTextField labelWithString:L(@"Язык интерфейса")], languages]];
    languageRow.spacing = 12;

    NSButton *notify = [NSButton checkboxWithTitle:L(@"Уведомлять при смене IP")
        target:self action:@selector(toggleIPNotifications)];
    notify.state = [settings boolForKey:NotifyIPChangesKey] ? NSControlStateValueOn : NSControlStateValueOff;
    notify.enabled = !self.requestingNotifications;
    NSButton *test = [NSButton buttonWithTitle:L(@"Проверить уведомление")
        target:self action:@selector(testIPNotification)];
    test.enabled = notify.state == NSControlStateValueOn;
    NSButton *forceClose = [NSButton checkboxWithTitle:L(@"Принудительно закрывать приложения при смене IP")
        target:self action:@selector(toggleForceClose)];
    forceClose.state = [settings boolForKey:ForceCloseOnIPChangeKey] ? NSControlStateValueOn : NSControlStateValueOff;
    NSTextField *detail = [NSTextField wrappingLabelWithString:L(@"Несохранённые данные могут потеряться.")];
    detail.textColor = NSColor.secondaryLabelColor;
    SMAppServiceStatus status = SMAppService.mainAppService.status;
    NSButton *login = [NSButton checkboxWithTitle:L(@"Запускать при входе")
        target:self action:@selector(toggleLogin)];
    login.state = status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    NSStackView *stack = [NSStackView stackViewWithViews:@[languageRow, notify, test, forceClose, detail, login]];
    if (status == SMAppServiceStatusRequiresApproval) {
        login.enabled = NO;
        [stack addArrangedSubview:[NSButton buttonWithTitle:L(@"Разрешить запуск при входе…")
            target:self action:@selector(toggleLogin)]];
    }
    NSButton *about = [NSButton buttonWithTitle:L(@"О нас") target:self action:@selector(openRepository)];
    about.bordered = NO;
    about.attributedTitle = [[NSAttributedString alloc] initWithString:about.title attributes:@{
        NSFontAttributeName: about.font ?: [NSFont systemFontOfSize:NSFont.systemFontSize],
        NSForegroundColorAttributeName: NSColor.linkColor,
        NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle)
    }];
    [stack addArrangedSubview:about];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    [stack setCustomSpacing:22 afterView:languageRow];
    [stack setCustomSpacing:6 afterView:forceClose];
    [stack setCustomSpacing:18 afterView:detail];
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *view = [[NSView alloc] initWithFrame:self.settingsWindow.contentView.bounds];
    self.settingsWindow.contentView = view;
    [view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-24],
        [stack.topAnchor constraintEqualToAnchor:view.topAnchor constant:22],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:view.bottomAnchor constant:-16],
        [detail.widthAnchor constraintLessThanOrEqualToAnchor:stack.widthAnchor]
    ]];
}

- (void)openRepository {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:RepositoryURL]];
}

- (void)changeLanguage:(NSPopUpButton *)sender {
    [LanguagePreferences() setObject:sender.indexOfSelectedItem == 1 ? @"en" : @"ru" forKey:LanguageKey];
    self.lastIPEvent = nil;
    [self.addPanel close];
    self.addPanel = nil;
    self.dropBox = nil;
    self.dropStatus = nil;
    [self refreshSettings];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    if (self.settingsWindow.visible) [self refreshSettings];
}

- (void)showAddPanel {
    if (!self.addPanel) {
        self.addPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 460, 210)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow
            backing:NSBackingStoreBuffered defer:NO];
        self.addPanel.title = L(@"Добавить приложения");
        self.addPanel.floatingPanel = YES;
        self.addPanel.hidesOnDeactivate = NO;
        self.addPanel.releasedWhenClosed = NO;
        self.addPanel.delegate = self;
        [self.addPanel registerForDraggedTypes:@[NSPasteboardTypeFileURL]];

        self.dropBox = [[NSBox alloc] init];
        self.dropBox.boxType = NSBoxCustom;
        self.dropBox.cornerRadius = 12;
        self.dropBox.borderColor = NSColor.separatorColor;
        self.dropBox.fillColor = NSColor.controlBackgroundColor;
        self.dropBox.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *heading = [NSTextField labelWithString:L(@"Перетащите приложения сюда")];
        heading.font = [NSFont boldSystemFontOfSize:17];
        NSTextField *detail = [NSTextField labelWithString:L(@"Можно выбрать несколько значков в Finder.")];
        detail.textColor = NSColor.secondaryLabelColor;
        NSStackView *labels = [NSStackView stackViewWithViews:@[heading, detail]];
        labels.orientation = NSUserInterfaceLayoutOrientationVertical;
        labels.alignment = NSLayoutAttributeCenterX;
        labels.spacing = 8;
        labels.translatesAutoresizingMaskIntoConstraints = NO;
        NSView *boxContent = self.dropBox.contentView;
        [boxContent addSubview:labels];

        self.dropStatus = [NSTextField wrappingLabelWithString:L(@"Список обновится автоматически.")];
        self.dropStatus.translatesAutoresizingMaskIntoConstraints = NO;
        NSView *view = self.addPanel.contentView;
        [view addSubview:self.dropBox];
        [view addSubview:self.dropStatus];
        [NSLayoutConstraint activateConstraints:@[
            [labels.centerXAnchor constraintEqualToAnchor:boxContent.centerXAnchor],
            [labels.centerYAnchor constraintEqualToAnchor:boxContent.centerYAnchor],
            [self.dropBox.topAnchor constraintEqualToAnchor:view.topAnchor constant:20],
            [self.dropBox.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:20],
            [self.dropBox.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-20],
            [self.dropBox.heightAnchor constraintGreaterThanOrEqualToConstant:100],
            [self.dropStatus.topAnchor constraintEqualToAnchor:self.dropBox.bottomAnchor constant:14],
            [self.dropStatus.leadingAnchor constraintEqualToAnchor:self.dropBox.leadingAnchor],
            [self.dropStatus.trailingAnchor constraintEqualToAnchor:self.dropBox.trailingAnchor],
            [self.dropStatus.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:-20]
        ]];
        [self.addPanel center];
    }
    [NSApp activateIgnoringOtherApps:YES];
    [self.addPanel makeKeyAndOrderFront:nil];
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NSDragOperation copy = [self draggingUpdated:sender];
    if (copy) self.dropBox.borderColor = NSColor.controlAccentColor;
    return copy;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    return sender.draggingSourceOperationMask & NSDragOperationCopy;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
    (void)sender;
    self.dropBox.borderColor = NSColor.separatorColor;
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender {
    return [self draggingUpdated:sender] != NSDragOperationNone;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    self.dropBox.borderColor = NSColor.separatorColor;
    NSArray<NSURL *> *urls = [sender.draggingPasteboard readObjectsForClasses:@[[NSURL class]]
        options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    NSMutableOrderedSet<NSString *> *identifiers = [NSMutableOrderedSet orderedSet];
    NSUInteger skipped = 0;
    for (NSURL *url in urls) {
        NSString *identifier = BundleIDAtURL(url);
        if (IsTargetID(identifier)) {
            [identifiers addObject:identifier];
        } else {
            skipped++;
        }
    }
    if (identifiers.count == 0) {
        self.dropStatus.stringValue = L(@"Перетащите приложения (.app) из Finder.");
        return NO;
    }

    NSString *problem = nil;
    NSUInteger added = AddApps(ConfigURL(), identifiers.array, &problem);
    if (problem) {
        self.dropStatus.stringValue = [NSString stringWithFormat:L(@"Не удалось добавить приложения. %@"), problem];
        return NO;
    }
    self.dropStatus.stringValue = [NSString stringWithFormat:
        L(@"Добавлено: %lu. Уже в списке: %lu. Пропущено: %lu."),
        (unsigned long)added, (unsigned long)(identifiers.count - added), (unsigned long)skipped];
    return YES;
}

- (void)quit {
    [NSApp terminate:nil];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.ipMonitor stop];
}

- (void)updateIPMonitoring {
    NSUserDefaults *settings = NSUserDefaults.standardUserDefaults;
    if (![settings boolForKey:NotifyIPChangesKey] && ![settings boolForKey:ForceCloseOnIPChangeKey]) {
        [self.ipMonitor stop];
        self.ipMonitor = nil;
        self.lastIPEvent = nil;
    } else if (!self.ipMonitor) {
        __weak GuardApp *weakSelf = self;
        self.ipMonitor = [[IPMonitor alloc] initWithHandler:^(NSArray<NSString *> *changed) {
            [weakSelf handleIPChange:changed];
        }];
    }
}

- (void)toggleIPNotifications {
    NSUserDefaults *settings = NSUserDefaults.standardUserDefaults;
    if ([settings boolForKey:NotifyIPChangesKey]) {
        [settings setBool:NO forKey:NotifyIPChangesKey];
        [UNUserNotificationCenter.currentNotificationCenter removeAllPendingNotificationRequests];
        [self updateIPMonitoring];
        [self refreshSettings];
        return;
    }
    if (self.requestingNotifications) return;
    self.requestingNotifications = YES;
    [self refreshSettings];
    [UNUserNotificationCenter.currentNotificationCenter requestAuthorizationWithOptions:UNAuthorizationOptionAlert
        completionHandler:^(BOOL granted, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.requestingNotifications = NO;
                if (granted) {
                    [settings setBool:YES forKey:NotifyIPChangesKey];
                    [self updateIPMonitoring];
                } else {
                    ShowMessage(L(@"Уведомления недоступны"), error.localizedDescription ?:
                        L(@"Разрешите уведомления для Route Shield в системных настройках и включите этот пункт снова."));
                }
                [self refreshSettings];
            });
        }];
}

- (void)toggleForceClose {
    NSUserDefaults *settings = NSUserDefaults.standardUserDefaults;
    BOOL enabled = [settings boolForKey:ForceCloseOnIPChangeKey];
    if (!enabled) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = L(@"Принудительно закрывать приложения при смене IP?");
        alert.informativeText = L(@"Route Shield принудительно завершит запущенные приложения из списка. Несохранённые данные могут потеряться.");
        [alert addButtonWithTitle:L(@"Отмена")];
        [alert addButtonWithTitle:L(@"Включить")];
        [NSApp activateIgnoringOtherApps:YES];
        if ([alert runModal] != NSAlertSecondButtonReturn) {
            [self refreshSettings];
            return;
        }
    }
    [settings setBool:!enabled forKey:ForceCloseOnIPChangeKey];
    [self updateIPMonitoring];
    [self refreshSettings];
}

- (void)handleIPChange:(NSArray<NSString *> *)changed {
    NSUserDefaults *settings = NSUserDefaults.standardUserDefaults;
    NSString *time = [NSDateFormatter localizedStringFromDate:NSDate.date
        dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle];
    self.lastIPEvent = [L(@"Смена IP · ") stringByAppendingString:time];
    if ([settings boolForKey:ForceCloseOnIPChangeKey]) {
        NSString *problem = nil;
        NSUInteger running = 0;
        NSUInteger requested = 0;
        for (NSString *identifier in ReadApps(&problem)) {
            for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:identifier]) {
                if (app.terminated) continue;
                running++;
                if ([app forceTerminate]) requested++;
            }
        }
        self.lastIPEvent = problem ? [self.lastIPEvent stringByAppendingString:L(@" · ошибка в .env")] :
            [self.lastIPEvent stringByAppendingFormat:L(@" · запросов на закрытие %lu из %lu"),
                (unsigned long)requested, (unsigned long)running];
    }
    if ([settings boolForKey:NotifyIPChangesKey]) {
        [self postIPNotification:L(@"Внешний IP изменился") body:[changed componentsJoinedByString:@"\n"]
            completion:nil];
    }
}

- (void)postIPNotification:(NSString *)title body:(NSString *)body completion:(void (^)(NSError *))completion {
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = title;
    content.body = body;
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:NSUUID.UUID.UUIDString
        content:content trigger:nil];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request withCompletionHandler:completion];
}

- (void)testIPNotification {
    [self postIPNotification:[GuardName stringByAppendingString:L(@" · проверка")] body:L(@"Уведомление о смене IP будет выглядеть так.")
        completion:^(NSError *error) {
            if (!error) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                ShowMessage(L(@"Не удалось отправить уведомление"), error.localizedDescription);
            });
        }];
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    (void)center;
    (void)notification;
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList);
}

- (void)toggleLogin {
    SMAppService *service = SMAppService.mainAppService;
    if (service.status == SMAppServiceStatusRequiresApproval) {
        [SMAppService openSystemSettingsLoginItems];
        [self refreshSettings];
        return;
    }

    NSError *error = nil;
    BOOL success = service.status == SMAppServiceStatusEnabled ?
        [service unregisterAndReturnError:&error] : [service registerAndReturnError:&error];
    if (!success) {
        ShowMessage(L(@"Не удалось изменить автозапуск"), error.localizedDescription);
    } else if (service.status == SMAppServiceStatusRequiresApproval) {
        [SMAppService openSystemSettingsLoginItems];
    }
    [self refreshSettings];
}

- (void)editConfig {
    NSURL *url = ConfigURL();
    NSFileManager *files = NSFileManager.defaultManager;
    NSError *error = nil;
    if (![files fileExistsAtPath:url.path]) {
        NSURL *example = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@".env.example"];
        if (![files createDirectoryAtURL:url.URLByDeletingLastPathComponent
              withIntermediateDirectories:YES attributes:nil error:&error] ||
            ![files copyItemAtURL:example toURL:url error:&error]) {
            ShowMessage(L(@"Не удалось создать .env"), error.localizedDescription);
            return;
        }
    }

    NSURL *editor = FindApp(@"com.apple.TextEdit");
    if (!editor) {
        [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[url]];
        return;
    }
    [NSWorkspace.sharedWorkspace openURLs:@[url] withApplicationAtURL:editor
        configuration:NSWorkspaceOpenConfiguration.configuration completionHandler:^(
            NSRunningApplication *app, NSError *openError) {
        (void)app;
        if (openError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[url]];
            });
        }
    }];
}

- (void)selectApp:(NSMenuItem *)item {
    [self askToOpen:item.representedObject];
}

- (void)askToOpen:(NSString *)identifier {
    if (self.prompt || self.opening) {
        [NSApp activateIgnoringOtherApps:YES];
        [self.prompt makeKeyAndOrderFront:nil];
        return;
    }

    NSString *problem = nil;
    NSArray<NSString *> *identifiers = ReadApps(&problem);
    NSURL *url = [identifiers containsObject:identifier] ? FindApp(identifier) : nil;
    if (!url) {
        ShowMessage(L(@"Запуск отменён"), problem ?: L(@"Приложение не установлено или его Bundle ID отсутствует в .env."));
        if (self.shortcutTarget) [self quit];
        return;
    }

    self.pendingTarget = identifier;
    self.prompt = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 510, 250)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    self.prompt.releasedWhenClosed = NO;
    self.prompt.title = GuardName;
    self.prompt.delegate = self;

    NSTextField *heading = [NSTextField wrappingLabelWithString:
        [NSString stringWithFormat:L(@"Открыть «%@»?"), AppName(url)]];
    heading.font = [NSFont boldSystemFontOfSize:19];
    NSTextField *help = [NSTextField wrappingLabelWithString:
        L(@"Сверьте внешние адреса с адресами VPN перед запуском.")];
    self.ipv4 = [NSTextField labelWithString:@""];
    self.ipv6 = [NSTextField labelWithString:@""];
    for (NSTextField *label in @[self.ipv4, self.ipv6]) {
        label.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
        label.selectable = YES;
    }

    self.refreshButton = [NSButton buttonWithTitle:L(@"Проверить ещё раз") target:self action:@selector(refreshIPs)];
    NSButton *cancel = [NSButton buttonWithTitle:L(@"Отмена") target:self action:@selector(cancelOpen)];
    cancel.keyEquivalent = @"\e";
    self.openButton = [NSButton buttonWithTitle:L(@"Открыть") target:self action:@selector(confirmOpen)];
    NSStackView *buttons = [NSStackView stackViewWithViews:@[self.refreshButton, cancel, self.openButton]];
    buttons.spacing = 9;

    NSStackView *stack = [NSStackView stackViewWithViews:@[heading, help, self.ipv4, self.ipv6, buttons]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    [stack setCustomSpacing:20 afterView:self.ipv6];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    NSView *view = self.prompt.contentView;
    [view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-24],
        [stack.topAnchor constraintEqualToAnchor:view.topAnchor constant:22],
        [stack.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:-22],
        [heading.widthAnchor constraintLessThanOrEqualToAnchor:stack.widthAnchor],
        [help.widthAnchor constraintEqualToAnchor:stack.widthAnchor]
    ]];

    [self refreshIPs];
    [self.prompt center];
    [NSApp activateIgnoringOtherApps:YES];
    [self.prompt makeKeyAndOrderFront:nil];
    [self.prompt makeFirstResponder:cancel];
}

- (void)refreshIPs {
    NSWindow *prompt = self.prompt;
    self.ipv4.stringValue = L(@"IPv4   Проверяю…");
    self.ipv6.stringValue = L(@"IPv6   Проверяю…");
    self.openButton.enabled = NO;
    self.refreshButton.enabled = NO;
    CheckIPs(^(NSString *ipv4, NSString *ipv6) {
        if (self.prompt != prompt) return;
        self.ipv4.stringValue = [@"IPv4   " stringByAppendingString:ipv4];
        self.ipv6.stringValue = [@"IPv6   " stringByAppendingString:ipv6];
        self.refreshButton.enabled = YES;
        self.openButton.enabled = YES;
    });
}

- (void)cancelOpen {
    [self.prompt close];
}

- (void)windowWillClose:(NSNotification *)notification {
    if (notification.object != self.prompt) return;
    self.prompt = nil;
    self.pendingTarget = nil;
    if (self.shortcutTarget && !self.opening) [self quit];
}

- (void)confirmOpen {
    if (!self.openButton.enabled || !self.prompt || self.opening) return;
    self.opening = YES;
    NSString *identifier = self.pendingTarget;
    [self.prompt close];

    NSString *problem = nil;
    NSArray<NSString *> *identifiers = ReadApps(&problem);
    NSURL *url = [identifiers containsObject:identifier] ? FindApp(identifier) : nil;
    if (!url) {
        self.opening = NO;
        ShowMessage(L(@"Запуск отменён"), problem ?: L(@"Приложение не установлено или удалено из .env."));
        if (self.shortcutTarget) [self quit];
        return;
    }

    [NSWorkspace.sharedWorkspace openApplicationAtURL:url
        configuration:NSWorkspaceOpenConfiguration.configuration completionHandler:^(
            NSRunningApplication *app, NSError *error) {
        (void)app;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.opening = NO;
            if (error) ShowMessage(L(@"Не удалось открыть приложение"), error.localizedDescription);
            if (self.shortcutTarget) [self quit];
        });
    }];
}

- (void)createLaunchers {
    NSString *problem = nil;
    NSArray<NSString *> *identifiers = ReadApps(&problem);
    if (problem) {
        ShowMessage(L(@"Не удалось создать ярлыки"), problem);
        return;
    }

    NSError *error = nil;
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *folder = LaunchersURL();
    if (![files createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:&error]) {
        ShowMessage(L(@"Не удалось создать папку с ярлыками"), error.localizedDescription);
        return;
    }

    NSMutableArray<NSString *> *issues = [NSMutableArray array];
    for (NSString *identifier in identifiers) {
        NSURL *target = FindApp(identifier);
        if (!target) {
            [issues addObject:[NSString stringWithFormat:L(@"%@ — приложение не найдено."), identifier]];
            continue;
        }
        NSString *name = [AppName(target) stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
        NSURL *dest = [folder URLByAppendingPathComponent:
            [NSString stringWithFormat:@"%@ — %@.app", name, GuardName]];
        BOOL replace = [files fileExistsAtPath:dest.path];
        if (replace && !OwnsLauncher(dest, identifier)) {
            [issues addObject:[NSString stringWithFormat:L(@"%@ — такой ярлык уже есть."), name]];
            continue;
        }

        error = nil;
        if (!InstallLauncher(target, identifier, dest, NSBundle.mainBundle, replace, &error)) {
            [issues addObject:[NSString stringWithFormat:@"%@ — %@", name,
                error.localizedDescription ?: L(@"не удалось сохранить или подписать ярлык.")]];
        }
    }

    if (issues.count) ShowMessage(L(@"Часть ярлыков недоступна"), [issues componentsJoinedByString:@"\n"]);
    [NSWorkspace.sharedWorkspace openURL:folder];
}
@end

int main() {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        __attribute__((objc_precise_lifetime)) GuardApp *delegate = [[GuardApp alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
