#import <Cordova/CDV.h>
#import <Cordova/NSDictionary+CordovaPreferences.h>

#import "MigrateStorage.h"
#import "FMDB.h"

// Uncomment this to enable debug mode
// #define DEBUG_MODE = 1;

#ifdef DEBUG_MODE
#   define logDebug(...) NSLog(__VA_ARGS__)
#else
#   define logDebug(...)
#endif

#define TAG @"\nMigrateStorage"

// TODO Make these paths simpler to deal with? We could embded the full paths in these strings if we want to...
#define ORIG_DIRPATH @"WebKit/LocalStorage/"
#define TARGET_DIRPATH @"WebKit/WebsiteData/"

#define ORIG_WEBSQL_DIRPATH @"WebKit/LocalStorage/"
#define TARGET_WEBSQL_DIRPATH @"WebKit/WebsiteData/WebSQL/"

#define ORIG_LS_DIRPATH @"WebKit/LocalStorage/"
#define ORIG_LS_CACHE_DIRPATH @"Caches/"
#define TARGET_LS_DIRPATH @"WebKit/WebsiteData/LocalStorage/"
#define TARGET_LS_DIRPATH_BUNDLE @"WebKit/%@/WebsiteData/LocalStorage/"

#define ORIG_IDB_DIRPATH @"WebKit/LocalStorage/___IndexedDB/"
#define TARGET_IDB_DIRPATH @"WebKit/WebsiteData/IndexedDB/"

#define UI_WEBVIEW_PROTOCOL_DIR @"file__0"

#define CDV_SETTING_PORT_NUMBER @"WKPort"
#define CDV_SETTING_HOSTNAME @"Hostname"
#define DEFAULT_PORT_NUMBER @"8080"
#define DEFAULT_HOSTNAME @"http_localhost_"

@interface MigrateStorage ()
@property (nonatomic, assign) NSString *portNumber;
@property (nonatomic, assign) NSString *hostname;
@property (nonatomic, assign) NSString *bundleId;
@end

@implementation MigrateStorage

- (NSString*)getWkWebviewProtocolDir
{
    return [self.hostname stringByAppendingString:self.portNumber];
}

