package com.migrate.android;

import android.app.Activity;
import android.os.Build;
import android.content.Context;
import android.database.sqlite.SQLiteDatabase;
import android.util.Log;

import com.migrate.android.*;

import org.apache.cordova.CordovaInterface;
import org.apache.cordova.CordovaPlugin;

import org.apache.cordova.CordovaWebView;
import java.io.File;

/**
 * Main class that is instantiated by cordova
 * Acts as a "bridge" between the SDK and the cordova layer
 *
 * This plugin migrates WebSQL and localStorage from the old webview to the new webview
 *
 * TODO
 * - Test if we can we remove old file:// keys?
 * - Properly handle exceptions? We have a catch-all at the moment that is dealt with in the `initialize` function
 * - migrating IndexedDB (may not be possible because of leveldb complexities)
 */
public class MigrateStorage extends CordovaPlugin {
    // Switch this value to enable debug mode
    private static final boolean DEBUG_MODE = false;

    private static final String TAG = "com.migrate.android";
    private static final String FILE_PROTOCOL = "file://";
    private static final String WEBSQL_FILE_DIR_NAME = "file__0";
    private static final String DEFAULT_PORT_NUMBER = "0";
    private static final String CDV_SETTING_PORT_NUMBER = "WKPort";

    // Root dir for system webview data used by Android 4.4+
    private static String modernWebviewDir = "/app_webview";

    // Root dir for system webview data used by Android 4.3 and below
    private static String oldWebviewDir = "/app_database";

    // Directory name for local storage files used by Android 4.4+ and XWalk
    private static String modernLocalStorageDir = "/Local Storage";

    // Directory name for local storage files used by Android 4.3 and below
    private static String oldLocalStorageDir = "/localstorage";

    private String portNumber;
    private boolean isModernAndroid;
    private Activity activity;

    private String getWebviewPath(){
        if(isModernAndroid){
            return modernWebviewDir;
        }else{
            return oldWebviewDir;
        }
    }

    private String getWebviewLocalStoragePath(){
        if(isModernAndroid){
            return modernLocalStorageDir;
        }else{
            return oldLocalStorageDir;
        }
    }

    private void logDebug(String message) {
        if(DEBUG_MODE) Log.d(TAG, message);
    }

    private String getLocalHostProtocolDirName() {
        return "https_localhost_" + this.portNumber;
    }

    private String getLocalHostProtocol() {
        if (this.portNumber != "0") {
            return "https://localhost:" + this.portNumber;
        } else {
            return "https://localhost";
        }
    }

    private String getRootPath() {
        Context context = cordova.getActivity().getApplicationContext();
        return context.getFilesDir().getAbsolutePath().replaceAll("/files", "");
    }

    private String getWebViewRootPath() {
        return this.getRootPath() + this.getWebviewPath();
    }

    private String getLocalStorageRootPath() {
        File localStorage = new File(this.getWebViewRootPath() + this.getWebviewLocalStoragePath());
        File localStorageDefault = new File(this.getWebViewRootPath() + "/Default" + this.getWebviewLocalStoragePath());

        if(localStorage.exists()){
          return localStorage.getAbsolutePath();
        } else {
          return localStorageDefault.getAbsolutePath();
        }
    }

    private String getWebSQLDatabasesPath() {
        return this.getWebViewRootPath() + "/databases";
    }

    private String getWebSQLReferenceDbPath() {
        return this.getWebSQLDatabasesPath() + "/Databases.db";
    }

