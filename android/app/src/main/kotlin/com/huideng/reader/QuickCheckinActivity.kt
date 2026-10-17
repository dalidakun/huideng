package com.huideng.reader

import android.app.Activity
import android.content.Context
import android.os.Bundle
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 桌面「一键打卡」快捷方式的入口：**无界面** 的透明 Activity。
 *
 * 不启动 Flutter 引擎、不显示任何 UI，而是直接读写 shared_preferences 的底层
 * 文件（`FlutterSharedPreferences`，键统一带 `flutter.` 前缀），把主页配置的
 * 具体功课项补齐为「今日已打卡」，并留下 `shortcut_checkin_needs_share` 标记，
 * 等用户下次打开 App 时由 Dart 侧静默分享到菩提空间。整个过程在这里完成即
 * 立即 finish，用户感知不到 App 被打开。
 */
class QuickCheckinActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            // 仅接受本应用快捷方式携带的专用 action，防止被其他显式 Intent 触发。
            if (intent?.action == ACTION_QUICK_CHECKIN) {
                performQuickCheckin(this)
            }
        } catch (_: Throwable) {
            // 快捷方式打卡失败不打扰用户：静默忽略。
        } finally {
            finish()
            @Suppress("DEPRECATION")
            overridePendingTransition(0, 0)
        }
    }

    companion object {
        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val PREFIX = "flutter."

        /** 供启动 Intent 校验，避免被其他显式 Intent 触发。 */
        const val ACTION_QUICK_CHECKIN = "com.huideng.reader.action.QUICK_CHECKIN"

        /**
         * 读取 [PREFIX]quick_checkin_items（主页写入的具体功课项），把今日缺失的
         * 项补进 [PREFIX]checkin_records，并置位待分享标记。返回本次新补项数。
         */
        fun performQuickCheckin(context: Context): Int {
            val sp = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val itemsRaw = sp.getString(PREFIX + "quick_checkin_items", null) ?: return 0
            val items = try {
                JSONArray(itemsRaw)
            } catch (_: Exception) {
                return 0
            }
            if (items.length() == 0) return 0

            val today = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())
            val records = try {
                JSONArray(sp.getString(PREFIX + "checkin_records", "[]") ?: "[]")
            } catch (_: Exception) {
                JSONArray()
            }

            // 今日已存在的项（type\u0001name）集合，避免重复打卡。
            val existing = HashSet<String>()
            for (i in 0 until records.length()) {
                val r = records.optJSONObject(i) ?: continue
                if (r.optString("date") == today) {
                    existing.add(r.optString("type") + "\u0001" + r.optString("name"))
                }
            }

            var added = 0
            for (i in 0 until items.length()) {
                val it = items.optJSONObject(i) ?: continue
                val type = it.optString("type")
                val name = it.optString("name")
                if (type.isEmpty() || name.isEmpty()) continue
                val key = type + "\u0001" + name
                if (existing.contains(key)) continue
                val rec = JSONObject()
                rec.put("date", today)
                rec.put("type", type)
                rec.put("label", it.optString("label"))
                rec.put("name", name)
                rec.put("amount", it.optDouble("amount", 0.0))
                records.put(rec)
                existing.add(key)
                added++
            }

            if (added == 0) return 0

            // commit() 同步落盘：确保随后冷启动的 MainActivity 一定能读到最新记录。
            sp.edit()
                .putString(PREFIX + "checkin_records", records.toString())
                .putBoolean(PREFIX + "shortcut_checkin_needs_share", true)
                .commit()
            return added
        }
    }
}
