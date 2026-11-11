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
#include <unistd.h>

static NSString *const GuardBundleID = @"local.vpnguard";
static NSString *const GuardName = @"Route Shield";
static NSString *const RepositoryURL = @"https://github.com/01trisha/route-shield";
static NSString *const TargetBundleIDKey = @"VPNGuardTargetBundleIdentifier";
static NSString *const NotifyIPChangesKey = @"NotifyIPChanges";
static NSString *const ForceCloseOnIPChangeKey = @"ForceCloseOnIPChange";
static NSString *const LanguageKey = @"InterfaceLanguage";
static NSString *const WelcomeCompletedKey = @"WelcomeCompleted";
static NSString *const ShowIPv4Key = @"ShowIPv4";
static NSString *const ShowIPv6Key = @"ShowIPv6";
static NSString *const ShowCountryKey = @"ShowCountry";
static NSString *const NotificationDetailsKey = @"NotificationDetails";
static NSString *const LastUpdateCheckKey = @"LastUpdateCheck";
static NSString *const LatestReleaseTagKey = @"LatestReleaseTag";
static NSString *const UpdateNotificationTagKey = @"UpdateReleaseTag";
static const NSTimeInterval UpdateCheckInterval = 24 * 60 * 60;

typedef NS_ENUM(NSInteger, NotificationDetails) {
    NotificationDetailsAddress,
    NotificationDetailsCountry,
    NotificationDetailsAddressAndCountry,
};

static NSUserDefaults *InterfacePreferences() {
    if (![NSBundle.mainBundle objectForInfoDictionaryKey:TargetBundleIDKey]) {
        return NSUserDefaults.standardUserDefaults;
    }

    // Dock shortcuts have separate bundle IDs and read the main app's preferences.
    static NSUserDefaults *preferences;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        preferences = [[NSUserDefaults alloc] initWithSuiteName:GuardBundleID];
    });
    return preferences;
}

static BOOL UsesEnglish() {
    NSString *saved = [InterfacePreferences() stringForKey:LanguageKey];
    if (saved) return [saved isEqualToString:@"en"];

    NSString *preferred = NSLocale.preferredLanguages.firstObject ?: @"en";
    NSString *language = [NSLocale componentsFromLocaleIdentifier:preferred][NSLocaleLanguageCode];
    return ![language isEqualToString:@"ru"];
}

static BOOL ShowsConnectionField(NSString *key) {
    NSUserDefaults *settings = InterfacePreferences();
    return ![settings objectForKey:key] || [settings boolForKey:key];
}

static NSString *L(NSString *russian) {
    if (!UsesEnglish()) return russian;
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

static NSURL *ConfigTemplateURL() {
    return [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@".env.example"];
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

// Return an owned handle so the caller's scope controls when the lock is released.
static NSFileHandle *LockConfigDirectory(NSURL *config, NSError **error) NS_RETURNS_RETAINED {
    NSURL *directory = config.URLByDeletingLastPathComponent;
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory
           withIntermediateDirectories:YES attributes:nil error:error]) return nil;

    // Lock the directory so the lock survives atomic replacement of .env.
    int fd = open(directory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd != -1 && flock(fd, LOCK_EX) == 0) {
        return [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
    }
    *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    if (fd != -1) close(fd);
    return nil;
}

static BOOL PrepareConfigForEditing(NSURL *config, NSError **error) {
    __attribute__((objc_precise_lifetime)) NSFileHandle *lock = LockConfigDirectory(config, error);
    if (!lock) return NO;
    NSFileManager *files = NSFileManager.defaultManager;
    if (![files fileExistsAtPath:config.path]) {
        return [files copyItemAtURL:ConfigTemplateURL() toURL:config error:error];
    }

    // Translate only comments generated by older builds. Leave user edits intact.
    NSString *contents = [NSString stringWithContentsOfURL:config encoding:NSUTF8StringEncoding error:nil];
    if (!contents) return YES;
    NSDictionary<NSString *, NSString *> *oldComments = @{
        @"# Укажите Bundle ID приложений через запятую.": @"# Enter app bundle IDs separated by commas.",
        @"# Пример: APPS=com.apple.Safari,com.google.Chrome": @"# Example: APPS=com.apple.Safari,com.google.Chrome"
    };
    NSMutableString *updated = [contents mutableCopy];
    [contents enumerateSubstringsInRange:NSMakeRange(0, contents.length)
        options:NSStringEnumerationByLines | NSStringEnumerationReverse
        usingBlock:^(NSString *line, NSRange range, NSRange enclosingRange, BOOL *stop) {
            (void)enclosingRange;
            (void)stop;
            NSString *replacement = oldComments[line];
            if (replacement) [updated replaceCharactersInRange:range withString:replacement];
        }];
    return [updated isEqualToString:contents] ||
        [updated writeToURL:config atomically:YES encoding:NSUTF8StringEncoding error:error];
}

static NSUInteger AddApps(NSURL *config, NSArray<NSString *> *droppedIDs, NSString **problem) {
    NSError *error = nil;
    __attribute__((objc_precise_lifetime)) NSFileHandle *lock = LockConfigDirectory(config, &error);
    if (!lock) {
        *problem = error.localizedDescription;
        return 0;
    }
    NSURL *source = [NSFileManager.defaultManager fileExistsAtPath:config.path] ? config : ConfigTemplateURL();
    NSString *contents = ReadConfig(source, problem);
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

static NSString *ReleaseVersion(id tag) {
    if (![tag isKindOfClass:NSString.class]) return nil;
    NSString *value = tag;
    if ([value rangeOfString:@"\\Av?[0-9]+\\.[0-9]+\\.[0-9]+\\z"
                    options:NSRegularExpressionSearch].location == NSNotFound) return nil;
    return [value hasPrefix:@"v"] ? [value substringFromIndex:1] : value;
}

static NSString *CurrentAppVersion() {
    return [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
}

static NSString *AvailableUpdateTag() {
    NSString *tag = [NSUserDefaults.standardUserDefaults stringForKey:LatestReleaseTagKey];
    NSString *latest = ReleaseVersion(tag);
    NSString *current = ReleaseVersion(CurrentAppVersion());
    return latest && current && [latest compare:current options:NSNumericSearch] == NSOrderedDescending ? tag : nil;
}

static NSString *ReleaseTagFromResponse(NSData *data) {
    if (!data) return nil;
    id response = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![response isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *release = response;
    if ([release[@"draft"] isEqual:@YES] || [release[@"prerelease"] isEqual:@YES]) return nil;
    id tag = release[@"tag_name"];
    return ReleaseVersion(tag) ? tag : nil;
}

static NSURL *ReleaseURL(NSString *tag) {
    if (!ReleaseVersion(tag)) return nil;
    NSString *address = [NSString stringWithFormat:@"%@/releases/tag/%@", RepositoryURL, tag];
    return [NSURL URLWithString:address];
}

static void CheckLatestRelease(void (^complete)(NSString *)) {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.timeoutIntervalForRequest = 10;
        config.timeoutIntervalForResource = 20;
        session = [NSURLSession sessionWithConfiguration:config];
    });
    NSString *repositoryPath = [NSURL URLWithString:RepositoryURL].path;
    NSURL *endpoint = [NSURL URLWithString:
        [NSString stringWithFormat:@"https://api.github.com/repos%@/releases/latest", repositoryPath]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:endpoint];
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Route-Shield" forHTTPHeaderField:@"User-Agent"];
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        NSString *tag = !error && http.statusCode == 200 ? ReleaseTagFromResponse(data) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ complete(tag); });
    }] resume];
}