- (BOOL)moveFile:(NSString*)src to:(NSString*)dest
{
    logDebug(@"%@ moveFile()", TAG);
    logDebug(@"%@ moveFile() src: %@", TAG, src);
    logDebug(@"%@ moveFile() dest: %@", TAG, dest);
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    // Bail out if source file does not exist
    if (![fileManager fileExistsAtPath:src]) {
        logDebug(@"%@ source file does not exist: %@", TAG, src);
        return NO;
    }
    
    // Bail out if dest file exists
    if ([fileManager fileExistsAtPath:dest]) {
        logDebug(@"%@ destination file already exists: %@", TAG, dest);
        return NO;
    }
    
    // create path to destination
    if (![fileManager createDirectoryAtPath:[dest stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil]) {
        return NO;
    }
    
    BOOL res = [fileManager moveItemAtPath:src toPath:dest error:nil];
    
    logDebug(@"%@ end moveFile(src: %@ , dest: %@ ); success: %@", TAG, src, dest, res ? @"YES" : @"NO");
    
    return res;
}

- (BOOL)changeProtocolEntriesinReferenceDB:(NSString *)path from:(NSString *)srcProtocolDir to:(NSString *)targetProtocolDir
{
    logDebug(@"%@ changeProtocolEntriesinReferenceDB()", TAG);
    
    FMDatabase *db = [FMDatabase databaseWithPath:path];
    
    // Can't do anything, just let this fail and let WkWebview create its own DB! :(
    if(![db open])
    {
        
        logDebug(@"%@ dbOpen error: %@ ; exiting..", TAG, [db lastErrorMessage]);
        return NO;
    }
    
    BOOL success = [db executeUpdate:@"UPDATE Databases SET origin = ? WHERE origin = ?", targetProtocolDir, srcProtocolDir];
    if (!success)
    {
        logDebug(@"%@ executeUpdate error for `Databases` table update = %@", TAG, [db lastErrorMessage]);
    }
    
    
    success = [db executeUpdate:@"UPDATE Origins SET origin = ? WHERE origin = ?", targetProtocolDir, srcProtocolDir];
    if (!success)
    {
        logDebug(@"%@ executeUpdate error for `Origins` table update = %@", TAG, [db lastErrorMessage]);
    }
    
    [db close];
    
    logDebug(@"%@ end changeProtocolEntriesinReferenceDB()", TAG);
    
    return success;
}

- (BOOL)migrateWebSQL
{
    logDebug(@"%@ migrateWebSQL()", TAG);
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *appLibraryDir = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    
    NSString *uiWebViewRootPath = [appLibraryDir stringByAppendingPathComponent:ORIG_WEBSQL_DIRPATH];
    NSString *wkWebViewRootPath = [appLibraryDir stringByAppendingPathComponent:TARGET_WEBSQL_DIRPATH];
    
    //
    // Copy {appLibrary}/WebKit/LocalStorage/Databases.db to {appLibrary}/WebKit/WebsiteData/WebSQL/Databases.db
    //
    
    // "Databases.db" contains an "index" of all the WebSQL databases that the app is using
    NSString *uiWebViewRefDBPath = [uiWebViewRootPath stringByAppendingPathComponent:@"Databases.db"];
    NSString *wkWebViewRefDBPath = [wkWebViewRootPath stringByAppendingPathComponent:@"Databases.db"];
    
    // Exit away if the source file does not exist
    if(![fileManager fileExistsAtPath:uiWebViewRefDBPath])
    {
        logDebug(@"%@ source path not found: %@ ; exiting..", TAG, uiWebViewRefDBPath);
        return NO;
    }
    
    // TODO Check if target file exists or not?
    
    NSString *wkWebviewProtocolDir = [self getWkWebviewProtocolDir];
    
    // Before copying, open Databases.db and change the reference from `file__0` to `localhost_http_{portNumber}`, so WkWebView will understand this
    if (![self changeProtocolEntriesinReferenceDB:uiWebViewRefDBPath from:UI_WEBVIEW_PROTOCOL_DIR to:wkWebviewProtocolDir])
    {
        logDebug(@"%@ could not perform needed update; exiting..", TAG);
        return NO;
    }
    
    
    BOOL success1 = [self moveFile:uiWebViewRefDBPath to:wkWebViewRefDBPath];
    BOOL success2 = [self moveFile:[uiWebViewRefDBPath stringByAppendingString:@"-shm"] to:[wkWebViewRefDBPath stringByAppendingString:@"-shm"]];
    BOOL success3 = [self moveFile:[uiWebViewRefDBPath stringByAppendingString:@"-wal"] to:[wkWebViewRefDBPath stringByAppendingString:@"-wal"]];
    
    if(!success1 || !success2 || !success3)
    {
        logDebug(@"%@ could not move Databases.db; exiting..", TAG);
        return NO;
    }
    
    //
    // Move
    //  {appLibrary}/WebKit/LocalStorage/file__0/*
    // to
    //  {appLibrary}/WebKit/WebsiteData/WebSQL/http_localhost_{portNumber}/*
    //
    
    // This dir contains all the WebSQL Databases that the cordova app
    NSString *uiWebViewDBFileDir = [uiWebViewRootPath stringByAppendingPathComponent:UI_WEBVIEW_PROTOCOL_DIR];
    
    
    // The target dir that should contain all the databases from `uiWebViewDBFileDir`
    NSString *wkWebViewDBFileDir = [wkWebViewRootPath stringByAppendingPathComponent:wkWebviewProtocolDir];
    
    NSArray *fileList = [fileManager contentsOfDirectoryAtPath:uiWebViewDBFileDir error:nil];
    
    // Exit if no databases were found
    // This should never happen, because if no databases were found, we would not have found the `Databases.db` file!
    if ([fileList count] == 0) return NO;
    
    BOOL success;
    
    for (NSString *fileName in fileList) {
        NSString *originalFilePath = [uiWebViewDBFileDir stringByAppendingPathComponent:fileName];
        NSString *targetFilePath = [wkWebViewDBFileDir stringByAppendingPathComponent:fileName];
        
        success = [self moveFile:originalFilePath to:targetFilePath];
    }
    
    if(!success)
    {
        logDebug(@"%@ could not move one of the databases in %@ ; exiting..", TAG, uiWebViewDBFileDir);
        return NO;
    }
    
    logDebug(@"%@ end migrateWebSQL() with success: %@", TAG, success ? @"YES" : @"NO");
    return YES;
}

- (BOOL) migrateLocalStorage
{
    logDebug(@"%@ migrateLocalStorage()", TAG);
    
    BOOL success;
    NSString *wkWebviewProtocolDir = [self getWkWebviewProtocolDir];
    
    NSString *appLibraryFolder = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    
    NSString *originalLSFileName = [UI_WEBVIEW_PROTOCOL_DIR stringByAppendingString:@".localstorage"];
    NSString *targetLSFileName = [wkWebviewProtocolDir stringByAppendingString:@".localstorage"];
    
    NSString *originalLSFilePath = [[appLibraryFolder stringByAppendingPathComponent:ORIG_LS_DIRPATH] stringByAppendingPathComponent:originalLSFileName];
    NSString *originalLSCachePath = [[appLibraryFolder stringByAppendingPathComponent:ORIG_LS_CACHE_DIRPATH] stringByAppendingPathComponent:originalLSFileName];
    

    NSString *targetPath = [appLibraryFolder stringByAppendingPathComponent:TARGET_LS_DIRPATH];
    NSString *targetBundlePath = [appLibraryFolder stringByAppendingPathComponent:[NSString stringWithFormat: TARGET_LS_DIRPATH_BUNDLE, self.bundleId]];
    NSString *targetLSStoragePath = [[appLibraryFolder stringByAppendingPathComponent:TARGET_LS_DIRPATH] stringByAppendingPathComponent:targetLSFileName];
    NSString *targetLSStorageBundlePath = [[appLibraryFolder stringByAppendingPathComponent:[NSString stringWithFormat: TARGET_LS_DIRPATH_BUNDLE, self.bundleId]] stringByAppendingPathComponent:targetLSFileName];
    
    // Use the file in the cache if not found in original path
    NSString *original = [[NSFileManager defaultManager] fileExistsAtPath:originalLSFilePath] ? originalLSFilePath : originalLSCachePath;
    NSString *target = [[NSFileManager defaultManager] fileExistsAtPath:targetPath] && ![[NSFileManager defaultManager] fileExistsAtPath:targetBundlePath] ? targetLSStoragePath : targetLSStorageBundlePath;
    BOOL recoveryMigrationError = [[NSFileManager defaultManager] fileExistsAtPath:targetLSStorageBundlePath] && [[NSFileManager defaultManager] fileExistsAtPath:targetLSStoragePath];
    
    logDebug(@"%@ LS original %@", TAG, original);
    logDebug(@"%@ LS target %@", TAG, target);
    
    // Only copy data if no existing localstorage data exists yet for wkwebview
    if (![[NSFileManager defaultManager] fileExistsAtPath:target]) {
        logDebug(@"%@ No existing localstorage data found for WKWebView. Migrating data from UIWebView", TAG);
        BOOL success1 = [self moveFile:original to:target];
        BOOL success2 = [self moveFile:[original stringByAppendingString:@"-shm"] to:[target stringByAppendingString:@"-shm"]];
        BOOL success3 = [self moveFile:[original stringByAppendingString:@"-wal"] to:[target stringByAppendingString:@"-wal"]];
        logDebug(@"%@ copy status %d %d %d", TAG, success1, success2, success3);
        success = success1 && success2 && success3;
    }
    else {
        if (recoveryMigrationError) {
            logDebug(@"%@ Recovery action existing localstorage data found for WKWebView in bundle. Migrating data to non bundle WKWebView", TAG);
            BOOL success1 = [self moveFile:targetLSStoragePath to:[targetLSStoragePath stringByAppendingString:@"-bad"]];
            BOOL success2 = [self moveFile:[targetLSStoragePath stringByAppendingString:@"-shm"] to:[targetLSStoragePath stringByAppendingString:@"-shm-bad"]];
            BOOL success3 = [self moveFile:[targetLSStoragePath stringByAppendingString:@"-wal"] to:[targetLSStoragePath stringByAppendingString:@"-wal-bad"]];
            
            BOOL success4 = [self moveFile:targetLSStorageBundlePath to:targetLSStoragePath];
            BOOL success5 = [self moveFile:[targetLSStorageBundlePath stringByAppendingString:@"-shm"] to:[targetLSStoragePath stringByAppendingString:@"-shm"]];
            BOOL success6 = [self moveFile:[targetLSStorageBundlePath stringByAppendingString:@"-wal"] to:[targetLSStoragePath stringByAppendingString:@"-wal"]];
            logDebug(@"%@ copy status %d %d %d %d %d %d", TAG, success1, success2, success3, success4, success5, success6);
            success = success1 && success2 && success3 && success4 && success5 && success6;
        } else {
            logDebug(@"%@ found LS data. not migrating", TAG);
            success = NO;
        }
    }
    
    logDebug(@"%@ end migrateLocalStorage() with success: %@", TAG, success ? @"YES": @"NO");
    
    return success;
}

- (BOOL) migrateIndexedDB
{
    logDebug(@"%@ migrateIndexedDB()", TAG);
    
    NSString *wkWebviewProtocolDir = [self getWkWebviewProtocolDir];
    
    NSString *appLibraryFolder = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    
    NSString *original = [[appLibraryFolder stringByAppendingPathComponent:ORIG_IDB_DIRPATH] stringByAppendingPathComponent:UI_WEBVIEW_PROTOCOL_DIR];
    NSString *target = [[appLibraryFolder stringByAppendingPathComponent:TARGET_IDB_DIRPATH] stringByAppendingPathComponent:wkWebviewProtocolDir];
    
    logDebug(@"%@ IDB original %@", TAG, original);
    logDebug(@"%@ IDB target %@", TAG, target);
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:target]) {
        logDebug(@"%@ No existing IDB data found for WKWebView. Migrating data from UIWebView", TAG);
        BOOL success = [self moveFile:original to:target];
        logDebug(@"%@ copy status %d", TAG, success);
        return success;
    }
    else {
        logDebug(@"%@ found IDB data. Not migrating", TAG);
        return NO;
    }
}


- (void)pluginInitialize
{
    logDebug(@"%@ pluginInitialize()", TAG);
    
    NSDictionary *cdvSettings = self.commandDelegate.settings;
    self.portNumber = [cdvSettings cordovaSettingForKey:CDV_SETTING_PORT_NUMBER];
    NSString *hostname = [cdvSettings cordovaSettingForKey:CDV_SETTING_HOSTNAME];
    NSBundle* bundle = [NSBundle mainBundle];
    self.bundleId = [bundle bundleIdentifier];
    
    if([self.portNumber length] == 0) {
        self.portNumber = DEFAULT_PORT_NUMBER;
    }
    
    if([hostname length] == 0) {
        hostname = DEFAULT_HOSTNAME;
    } else {
        hostname = [@"ionic_" stringByAppendingString:hostname];
        self.portNumber = @"_0";
    }
    self.hostname = hostname;
    
    // [self migrateWebSQL];
    [self migrateLocalStorage];
    // [self migrateIndexedDB];
    
    logDebug(@"%@ end pluginInitialize()", TAG);
}

@end


