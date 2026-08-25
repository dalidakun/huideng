package com.huideng.reader

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
import android.provider.AlarmClock
import androidx.core.content.FileProvider
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "app_channel"
    private val FILE_PROVIDER_CHANNEL = "com.huideng.reader/file_provider"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
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