static NSFileHandle *AcquireMainInstanceLock(int *failure) {
    NSString *name = [NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".lock"];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd == -1) {
        *failure = errno;
        return nil;
    }
    if (flock(fd, LOCK_EX | LOCK_NB) == -1) {
        *failure = errno;
        close(fd);
        return nil;
    }
    return [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
}

static NSData *FetchNetworkData(NSString *endpoint, NSArray<NSString *> *options, int *exitStatus) {
    NSTask *curl = [[NSTask alloc] init];
    curl.executableURL = [NSURL fileURLWithPath:@"/usr/bin/curl"];
    NSMutableArray<NSString *> *arguments = [@[@"-q", @"--noproxy", @"*",
        @"--fail", @"--silent", @"--connect-timeout", @"3", @"--max-time", @"6",
        @"--max-filesize", @"1024"] mutableCopy];
    [arguments addObjectsFromArray:options];
    [arguments addObject:endpoint];
    curl.arguments = arguments;
    NSPipe *pipe = [NSPipe pipe];
    curl.standardOutput = pipe;
    if (![curl launchAndReturnError:nil]) {
        *exitStatus = -1;
        return nil;
    }
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [curl waitUntilExit];
    *exitStatus = curl.terminationStatus;
    return *exitStatus == 0 ? data : nil;
}

static NSString *LookupIP(int family) {
    // Use a fixed source per family so a provider change can't trigger an IP change.
    NSString *endpoint = family == AF_INET ? @"https://api.ipify.org" : @"https://ifconfig.me/ip";
    int status;
    NSData *data = FetchNetworkData(endpoint, @[family == AF_INET ? @"-4" : @"-6"], &status);
    if (status == -1) return L(@"Не удалось запустить curl");
    if (!data) return [NSString stringWithFormat:L(@"Не удалось получить (curl %d)"), status];

    NSString *address = Trim([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
    struct in6_addr parsed = {};
    char normalized[INET6_ADDRSTRLEN];
    if (address.length == 0 || inet_pton(family, address.UTF8String, &parsed) != 1 ||
        !inet_ntop(family, &parsed, normalized, sizeof(normalized))) {
        return L(@"Сервис не вернул адрес этого семейства");
    }
    return [NSString stringWithUTF8String:normalized];
}

static void RunNetworkChecks(NSString *(^lookup)(int), void (^complete)(NSString *, NSString *)) {
    dispatch_group_t checks = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    __block NSString *ipv4 = nil;
    __block NSString *ipv6 = nil;
    dispatch_group_async(checks, queue, ^{ ipv4 = lookup(AF_INET); });
    dispatch_group_async(checks, queue, ^{ ipv6 = lookup(AF_INET6); });
    dispatch_group_notify(checks, queue, ^{
        // Deliver results even while AppKit is tracking the open menu.
        CFRunLoopRef mainLoop = CFRunLoopGetMain();
        NSArray *modes = @[NSRunLoopCommonModes, NSEventTrackingRunLoopMode];
        CFRunLoopPerformBlock(mainLoop, (__bridge CFArrayRef)modes, ^{ complete(ipv4, ipv6); });
        CFRunLoopWakeUp(mainLoop);
    });
}

static void CheckIPs(void (^complete)(NSString *, NSString *)) {
    RunNetworkChecks(^NSString *(int family) { return LookupIP(family); }, complete);
}

static BOOL IsIPAddress(NSString *sample, int family) {
    struct in6_addr parsed = {};
    return sample.length > 0 && inet_pton(family, sample.UTF8String, &parsed) == 1;
}

static NSString *CountryCodeFromResponse(NSData *data) {
    if (!data) return nil;
    id response = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    id code = [response isKindOfClass:NSDictionary.class] ? response[@"country"] : nil;
    return [code isKindOfClass:NSString.class] && [NSLocale.ISOCountryCodes containsObject:code] ? code : nil;
}

static NSString *LookupCountryCode(NSString *address) {
    static NSCache<NSString *, NSString *> *countries;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        countries = [[NSCache alloc] init];
        countries.countLimit = 64;
    });
    NSString *code = [countries objectForKey:address];
    if (code) return code;

    // The caller supplies a validated IP literal, so it is safe as a single URL path component.
    NSString *endpoint = [@"https://api.country.is/" stringByAppendingString:address];
    int status;
    code = CountryCodeFromResponse(FetchNetworkData(endpoint, @[], &status));
    if (code) [countries setObject:code forKey:address];
    return code;
}

