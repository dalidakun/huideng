package com.huideng.reader

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
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
                "getLastUpdateTime" -> {
                    try {
                        val info = packageManager.getPackageInfo(packageName, 0)
                        result.success(info.lastUpdateTime)
                    } catch (e: Exception) {
                        result.error("GET_UPDATE_TIME_FAILED", "Failed to get lastUpdateTime", e.message)
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
