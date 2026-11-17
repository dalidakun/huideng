package com.huideng.reader

import android.app.Activity
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import com.alipay.sdk.app.PayTask
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * 支付宝 App 支付的原生通道（参考实现，未联调）。
 *
 * 只做两件事：
 *  - pay：把云函数签好的 orderStr 交给官方 SDK，阻塞等待用户返回；
 *  - isInstalled：判断支付宝是否安装（Android 11+ 需在 Manifest 里声明包可见性）。
 *
 * 在 MainActivity.configureFlutterEngine 末尾注册：
 *   registerAlipayChannel(this, flutterEngine.dartExecutor.binaryMessenger)
 *
 * 依赖（android/app/build.gradle.kts）：
 *   implementation("com.alipay.sdk:alipaysdk-android:15.8.42")
 *
 * 混淆（android/app/proguard-rules.pro）：
 *   -keep class com.alipay.** { *; }
 *   -dontwarn com.alipay.**
 */

private const val CHANNEL = "huideng/alipay"
private const val ALIPAY_PACKAGE = "com.eg.android.AlipayGphone"

// SDK 的 payV2 会阻塞到用户从支付宝返回，必须放后台线程；
// 单线程足够，支付本身不允许并发。
private val payExecutor = Executors.newSingleThreadExecutor()
private val mainHandler = Handler(Looper.getMainLooper())

fun registerAlipayChannel(activity: Activity, messenger: BinaryMessenger) {
    MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
        when (call.method) {
            "pay" -> {
                val orderStr = call.argument<String>("orderStr")
                if (orderStr.isNullOrBlank()) {
                    result.error("INVALID_ORDER", "orderStr 为空", null)
                    return@setMethodCallHandler
                }
                payExecutor.execute {
                    try {
                        val payResult: Map<String, String> = PayTask(activity).payV2(orderStr, true)
                        mainHandler.post { result.success(payResult) }
                    } catch (t: Throwable) {
                        mainHandler.post {
                            result.error("ALIPAY_FAILED", t.message ?: "调起支付宝失败", null)
                        }
                    }
                }
            }

            "isInstalled" -> result.success(isAlipayInstalled(activity))

            else -> result.notImplemented()
        }
    }
}

private fun isAlipayInstalled(activity: Activity): Boolean {
    return try {
        activity.packageManager.getPackageInfo(ALIPAY_PACKAGE, 0)
        true
    } catch (_: PackageManager.NameNotFoundException) {
        false
    }
}