static NSString *CountryLine(NSString *detail) {
    return [NSString stringWithFormat:L(@"Страна по IP: %@"), detail];
}

static NSString *CountryName(NSString *code) {
    if (!code) return L(@"не определена");
    NSLocale *locale = [NSLocale localeWithLocaleIdentifier:UsesEnglish() ? @"en" : @"ru"];
    return [locale localizedStringForCountryCode:code] ?: code;
}

static NSString *ConnectionCountryBlock(NSString *country4, NSString *country6) {
    return [NSString stringWithFormat:@"%@\nIPv4: %@\nIPv6: %@", L(@"Страна соединения:"), country4, country6];
}

static NSString *CountrySummary(NSString *code4, NSString *code6, BOOL hasIPv4, BOOL hasIPv6) {
    if (hasIPv4 && hasIPv6 && (code4 || code6) && ![code4 isEqualToString:code6]) {
        return CountryLine([NSString stringWithFormat:@"IPv4: %@ · IPv6: %@",
            CountryName(code4), CountryName(code6)]);
    }
    return CountryLine(CountryName(code4 ?: code6));
}

static void CheckCountries(NSString *ipv4, NSString *ipv6, void (^complete)(NSString *, NSString *)) {
    BOOL hasIPv4 = IsIPAddress(ipv4, AF_INET);
    BOOL hasIPv6 = IsIPAddress(ipv6, AF_INET6);
    if (!hasIPv4 && !hasIPv6) {
        complete(nil, nil);
        return;
    }
    RunNetworkChecks(^NSString *(int family) {
        if (family == AF_INET) return hasIPv4 ? LookupCountryCode(ipv4) : nil;
        return hasIPv6 ? LookupCountryCode(ipv6) : nil;
    }, complete);
}

static BOOL UpdateKnownAddress(NSString *sample, int family, NSString *__strong *previous) {
    if (!IsIPAddress(sample, family)) return NO;
    BOOL changed = *previous && ![*previous isEqualToString:sample];
    *previous = sample;
    return changed;
}

static NSString *IPNotificationBody(NotificationDetails details, NSString *ipv4, NSString *ipv6, NSString *country) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    if (details != NotificationDetailsCountry) {
        if (ipv4) [lines addObject:[@"IPv4: " stringByAppendingString:ipv4]];
        if (ipv6) [lines addObject:[@"IPv6: " stringByAppendingString:ipv6]];
    }
    if (details != NotificationDetailsAddress && country) [lines addObject:country];
    return lines.count ? [lines componentsJoinedByString:@"\n"] : L(@"Внешний IP недоступен.");
}

static void CheckNotificationBody(NotificationDetails details, NSString *ipv4, NSString *ipv6,
                                  void (^complete)(NSString *)) {
    if (details == NotificationDetailsCountry || details == NotificationDetailsAddressAndCountry) {
        CheckCountries(ipv4, ipv6, ^(NSString *code4, NSString *code6) {
            NSString *country = CountrySummary(code4, code6, ipv4 != nil, ipv6 != nil);
            complete(IPNotificationBody(details, ipv4, ipv6, country));
        });
    } else {
        complete(IPNotificationBody(details, ipv4, ipv6, nil));
    }
}

static NSView *StackContent(NSArray<NSView *> *controls, CGFloat padding) {
    NSView *view = [[NSView alloc] initWithFrame:NSZeroRect];
    NSStackView *stack = [NSStackView stackViewWithViews:controls];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:padding],
        [stack.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-padding],
        [stack.topAnchor constraintEqualToAnchor:view.topAnchor constant:padding],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:view.bottomAnchor constant:-padding]
    ]];
    return view;
}

static NSTabViewItem *SettingsTab(NSString *identifier, NSString *title, NSArray<NSView *> *controls) {
    NSTabViewItem *tab = [[NSTabViewItem alloc] initWithIdentifier:identifier];
    tab.label = title;
    tab.view = StackContent(controls, 20);
    return tab;
}

@interface IPMonitor : NSObject
- (instancetype)initWithHandler:(void (^)(NSString *, NSString *))handler;
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
    void (^_handler)(NSString *, NSString *);
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

- (instancetype)initWithHandler:(void (^)(NSString *, NSString *))handler {
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
            BOOL changed4 = UpdateKnownAddress(ipv4, AF_INET, &monitor->_lastIPv4);
            BOOL changed6 = UpdateKnownAddress(ipv6, AF_INET6, &monitor->_lastIPv6);
            if (changed4 || changed6) monitor->_handler(changed4 ? ipv4 : nil, changed6 ? ipv6 : nil);
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
@property (strong) NSTabView *settingsTabs;
@property (strong) NSWindow *welcomeWindow;
@property (strong) NSBox *dropBox;
@property (strong) NSTextField *dropStatus;
@property (strong) NSWindow *prompt;
@property (strong) NSTextField *ipv4;
@property (strong) NSTextField *ipv6;
@property (strong) NSTextField *country;
@property (strong) NSTextField *promptHelp;
@property NSUInteger promptCheckRevision;
@property (strong) NSButton *refreshButton;
@property (strong) NSButton *openButton;
@property (copy) NSString *pendingTarget;
@property BOOL opening;
@property BOOL requestingNotifications;
@property BOOL testingNotification;
@property BOOL checkingForUpdate;
@property BOOL updateResultRequested;
@property (strong) NSTimer *updateCheckTimer;
@property (strong) IPMonitor *ipMonitor;
@property (copy) NSString *lastIPEvent;
@property (strong) NSMutableSet<NSNumber *> *closingPIDs;
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
    NSUserDefaults *settings = InterfacePreferences();
    if (![settings objectForKey:WelcomeCompletedKey]) {
        BOOL hasPreviousSetup = [settings objectForKey:LanguageKey] ||
            [settings objectForKey:NotifyIPChangesKey] || [settings objectForKey:ForceCloseOnIPChangeKey] ||
            [NSFileManager.defaultManager fileExistsAtPath:ConfigURL().path];
        [settings setBool:hasPreviousSetup forKey:WelcomeCompletedKey];
    }
    if ([settings boolForKey:WelcomeCompletedKey]) {
        [self startMenuBar];
    } else {
        [self showWelcome];
    }
}

