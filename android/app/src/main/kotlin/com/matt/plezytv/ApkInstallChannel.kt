package com.matt.plezytv

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Opens the Android system install prompt for a downloaded APK (build #10).
 *
 * The update flow downloads the release APK inside the app (there is no
 * browser download flow on Android TV), then hands the file to the system
 * installer: the APK is shared through the app's FileProvider
 * (`com.matt.plezytv.fileprovider`, whose `<cache-path>` covers the
 * download directory) and fired as an ACTION_VIEW intent with the APK mime
 * type. On first use Android asks the user to allow "Install unknown apps"
 * for PlezTV itself; after that the installer puts the new build over the
 * current one — every build is signed with the same fixed debug keystore,
 * so the over-the-top update keeps its signature.
 *
 * Returns true when the installer opened, false when no app on the device
 * handles the install intent (some stripped TV builds have none). The
 * Dart side offers the release page in the browser as the fallback then.
 */
internal class ApkInstallChannel(private val activity: Activity) {
  companion object {
    const val CHANNEL = "com.matt.plezytv/apk_install"
    private const val TAG = "ApkInstallChannel"
    private const val FILE_PROVIDER_AUTHORITY = "com.matt.plezytv.fileprovider"
    private const val APK_MIME_TYPE = "application/vnd.android.package-archive"
  }

  fun attach(messenger: BinaryMessenger) {
    MethodChannel(messenger, CHANNEL).setMethodCallHandler(::onMethodCall)
  }

  private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    try {
      when (call.method) {
        "installApk" -> installApk(call.argument<String>("filePath"), result)
        else -> result.notImplemented()
      }
    } catch (e: Exception) {
      Log.w(TAG, "${call.method} failed", e)
      result.error("failed", e.message, null)
    }
  }

  private fun installApk(filePath: String?, result: MethodChannel.Result) {
    if (filePath.isNullOrBlank()) {
      result.error("INVALID_ARGUMENT", "filePath is required", null)
      return
    }
    val file = File(filePath)
    if (!file.exists()) {
      result.error("FILE_NOT_FOUND", "Downloaded APK not found at $filePath", null)
      return
    }
    try {
      val uri = FileProvider.getUriForFile(activity, FILE_PROVIDER_AUTHORITY, file)
      val intent = Intent(Intent.ACTION_VIEW).apply {
        setDataAndType(uri, APK_MIME_TYPE)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
      }
      activity.startActivity(intent)
      result.success(true)
    } catch (_: ActivityNotFoundException) {
      result.success(false)
    } catch (e: IllegalArgumentException) {
      // FileProvider refused the path (not under a configured root).
      result.error("BAD_FILE", e.message, null)
    }
  }
}