    /**
     * Migrate localStorage from `file://` to `https://localhost:{portNumber}`
     *
     * TODO Test if we can we remove old file:// keys?
     *
     * @throws Exception - Can throw LevelDBException
     */
    private void migrateLocalStorage() throws Exception {
        this.logDebug("migrateLocalStorage: Migrating localStorage..");

        boolean hasMigratedData = false;

        File fileLocalStorage = new File(this.getLocalStorageRootPath() + "/" + WEBSQL_FILE_DIR_NAME + ".localstorage");
        File fileLocalStorageJournal = new File(this.getLocalStorageRootPath() + "/" + WEBSQL_FILE_DIR_NAME + ".localstorage-journal");

        File ionicLocalStorage = new File(this.getLocalStorageRootPath() + "/" + this.getLocalHostProtocolDirName() + ".localstorage");
        File ionicLocalStorageJournal = new File(this.getLocalStorageRootPath() + "/" + this.getLocalHostProtocolDirName() + ".localstorage-journal");

        if (fileLocalStorage.exists()) {
            fileLocalStorage.renameTo(ionicLocalStorage);
            hasMigratedData = true;
        } else {
            this.logDebug("migrateLocalStorage: Migrating localStorage from leveldb..");

            String levelDbPath = this.getLocalStorageRootPath() + "/leveldb";
            this.logDebug("migrateLocalStorage: levelDbPath: " + levelDbPath);
    
            File levelDbDir = new File(levelDbPath);
            if(!levelDbDir.isDirectory() || !levelDbDir.exists()) {
                this.logDebug("migrateLocalStorage: '" + levelDbPath + "' is not a directory or was not found; Exiting");
                return;
            }
    
            LevelDB db = new LevelDB(levelDbPath);
    
            String localHostProtocol = this.getLocalHostProtocol();
    
            if(db.exists(Utils.stringToBytes("META:" + localHostProtocol))) {
                this.logDebug("migrateLocalStorage: Found 'META:" + localHostProtocol + "' key; Skipping migration");
                db.close();
                return;
            }
    
            // Yes, there is a typo here; `newInterator` 😔
            LevelIterator iterator = db.newInterator();
    
            // To update in bulk!
            WriteBatch batch = new WriteBatch();
    
    
            // 🔃 Loop through the keys and replace `file://` with `http://localhost:{portNumber}`
            logDebug("migrateLocalStorage: Starting replacements;");
            for(iterator.seekToFirst(); iterator.isValid(); iterator.next()) {
                String key = Utils.bytesToString(iterator.key());
                byte[] value = iterator.value();
    
                if (key.contains(FILE_PROTOCOL)) {
                    String newKey = key.replace(FILE_PROTOCOL, localHostProtocol);
    
                    logDebug("migrateLocalStorage: Changing key:" + key + " to '" + newKey + "'");
    
                    // Add new key to db
                    batch.putBytes(Utils.stringToBytes(newKey), value);
                    hasMigratedData = true;
                } else {
                    logDebug("migrateLocalStorage: Skipping key:" + key);
                }
            }
    
            // Commit batch to DB
            db.write(batch);
    
            iterator.close();
            db.close();
    
            this.logDebug("migrateLocalStorage: Successfully migrated localStorage..");            
        }

        if (fileLocalStorageJournal.exists()) {
            fileLocalStorageJournal.renameTo(ionicLocalStorageJournal);
            hasMigratedData = true;
        }

        if(hasMigratedData){
            Log.d(TAG, "restarting Cordova activity");
            activity.recreate();
        }

        this.logDebug("migrateLocalStorage: Successfully migrated localStorage..");
    }


    /**
     * Migrate WebSQL from using `file://` to `http://localhost:{portNumber}`
     *
     */
    private void migrateWebSQL() {
        this.logDebug("migrateWebSQL: Migrating WebSQL..");

        String databasesPath = this.getWebSQLDatabasesPath();
        String referenceDbPath = this.getWebSQLReferenceDbPath();
        String localHostDirName = this.getLocalHostProtocolDirName();

        if(!new File(referenceDbPath).exists()) {
            logDebug("migrateWebSQL: Databases.db was not found in path: '" + referenceDbPath + "'; Exiting..");
            return;
        }

        File originalWebSQLDir = new File(databasesPath + "/" + WEBSQL_FILE_DIR_NAME);
        File targetWebSQLDir = new File(databasesPath + "/" + localHostDirName);

        if(!originalWebSQLDir.exists()) {
            logDebug("migrateWebSQL: original DB does not exist at '" + originalWebSQLDir.getAbsolutePath() + "'; Exiting..");
            return;
        }

        if(targetWebSQLDir.exists()) {
            logDebug("migrateWebSQL: target DB already exists at '" + targetWebSQLDir.getAbsolutePath() + "'; Skipping..");
            return;
        }

        logDebug("migrateWebSQL: Databases.db path: '" + referenceDbPath + "';");

        SQLiteDatabase db = SQLiteDatabase.openDatabase(referenceDbPath, null, 0);

        // Update reference DB to point to `localhost:{portNumber}`
        db.execSQL("UPDATE Databases SET origin = ? WHERE origin = ?", new String[] { localHostDirName, WEBSQL_FILE_DIR_NAME });

        // rename `databases/file__0` dir to `databases/localhost_http_{portNumber}`
        boolean renamed = originalWebSQLDir.renameTo(targetWebSQLDir);

        if(!renamed) {
            logDebug("migrateWebSQL: Tried renaming '" + originalWebSQLDir.getAbsolutePath() + "' to '" + targetWebSQLDir.getAbsolutePath() + "' but failed; Exiting...");
            return;
        }

        db.close();

        this.logDebug("migrateWebSQL: Successfully migrated WebSQL..");
    }


    /**
     * Sets up the plugin interface
     *
     * @param cordova - cdvInterface that contains cordova goodies
     * @param webView - the webview that we're running
     */
    public void initialize(CordovaInterface cordova, CordovaWebView webView) {
        try {
            super.initialize(cordova, webView);

            activity = cordova.getActivity();
            this.isModernAndroid = Build.VERSION.SDK_INT >= 19;
            this.portNumber = this.preferences.getString(CDV_SETTING_PORT_NUMBER, "");
            if(this.portNumber.isEmpty() || this.portNumber == null) this.portNumber = DEFAULT_PORT_NUMBER;

            logDebug("Starting migration;");

            this.migrateLocalStorage();
            // this.migrateWebSQL();

            logDebug("Migration completed;");
        } catch (Exception ex) {
            logDebug("Migration filed due to error: " + ex.getMessage());
        }
    }
}