- (void)startMenuBar {
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.image = [NSImage imageWithSystemSymbolName:@"shield" accessibilityDescription:GuardName];
    self.statusItem.menu = [[NSMenu alloc] initWithTitle:GuardName];
    self.statusItem.menu.delegate = self;
    self.statusItem.menu.autoenablesItems = NO;
    [self updateIPMonitoring];
    [self updateAvailableReleaseIndicator];
    [self scheduleUpdateCheck];
}

- (NSMenuItem *)addItem:(NSString *)title action:(SEL)action toMenu:(NSMenu *)menu {
    NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    item.enabled = action != nullptr;
    return item;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    BOOL showIPv4 = ShowsConnectionField(ShowIPv4Key);
    BOOL showIPv6 = ShowsConnectionField(ShowIPv6Key);
    BOOL showCountry = ShowsConnectionField(ShowCountryKey);
    BOOL showConnection = showIPv4 || showIPv6 || showCountry;
    if (showConnection) [self addItem:L(@"Текущее соединение") action:nullptr toMenu:menu];
    NSMenuItem *ipv4Item = showIPv4 ? [self addItem:L(@"IPv4   Проверяю…") action:nullptr toMenu:menu] : nil;
    NSMenuItem *ipv6Item = showIPv6 ? [self addItem:L(@"IPv6   Проверяю…") action:nullptr toMenu:menu] : nil;
    NSMenuItem *country4Item = nil;
    NSMenuItem *country6Item = nil;
    if (showCountry) {
        [self addItem:L(@"Страна соединения:") action:nullptr toMenu:menu];
        country4Item = [self addItem:[@"IPv4: " stringByAppendingString:L(@"Определяю…")] action:nullptr toMenu:menu];
        country6Item = [self addItem:[@"IPv6: " stringByAppendingString:L(@"Определяю…")] action:nullptr toMenu:menu];
        country4Item.indentationLevel = 1;
        country6Item.indentationLevel = 1;
    }
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
        if (country4Item.menu) {
            CheckCountries(ipv4, ipv6, ^(NSString *code4, NSString *code6) {
                country4Item.title = [@"IPv4: " stringByAppendingString:CountryName(code4)];
                country6Item.title = [@"IPv6: " stringByAppendingString:CountryName(code6)];
            });
        }
    };
    if (self.ipMonitor) {
        [self.ipMonitor checkWithResult:display];
    } else if (showConnection) {
        CheckIPs(display);
    }
    if (showConnection || monitorItem) [menu addItem:NSMenuItem.separatorItem];

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
    [self addItem:L(@"Создать или обновить ярлыки для Dock")
        action:identifiers.count ? @selector(createLaunchers) : nullptr toMenu:menu];
    [menu addItem:NSMenuItem.separatorItem];
    NSString *update = AvailableUpdateTag();
    if (update) {
        NSString *title = [NSString stringWithFormat:L(@"Доступна версия %@…"), ReleaseVersion(update)];
        [self addItem:title action:@selector(openAvailableUpdate) toMenu:menu];
    }
    [self addItem:L(@"Настройки…") action:@selector(showSettings) toMenu:menu];
    [self addItem:[L(@"Выйти из ") stringByAppendingString:GuardName] action:@selector(quit) toMenu:menu];
}

- (NSStackView *)languageRow {
    NSPopUpButton *languages = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [languages addItemsWithTitles:@[@"Русский", @"English"]];
    [languages selectItemAtIndex:UsesEnglish() ? 1 : 0];
    languages.target = self;
    languages.action = @selector(changeLanguage:);
    [languages setAccessibilityLabel:L(@"Язык интерфейса")];
    NSStackView *row = [NSStackView stackViewWithViews:
        @[[NSTextField labelWithString:L(@"Язык интерфейса")], languages]];
    row.spacing = 12;
    return row;
}

- (void)showWelcome {
    if (!self.welcomeWindow) {
        self.welcomeWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 480, 235)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        self.welcomeWindow.releasedWhenClosed = NO;
        self.welcomeWindow.delegate = self;
        [self.welcomeWindow center];
    }
    self.welcomeWindow.title = GuardName;
    NSTextField *heading = [NSTextField labelWithString:L(@"Добро пожаловать в Route Shield")];
    heading.font = [NSFont boldSystemFontOfSize:21];
    NSTextField *intro = [NSTextField wrappingLabelWithString:
        L(@"Route Shield показывает внешний IP в строке меню и перед запуском выбранных приложений. При смене IP он может уведомить вас и завершить эти приложения.")];
    intro.preferredMaxLayoutWidth = 432;
    NSButton *proceed = [NSButton buttonWithTitle:L(@"Продолжить") target:self action:@selector(continueWelcome)];
    proceed.keyEquivalent = @"\r";
    self.welcomeWindow.contentView = StackContent(@[heading, intro, [self languageRow], proceed], 24);
    [NSApp activateIgnoringOtherApps:YES];
    [self.welcomeWindow makeKeyAndOrderFront:nil];
}

