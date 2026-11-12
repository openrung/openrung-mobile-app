package com.openrung

import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.view.ViewTreeObserver
import com.facebook.react.ReactActivity
import com.facebook.react.ReactActivityDelegate
import com.facebook.react.defaults.DefaultNewArchitectureEntryPoint.fabricEnabled
import com.facebook.react.defaults.DefaultReactActivityDelegate

class MainActivity : ReactActivity() {

  /**
   * Returns the name of the main component registered from JavaScript. This is used to schedule
   * rendering of the component.
   */
  override fun getMainComponentName(): String = "OpenRung"

  /**
   * Returns the instance of the [ReactActivityDelegate]. We use [DefaultReactActivityDelegate]
   * which allows you to enable New Architecture with a single boolean flags [fabricEnabled]
   */
  override fun createReactActivityDelegate(): ReactActivityDelegate =
      DefaultReactActivityDelegate(this, mainComponentName, fabricEnabled)

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) holdSplashUntilReactDraws()
  }

  /**
   * The API 31+ system splash leaves on the first frame, which would otherwise be an empty
   * React root. Defer drawing until React has mounted content (or a timeout passes) so the
   * splash hands straight over to the UI. Before API 31 the themed window background plays
   * this role on its own.
   */
  private fun holdSplashUntilReactDraws() {
    val content = findViewById<View>(android.R.id.content)
    val deadline = SystemClock.uptimeMillis() + SPLASH_MAX_HOLD_MS
    content.viewTreeObserver.addOnPreDrawListener(
        object : ViewTreeObserver.OnPreDrawListener {
          override fun onPreDraw(): Boolean {
            val root = (content as? ViewGroup)?.getChildAt(0) as? ViewGroup
            val ready = (root?.childCount ?: 0) > 0 || SystemClock.uptimeMillis() >= deadline
            if (ready) content.viewTreeObserver.removeOnPreDrawListener(this)
            return ready
          }
        })
  }

  private companion object {
    const val SPLASH_MAX_HOLD_MS = 3_000L
  }
}
