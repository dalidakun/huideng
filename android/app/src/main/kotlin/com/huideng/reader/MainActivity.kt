package com.huideng.reader

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.AlarmClock
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.FileProvider
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "app_channel"
    private val FILE_PROVIDER_CHANNEL = "com.huideng.reader/file_provider"

    // 静态快捷方式携带的 action。冷启动由启动 Intent 解析，热启动由 onNewIntent 设置；
    // Flutter 侧通过 getShortcutAction 原子读取并清空，保证同一动作只被处理一次。
    private val ACTION_QUICK_CHECKIN = "com.huideng.reader.action.QUICK_CHECKIN"
    private val ACTION_CONTINUE_READING = "com.huideng.reader.action.CONTINUE_READING"
    private val ACTION_NEW_NOTE = "com.huideng.reader.action.NEW_NOTE"

    private var appChannel: MethodChannel? = null
    private var pendingShortcut: String? = null

    private fun shortcutFromIntent(intent: Intent?): String? =
        when (intent?.action) {
            ACTION_QUICK_CHECKIN -> "quick_checkin"
            ACTION_CONTINUE_READING -> "continue_reading"
            ACTION_NEW_NOTE -> "new_note"
            else -> null
        }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val action = shortcutFromIntent(intent) ?: return
        pendingShortcut = action
        // 热启动：Flutter 引擎已在运行，发信号让 Dart 侧立即拉取处理。
        appChannel?.invokeMethod("onShortcutAction", null)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 冷启动：从启动 Intent 解析快捷方式动作。
        pendingShortcut = shortcutFromIntent(intent)

        appChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        appChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "getShortcutAction" -> {
                    val action = pendingShortcut
                    pendingShortcut = null
                    result.success(action)
                }
                "minimizeApp" -> {
                    try {
                        // 使用更激进的方式最小化应用
                        // 先移动到后台，然后启动home来确保应用被正确后台化
                        moveTaskToBack(false)

                        // 延迟一下再启动home，确保任务已经移动到后台
                        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                            val homeIntent = Intent(Intent.ACTION_MAIN)
                            homeIntent.addCategory(Intent.CATEGORY_HOME)
                            homeIntent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            startActivity(homeIntent)
                        }, 100)

                        result.success(null)
                    } catch (e: Exception) {
                        result.error("MINIMIZE_FAILED", "Failed to minimize app", e.message)
                    }
                }
                "restartApp" -> {
                    try {
                        // 完全重启：以全新任务栈（CLEAR_TASK）冷启动 launcher Activity。
                        // 此时 App 仍在前台，系统必定放行启动；旧任务被清空、
                        // 旧 Flutter 引擎随旧 Activity 销毁，新引擎重新执行 main()，
                        // 外观等偏好全部从磁盘重读，换肤完全生效。
                        // 注意：不能杀进程——「杀进程 + 定时拉起」会被部分机型的
                        // 自启动/后台启动限制吞掉（表现为退出后不重启），且可能
                        // 恢复出安装页等旧任务 Intent。
                        val launch = packageManager.getLaunchIntentForPackage(packageName)
                        if (launch == null) {
                            result.error("NO_LAUNCH_INTENT", "No launch intent", null)
                            return@setMethodCallHandler
                        }
                        launch.addFlags(
                            Intent.FLAG_ACTIVITY_NEW_TASK or
                                Intent.FLAG_ACTIVITY_CLEAR_TASK
                        )
                        if (launch.component == null) {
                            // 兜底显式指向主 Activity，避免隐式解析到其他入口。
                            launch.setClassName(packageName, "$packageName.MainActivity")
                        }
                        result.success(null)
                        startActivity(launch)
                    } catch (e: Exception) {
                        result.error("RESTART_FAILED", "Failed to restart app", e.message)
                    }
                }
                "getLastUpdateTime" -> {
                    try {
                        val info = packageManager.getPackageInfo(packageName, 0)
                        result.success(info.lastUpdateTime)
                    } catch (e: Exception) {
                        result.error("GET_UPDATE_TIME_FAILED", "Failed to get lastUpdateTime", e.message)
                    }
                }
                "canInstallApk" -> {
                    // Android 8.0+ 需要用户逐应用开启「安装未知应用」；提前问一句，
                    // 好在拉起安装器之前就把用户引导到设置页，而不是报一个看不懂的错。
                    try {
                        val can = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            packageManager.canRequestPackageInstalls()
                        } else {
                            true
                        }
                        result.success(can)
                    } catch (e: Exception) {
                        result.success(true)
                    }
                }
                "openInstallSettings" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                                .setData(Uri.parse("package:$packageName"))
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        // 部分定制系统没有这个设置页：退而打开本应用详情页。
                        try {
                            val fallback = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                                .setData(Uri.parse("package:$packageName"))
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(fallback)
                            result.success(true)
                        } catch (e2: Exception) {
                            result.error("SETTINGS_FAILED", "Failed to open settings", e2.message)
                        }
                    }
                }
                "installApk" -> {
                    // App 内下载完成后调起系统安装器。APK 位于应用外部文件目录，
                    // 通过已声明的 FileProvider 生成 content:// URI 授予安装器读取权限。
                    try {
                        NotificationManagerCompat.from(this)
                            .cancel(DownloadCompleteReceiver.NOTIFICATION_ID)
                        val filePath = call.argument<String>("filePath")
                        if (filePath.isNullOrEmpty()) {
                            result.error("INVALID_PATH", "File path is null", null)
                            return@setMethodCallHandler
                        }
                        val file = File(filePath)
                        if (!file.exists()) {
                            result.error("FILE_NOT_FOUND", "File does not exist", null)
                            return@setMethodCallHandler
                        }
                        val uri = FileProvider.getUriForFile(
                            this,
                            "${packageName}.fileprovider",
                            file
                        )
                        val install = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivity(install)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("INSTALL_FAILED", "Failed to open installer", e.message)
                    }
                }
                "startApkDownload" -> {
                    // 用系统 DownloadManager 下载：即使退出 App 也会在后台继续，
                    // 并在通知栏显示进度；完成后由 DownloadCompleteReceiver 提示安装。
                    try {
                        val url = call.argument<String>("url")
                        val version = call.argument<String>("version") ?: ""
                        val sha256 = call.argument<String>("sha256") ?: ""
                        val notifyCompleted =
                            call.argument<Boolean>("notifyCompleted") ?: false
                        if (url.isNullOrEmpty()) {
                            result.error("INVALID_URL", "Download url is empty", null)
                            return@setMethodCallHandler
                        }
                        val fileName = if (version.isNotEmpty()) {
                            "huideng_v$version.apk"
                        } else {
                            "huideng_update.apk"
                        }
                        val manager =
                            getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
                        val dir = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
                            ?: filesDir
                        // 覆盖同名旧包，并清理更早版本下载的安装包。
                        dir.listFiles()?.forEach { old ->
                            if (old.isFile && old.name.startsWith("huideng_") &&
                                old.name.endsWith(".apk") && old.name != fileName
                            ) {
                                old.delete()
                            }
                        }
                        val target = File(dir, fileName)
                        if (target.exists()) target.delete()
                        val request = DownloadManager.Request(Uri.parse(url)).apply {
                            setTitle("燃灯新版本${if (version.isNotEmpty()) " v$version" else ""}")
                            setDescription("正在下载安装包…")
                            setMimeType("application/vnd.android.package-archive")
                            setNotificationVisibility(
                                if (notifyCompleted) {
                                    DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED
                                } else {
                                    DownloadManager.Request.VISIBILITY_VISIBLE
                                }
                            )
                            setDestinationInExternalFilesDir(
                                this@MainActivity,
                                Environment.DIRECTORY_DOWNLOADS,
                                fileName
                            )
                            setAllowedOverMetered(true)
                            setAllowedOverRoaming(false)
                        }
                        val id = manager.enqueue(request)
                        val path = target.absolutePath
                        // 记录文件名/校验值，供轮询与完成广播读取。
                        getSharedPreferences(DownloadCompleteReceiver.PREFS, Context.MODE_PRIVATE)
                            .edit()
                            .putString("path_$id", path)
                            .putString("version_$id", version)
                            .putString("sha_$id", sha256)
                            .apply()
                        result.success(id)
                    } catch (e: Exception) {
                        result.error("DOWNLOAD_FAILED", "Failed to start download", e.message)
                    }
                }
                "queryApkDownload" -> {
                    try {
                        val id = call.argument<Number>("downloadId")?.toLong() ?: -1L
                        val manager =
                            getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
                        val cursor = manager.query(
                            DownloadManager.Query().setFilterById(id)
                        )
                        if (cursor == null || !cursor.moveToFirst()) {
                            cursor?.close()
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        val status = cursor.getInt(
                            cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)
                        )
                        val downloaded = cursor.getLong(
                            cursor.getColumnIndexOrThrow(
                                DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR
                            )
                        )
                        val total = cursor.getLong(
                            cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)
                        )
                        val reason = cursor.getInt(
                            cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON)
                        )
                        cursor.close()
                        val prefs = getSharedPreferences(
                            DownloadCompleteReceiver.PREFS,
                            Context.MODE_PRIVATE
                        )
                        result.success(
                            mapOf(
                                "status" to status,
                                "downloaded" to downloaded,
                                "total" to total,
                                "reason" to reason,
                                "path" to (prefs.getString("path_$id", "") ?: ""),
                                "version" to (prefs.getString("version_$id", "") ?: ""),
                                "sha256" to (prefs.getString("sha_$id", "") ?: "")
                            )
                        )
                    } catch (e: Exception) {
                        result.error("QUERY_FAILED", "Failed to query download", e.message)
                    }
                }
                "cancelApkDownload" -> {
                    try {
                        val id = call.argument<Number>("downloadId")?.toLong() ?: -1L
                        val manager =
                            getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
                        manager.remove(id)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("CANCEL_FAILED", "Failed to cancel download", e.message)
                    }
                }
                "setSystemAlarm" -> {
                    try {
                        val hour = call.argument<Int>("hour") ?: 21
                        val minute = call.argument<Int>("minute") ?: 0
                        val message = call.argument<String>("message") ?: ""
                        val skipUI = call.argument<Boolean>("skipUI") ?: false

                        // 1. 优先 ACTION_SET_ALARM（打开新建闹钟界面，时间预填）
                        val setAlarm = Intent(AlarmClock.ACTION_SET_ALARM)
                        setAlarm.putExtra(AlarmClock.EXTRA_HOUR, hour)
                        setAlarm.putExtra(AlarmClock.EXTRA_MINUTES, minute)
                        setAlarm.putExtra(AlarmClock.EXTRA_MESSAGE, message)
                        if (skipUI) {
                            setAlarm.putExtra(AlarmClock.EXTRA_SKIP_UI, true)
                        }
                        setAlarm.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        try {
                            startActivity(setAlarm)
                            result.success("opened_set_alarm")
                            return@setMethodCallHandler
                        } catch (_: Exception) {
                        }

                        // 2. 退而打开系统闹钟列表页
                        try {
                            val show = Intent(AlarmClock.ACTION_SHOW_ALARMS)
                            show.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            startActivity(show)
                            result.success("opened_alarm_list")
                            return@setMethodCallHandler
                        } catch (_: Exception) {
                        }

                        // 3. 最后兜底：按包名直接打开系统时钟 App
                        for (pkg in listOf(
                            "com.android.deskclock",
                            "com.google.android.deskclock",
                            "com.miui.deskclock"
                        )) {
                            try {
                                val launch = packageManager.getLaunchIntentForPackage(pkg)
                                if (launch != null) {
                                    launch.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                                    startActivity(launch)
                                    result.success("opened_clock_package")
                                    return@setMethodCallHandler
                                }
                            } catch (_: Exception) {
                            }
                        }
                        result.error("NO_ALARM_APP", "No clock app found", null)
                    } catch (e: Exception) {
                        result.error("SET_ALARM_FAILED", "Failed to set system alarm", e.message)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
        
        // FileProvider channel for WebView file upload
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILE_PROVIDER_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getUriForFile" -> {
                    try {
                        val filePath = call.argument<String>("filePath")
                        if (filePath != null) {
                            val file = File(filePath)
                            if (file.exists()) {
                                val uri = FileProvider.getUriForFile(
                                    this,
                                    "${packageName}.fileprovider",
                                    file
                                )
                                result.success(uri.toString())
                            } else {
                                result.error("FILE_NOT_FOUND", "File does not exist", null)
                            }
                        } else {
                            result.error("INVALID_PATH", "File path is null", null)
                        }
                    } catch (e: Exception) {
                        result.error("URI_GENERATION_FAILED", "Failed to generate content URI", e.message)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }
}