- (void)continueWelcome {
    NSUserDefaults *settings = InterfacePreferences();
    [settings setObject:UsesEnglish() ? @"en" : @"ru" forKey:LanguageKey];
    [settings setBool:YES forKey:WelcomeCompletedKey];
    NSWindow *window = self.welcomeWindow;
    self.welcomeWindow = nil;
    [window close];
    [self startMenuBar];
    dispatch_async(dispatch_get_main_queue(), ^{ [self.statusItem.button performClick:nil]; });
}

- (void)showSettings {
    if (!self.settingsWindow) {
        self.settingsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 530, 435)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        self.settingsWindow.releasedWhenClosed = NO;
        [self.settingsWindow center];
    }
    [self refreshSettings];
    [NSApp activateIgnoringOtherApps:YES];
    [self.settingsWindow makeKeyAndOrderFront:nil];
}

- (NSButton *)connectionCheckbox:(NSString *)title key:(NSString *)key {
    NSButton *button = [NSButton checkboxWithTitle:title target:self action:@selector(changeConnectionField:)];
    button.identifier = key;
    button.state = ShowsConnectionField(key) ? NSControlStateValueOn : NSControlStateValueOff;
    return button;
}

- (NSArray<NSView *> *)generalControls {
    BOOL waitingForUpdate = self.checkingForUpdate && self.updateResultRequested;
    NSButton *checkUpdates = [NSButton buttonWithTitle:waitingForUpdate ? L(@"Проверяю обновления…") : L(@"Проверить обновления…")
        target:self action:@selector(checkForUpdates)];
    checkUpdates.enabled = !waitingForUpdate;
    NSTextField *version = [NSTextField labelWithString:[NSString stringWithFormat:L(@"Версия %@"), CurrentAppVersion()]];
    version.textColor = NSColor.secondaryLabelColor;
    NSStackView *updates = [NSStackView stackViewWithViews:@[checkUpdates, version]];
    updates.spacing = 12;
    NSTextField *connection = [NSTextField labelWithString:L(@"Информация о соединении")];
    connection.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
    NSButton *forceClose = [NSButton checkboxWithTitle:L(@"Принудительно закрывать приложения при смене IP")
        target:self action:@selector(toggleForceClose)];
    forceClose.state = [NSUserDefaults.standardUserDefaults boolForKey:ForceCloseOnIPChangeKey]
        ? NSControlStateValueOn : NSControlStateValueOff;
    NSTextField *detail = [NSTextField labelWithString:L(@"Несохранённые данные могут потеряться.")];
    detail.textColor = NSColor.secondaryLabelColor;
    SMAppServiceStatus status = SMAppService.mainAppService.status;
    NSButton *login = [NSButton checkboxWithTitle:L(@"Запускать при входе")
        target:self action:@selector(toggleLogin)];
    login.state = status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    NSMutableArray<NSView *> *controls = [@[
        updates, [self languageRow], connection,
        [self connectionCheckbox:L(@"Показывать IPv4") key:ShowIPv4Key],
        [self connectionCheckbox:L(@"Показывать IPv6") key:ShowIPv6Key],
        [self connectionCheckbox:L(@"Показывать страну") key:ShowCountryKey],
        login, forceClose, detail
    ] mutableCopy];
    if (status == SMAppServiceStatusRequiresApproval) {
        login.enabled = NO;
        [controls insertObject:[NSButton buttonWithTitle:L(@"Разрешить запуск при входе…")
            target:self action:@selector(toggleLogin)] atIndex:7];
    }
    [controls addObject:[NSButton buttonWithTitle:L(@"Открыть конфигурационный файл…")
        target:self action:@selector(editConfig)]];
    return controls;
}

- (NSArray<NSView *> *)notificationControls {
    NSUserDefaults *settings = NSUserDefaults.standardUserDefaults;
    BOOL enabled = [settings boolForKey:NotifyIPChangesKey];
    NSButton *notify = [NSButton checkboxWithTitle:L(@"Уведомлять при смене IP")
        target:self action:@selector(toggleIPNotifications)];
    notify.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    notify.enabled = !self.requestingNotifications;
    NSPopUpButton *details = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [details addItemsWithTitles:@[L(@"IP-адрес"), L(@"Страна"), L(@"IP-адрес и страна")]];
    [details selectItemAtIndex:[settings integerForKey:NotificationDetailsKey]];
    details.target = self;
    details.action = @selector(changeNotificationDetails:);
    [details setAccessibilityLabel:L(@"Содержимое уведомления")];
    NSStackView *row = [NSStackView stackViewWithViews:
        @[[NSTextField labelWithString:L(@"Содержимое уведомления")], details]];
    row.spacing = 12;
    NSButton *test = [NSButton buttonWithTitle:self.testingNotification ? L(@"Проверяю соединение…") : L(@"Проверить уведомление")
        target:self action:@selector(testIPNotification)];
    test.enabled = enabled && !self.testingNotification;
    return @[notify, row, test];
}

