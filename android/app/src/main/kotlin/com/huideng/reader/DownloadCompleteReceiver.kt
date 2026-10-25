package com.huideng.reader

import android.app.DownloadManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.FileProvider
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest

/**
 * 系统下载完成广播：后台下载结束后发一条通知，用户点击直接进入安装界面。
 *
 * 更新下载交给 DownloadManager，因此离开 App、甚至进程被回收后仍会继续；
 * 这里在完成时负责校验安装包并提示安装。
 */
class DownloadCompleteReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != DownloadManager.ACTION_DOWNLOAD_COMPLETE) return
        val id = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1L)
        if (id <= 0) return
        val pendingResult = goAsync()
        Thread {
            try {
                handle(context.applicationContext, id)
            } finally {
                pendingResult.finish()
            }
        }.start()
    }

    private fun handle(context: Context, id: Long) {
        val manager = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        val cursor = manager.query(DownloadManager.Query().setFilterById(id)) ?: return
        val status: Int
        try {
            if (!cursor.moveToFirst()) return
            status = cursor.getInt(
                cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)
            )
        } finally {
            cursor.close()
        }
        if (status != DownloadManager.STATUS_SUCCESSFUL) return

        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val path = prefs.getString("path_$id", null) ?: return
        val version = prefs.getString("version_$id", "") ?: ""
        val expectedSha = prefs.getString("sha_$id", "") ?: ""
        val file = File(path)
        if (!file.exists()) {
            notifyInstall(context, file, version, null)
            return
        }
        if (expectedSha.isNotEmpty() && !sha256(file).equals(expectedSha, true)) {
            file.delete()
            notifyInstall(context, file, version, "安装包校验失败，请重新下载")
            return
        }
        notifyInstall(context, file, version, null)
    }

    private fun notifyInstall(
        context: Context,
        file: File,
        version: String,
        error: String?
    ) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE)
            as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "应用更新",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "新版本下载完成后的安装提示"
                }
            )
        }

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)

        if (error != null) {
            builder.setContentTitle("燃灯新版本下载失败")
                .setContentText(error)
        } else {
            val installIntent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(
                    FileProvider.getUriForFile(
                        context,
                        "${context.packageName}.fileprovider",
                        file
                    ),
                    "application/vnd.android.package-archive"
                )
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val pending = PendingIntent.getActivity(
                context,
                NOTIFICATION_ID,
                installIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            builder.setContentTitle("燃灯新版本已下载")
                .setContentText(
                    if (version.isNotEmpty()) "点击安装 v$version" else "点击安装新版本"
                )
                .setContentIntent(pending)
        }

        if (NotificationManagerCompat.from(context).areNotificationsEnabled()) {
            NotificationManagerCompat.from(context)
                .notify(NOTIFICATION_ID, builder.build())
        }
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read <= 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xFF) }
    }

    companion object {
        const val PREFS = "update_download"
        const val CHANNEL_ID = "app_update"
        const val NOTIFICATION_ID = 2001
    }
}