- (void)refreshSettings {
    if (!self.settingsWindow) return;
    self.settingsWindow.title = L(@"Настройки Route Shield");
    NSString *selected = self.settingsTabs.selectedTabViewItem.identifier;
    NSTabView *tabs = [[NSTabView alloc] initWithFrame:self.settingsWindow.contentView.bounds];
    [tabs addTabViewItem:SettingsTab(@"general", L(@"Основные"), [self generalControls])];
    [tabs addTabViewItem:SettingsTab(@"notifications", L(@"Уведомления"), [self notificationControls])];
    NSButton *about = [NSButton buttonWithTitle:L(@"Репозиторий на GitHub") target:self action:@selector(openRepository)];
    about.bordered = NO;
    about.attributedTitle = [[NSAttributedString alloc] initWithString:about.title attributes:@{
        NSFontAttributeName: about.font ?: [NSFont systemFontOfSize:NSFont.systemFontSize],
        NSForegroundColorAttributeName: NSColor.linkColor,
        NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle)
    }];
    [tabs addTabViewItem:SettingsTab(@"about", L(@"О нас"), @[[NSTextField labelWithString:GuardName], about])];
    if (selected) [tabs selectTabViewItemWithIdentifier:selected];
    self.settingsTabs = tabs;
    self.settingsWindow.contentView = tabs;
}

- (void)openRepository {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:RepositoryURL]];
}

- (void)openAvailableUpdate {
    NSURL *url = ReleaseURL(AvailableUpdateTag());
    if (url) [NSWorkspace.sharedWorkspace openURL:url];
}

- (void)updateAvailableReleaseIndicator {
    BOOL available = AvailableUpdateTag() != nil;
    NSStatusBarButton *button = self.statusItem.button;
    button.imagePosition = available ? NSImageLeft : NSImageOnly;
    button.title = available ? @" •" : @"";
    NSString *label = available ? L(@"Доступно обновление Route Shield") : GuardName;
    button.toolTip = label;
    [button setAccessibilityLabel:label];
}

- (void)scheduleUpdateCheck {
    [self.updateCheckTimer invalidate];
    self.updateCheckTimer = nil;
    id lastCheck = [NSUserDefaults.standardUserDefaults objectForKey:LastUpdateCheckKey];
    NSTimeInterval elapsed = [lastCheck isKindOfClass:NSDate.class] ? -[lastCheck timeIntervalSinceNow] : UpdateCheckInterval;
    NSTimeInterval delay = UpdateCheckInterval - MAX(0, elapsed);
    if (delay <= 0) {
        [self runUpdateCheck:NO];
        return;
    }

    __weak GuardApp *weakSelf = self;
    self.updateCheckTimer = [NSTimer timerWithTimeInterval:delay repeats:NO block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf runUpdateCheck:NO];
    }];
    self.updateCheckTimer.tolerance = 60;
    [NSRunLoop.mainRunLoop addTimer:self.updateCheckTimer forMode:NSRunLoopCommonModes];
}

- (void)checkForUpdates {
    [self runUpdateCheck:YES];
}

- (void)runUpdateCheck:(BOOL)manual {
    if (manual) self.updateResultRequested = YES;
    if (self.checkingForUpdate) {
        if (manual) [self refreshSettings];
        return;
    }

    self.checkingForUpdate = YES;
    if (manual) [self refreshSettings];
    [NSUserDefaults.standardUserDefaults setObject:NSDate.date forKey:LastUpdateCheckKey];
    [self scheduleUpdateCheck];
    __weak GuardApp *weakSelf = self;
    CheckLatestRelease(^(NSString *tag) { [weakSelf finishUpdateCheck:tag]; });
}

- (void)finishUpdateCheck:(NSString *)tag {
    NSString *previous = AvailableUpdateTag();
    if (tag) [NSUserDefaults.standardUserDefaults setObject:tag forKey:LatestReleaseTagKey];
    NSString *available = AvailableUpdateTag();
    BOOL showResult = self.updateResultRequested;
    self.checkingForUpdate = NO;
    self.updateResultRequested = NO;
    [self updateAvailableReleaseIndicator];
    if (showResult) {
        [self refreshSettings];
        [self showUpdateCheckResult:tag ? available : nil succeeded:tag != nil];
    } else if (available && ![previous isEqualToString:available]) {
        [self announceUpdate:available];
    }
}

- (void)showUpdateCheckResult:(NSString *)tag succeeded:(BOOL)succeeded {
    if (!self.settingsWindow.visible) return;
    NSAlert *alert = [[NSAlert alloc] init];
    if (!succeeded) {
        alert.messageText = L(@"Не удалось проверить обновления");
        alert.informativeText = L(@"Проверьте подключение к интернету и попробуйте ещё раз.");
    } else if (tag) {
        alert.messageText = [NSString stringWithFormat:L(@"Доступна версия %@"), ReleaseVersion(tag)];
        alert.informativeText = L(@"Скачайте DMG или ZIP со страницы релиза GitHub.");
    } else {
        alert.messageText = L(@"Обновлений нет");
        alert.informativeText = [NSString stringWithFormat:L(@"Установлена версия %@."), CurrentAppVersion()];
    }
    [alert addButtonWithTitle:tag ? L(@"Открыть страницу релиза") : @"OK"];
    if (tag) [alert addButtonWithTitle:L(@"Позже")];
    [alert beginSheetModalForWindow:self.settingsWindow completionHandler:^(NSModalResponse response) {
        if (tag && response == NSAlertFirstButtonReturn) {
            [NSWorkspace.sharedWorkspace openURL:ReleaseURL(tag)];
        }
    }];
}

- (void)announceUpdate:(NSString *)tag {
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        if (settings.authorizationStatus != UNAuthorizationStatusAuthorized &&
            settings.authorizationStatus != UNAuthorizationStatusProvisional) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![AvailableUpdateTag() isEqualToString:tag]) return;
            UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
            content.title = L(@"Доступно обновление Route Shield");
            content.body = [NSString stringWithFormat:L(@"Доступна версия %@"), ReleaseVersion(tag)];
            content.userInfo = @{UpdateNotificationTagKey: tag};
            NSString *identifier = [@"route-shield-update-" stringByAppendingString:tag];
            UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:nil];
            [center addNotificationRequest:request withCompletionHandler:nil];
        });
    }];
}

- (void)changeConnectionField:(NSButton *)sender {
    [InterfacePreferences() setBool:sender.state == NSControlStateValueOn forKey:sender.identifier];
    if (self.prompt) [self refreshIPs];
}

- (void)changeNotificationDetails:(NSPopUpButton *)sender {
    [NSUserDefaults.standardUserDefaults setInteger:sender.indexOfSelectedItem forKey:NotificationDetailsKey];
}

- (void)changeLanguage:(NSPopUpButton *)sender {
    [InterfacePreferences() setObject:sender.indexOfSelectedItem == 1 ? @"en" : @"ru" forKey:LanguageKey];
    self.lastIPEvent = nil;
    [self.addPanel close];
    self.addPanel = nil;
    self.dropBox = nil;
    self.dropStatus = nil;
    if (self.welcomeWindow) [self showWelcome];
    [self refreshSettings];
    [self updateAvailableReleaseIndicator];
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
    [self.updateCheckTimer invalidate];
}

- (void)updateIPMonitoring {
    NSUserDefaults *settings = NSUserDefaults.standardUserDefaults;
    if (![settings boolForKey:NotifyIPChangesKey] && ![settings boolForKey:ForceCloseOnIPChangeKey]) {
        [self.ipMonitor stop];
        self.ipMonitor = nil;
        self.lastIPEvent = nil;
    } else if (!self.ipMonitor) {
        __weak GuardApp *weakSelf = self;
        self.ipMonitor = [[IPMonitor alloc] initWithHandler:^(NSString *ipv4, NSString *ipv6) {
            [weakSelf handleIPChangeWithIPv4:ipv4 ipv6:ipv6];
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

- (void)closeTrackedAppsWithCompletion:(void (^)(NSArray<NSString *> *))completion {
    NSString *problem = nil;
    NSUInteger running = 0;
    NSMutableArray<NSRunningApplication *> *pending = [NSMutableArray array];
    NSMutableDictionary<NSNumber *, NSString *> *names = [NSMutableDictionary dictionary];
    if (!self.closingPIDs) self.closingPIDs = [NSMutableSet set];
    for (NSString *identifier in ReadApps(&problem)) {
        for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:identifier]) {
            NSNumber *pid = @(app.processIdentifier);
            if (app.terminated || [self.closingPIDs containsObject:pid]) continue;
            running++;
            NSString *name = app.localizedName ?: identifier;
            if (![app forceTerminate]) continue;
            [self.closingPIDs addObject:pid];
            [pending addObject:app];
            names[pid] = name;
        }
    }
    self.lastIPEvent = problem ? [self.lastIPEvent stringByAppendingString:L(@" · ошибка в .env")] :
        [self.lastIPEvent stringByAppendingFormat:L(@" · запросов на закрытие %lu из %lu"),
            (unsigned long)pending.count, (unsigned long)running];
    if (pending.count == 0) {
        completion(@[]);
        return;
    }

    NSMutableOrderedSet<NSString *> *closed = [NSMutableOrderedSet orderedSet];
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 5;
    NSTimer *confirmation = [NSTimer timerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *timer) {
        BOOL expired = NSProcessInfo.processInfo.systemUptime >= deadline;
        for (NSRunningApplication *app in [pending copy]) {
            BOOL terminated = app.terminated;
            if (!terminated && !expired) continue;
            NSNumber *pid = @(app.processIdentifier);
            if (terminated) [closed addObject:names[pid]];
            [self.closingPIDs removeObject:pid];
            [pending removeObjectIdenticalTo:app];
        }
        if (pending.count) return;
        [timer invalidate];
        completion([closed.array sortedArrayUsingSelector:@selector(localizedStandardCompare:)]);
    }];
    [NSRunLoop.mainRunLoop addTimer:confirmation forMode:NSRunLoopCommonModes];
}

- (void)handleIPChangeWithIPv4:(NSString *)ipv4 ipv6:(NSString *)ipv6 {
    NSUserDefaults *settings = NSUserDefaults.standardUserDefaults;
    NSString *time = [NSDateFormatter localizedStringFromDate:NSDate.date
        dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle];
    self.lastIPEvent = [L(@"Смена IP · ") stringByAppendingString:time];
    BOOL notify = [settings boolForKey:NotifyIPChangesKey];
    dispatch_group_t event = dispatch_group_create();
    __block NSArray<NSString *> *closed = nil;
    if (notify) {
        NotificationDetails details = (NotificationDetails)[settings integerForKey:NotificationDetailsKey];
        dispatch_group_enter(event);
        CheckNotificationBody(details, ipv4, ipv6, ^(NSString *body) {
            if (![settings boolForKey:NotifyIPChangesKey]) {
                dispatch_group_leave(event);
                return;
            }
            [self postIPNotification:L(@"Внешний IP изменился")
                body:body completion:^(NSError *error) {
                    (void)error;
                    dispatch_group_leave(event);
                }];
        });
    }
    if ([settings boolForKey:ForceCloseOnIPChangeKey]) {
        dispatch_group_enter(event);
        [self closeTrackedAppsWithCompletion:^(NSArray<NSString *> *names) {
            closed = names;
            dispatch_group_leave(event);
        }];
    }
    if (notify) {
        dispatch_group_notify(event, dispatch_get_main_queue(), ^{
            if (closed.count && [settings boolForKey:NotifyIPChangesKey]) {
                [self postIPNotification:L(@"Приложения закрыты после смены IP")
                    body:[closed componentsJoinedByString:@"\n"] completion:nil];
            }
        });
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
    NSUserDefaults *settings = NSUserDefaults.standardUserDefaults;
    if (self.testingNotification || ![settings boolForKey:NotifyIPChangesKey]) return;
    NotificationDetails details = (NotificationDetails)[settings integerForKey:NotificationDetailsKey];
    self.testingNotification = YES;
    [self refreshSettings];
    CheckIPs(^(NSString *ipv4, NSString *ipv6) {
        NSString *address4 = IsIPAddress(ipv4, AF_INET) ? ipv4 : nil;
        NSString *address6 = IsIPAddress(ipv6, AF_INET6) ? ipv6 : nil;
        CheckNotificationBody(details, address4, address6, ^(NSString *body) {
            self.testingNotification = NO;
            [self refreshSettings];
            if (![settings boolForKey:NotifyIPChangesKey]) return;
            [self postIPNotification:[GuardName stringByAppendingString:L(@" · проверка")]
                body:body completion:^(NSError *error) {
                    if (!error) return;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        ShowMessage(L(@"Не удалось отправить уведомление"), error.localizedDescription);
                    });
                }];
        });
    });
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    (void)center;
    (void)notification;
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler {
    (void)center;
    NSURL *url = ReleaseURL(response.notification.request.content.userInfo[UpdateNotificationTagKey]);
    if (url && [response.actionIdentifier isEqualToString:UNNotificationDefaultActionIdentifier]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSWorkspace.sharedWorkspace openURL:url];
            completionHandler();
        });
    } else {
        completionHandler();
    }
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
    NSError *error = nil;
    if (!PrepareConfigForEditing(url, &error)) {
        ShowMessage(L(@"Не удалось открыть конфигурационный файл"), error.localizedDescription);
        return;
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
    self.prompt = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 510, 315)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    self.prompt.releasedWhenClosed = NO;
    self.prompt.title = GuardName;
    self.prompt.delegate = self;

    NSTextField *heading = [NSTextField wrappingLabelWithString:
        [NSString stringWithFormat:L(@"Открыть «%@»?"), AppName(url)]];
    heading.font = [NSFont boldSystemFontOfSize:19];
    self.promptHelp = [NSTextField wrappingLabelWithString:
        L(@"Сверьте внешние адреса с адресами VPN перед запуском.")];
    self.promptHelp.preferredMaxLayoutWidth = 462;
    self.ipv4 = [NSTextField labelWithString:@""];
    self.ipv6 = [NSTextField labelWithString:@""];
    self.country = [NSTextField wrappingLabelWithString:@""];
    self.country.preferredMaxLayoutWidth = 462;
    self.country.selectable = YES;
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

    NSStackView *stack = [NSStackView stackViewWithViews:
        @[heading, self.promptHelp, self.ipv4, self.ipv6, self.country, buttons]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    [stack setCustomSpacing:20 afterView:self.country];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    NSView *view = self.prompt.contentView;
    [view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-24],
        [stack.topAnchor constraintEqualToAnchor:view.topAnchor constant:22],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:view.bottomAnchor constant:-22],
        [heading.widthAnchor constraintLessThanOrEqualToAnchor:stack.widthAnchor]
    ]];

    [self refreshIPs];
    [self.prompt center];
    [NSApp activateIgnoringOtherApps:YES];
    [self.prompt makeKeyAndOrderFront:nil];
    [self.prompt makeFirstResponder:cancel];
}

- (void)refreshIPs {
    NSWindow *prompt = self.prompt;
    NSUInteger revision = ++self.promptCheckRevision;
    self.ipv4.hidden = !ShowsConnectionField(ShowIPv4Key);
    self.ipv6.hidden = !ShowsConnectionField(ShowIPv6Key);
    self.country.hidden = !ShowsConnectionField(ShowCountryKey);
    BOOL showConnection = !self.ipv4.hidden || !self.ipv6.hidden || !self.country.hidden;
    self.promptHelp.hidden = !showConnection;
    self.refreshButton.hidden = !showConnection;
    self.openButton.enabled = !showConnection;
    if (!showConnection) return;

    self.ipv4.stringValue = L(@"IPv4   Проверяю…");
    self.ipv6.stringValue = L(@"IPv6   Проверяю…");
    self.country.stringValue = ConnectionCountryBlock(L(@"Определяю…"), L(@"Определяю…"));
    self.refreshButton.enabled = NO;
    CheckIPs(^(NSString *ipv4, NSString *ipv6) {
        if (self.prompt != prompt || self.promptCheckRevision != revision) return;
        self.ipv4.stringValue = [@"IPv4   " stringByAppendingString:ipv4];
        self.ipv6.stringValue = [@"IPv6   " stringByAppendingString:ipv6];
        self.refreshButton.enabled = YES;
        self.openButton.enabled = YES;
        if (!self.country.hidden) {
            CheckCountries(ipv4, ipv6, ^(NSString *code4, NSString *code6) {
                if (self.prompt == prompt && self.promptCheckRevision == revision) {
                    self.country.stringValue = ConnectionCountryBlock(CountryName(code4), CountryName(code6));
                }
            });
        }
    });
}

- (void)cancelOpen {
    [self.prompt close];
}

- (void)windowWillClose:(NSNotification *)notification {
    if (notification.object == self.welcomeWindow) {
        self.welcomeWindow = nil;
        [self quit];
        return;
    }
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
        __attribute__((objc_precise_lifetime)) NSFileHandle *mainLock = nil;
        if (![NSBundle.mainBundle objectForInfoDictionaryKey:TargetBundleIDKey]) {
            int failure = 0;
            mainLock = AcquireMainInstanceLock(&failure);
            if (!mainLock) {
                if (failure == EWOULDBLOCK) return 0;
                (void)NSApplication.sharedApplication;
                ShowMessage(L(@"Не удалось запустить Route Shield"),
                    [NSError errorWithDomain:NSPOSIXErrorDomain code:failure userInfo:nil].localizedDescription);
                return 1;
            }
        }
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        __attribute__((objc_precise_lifetime)) GuardApp *delegate = [[GuardApp alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
