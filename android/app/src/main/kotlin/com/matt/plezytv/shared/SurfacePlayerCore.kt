package com.matt.plezytv.shared

/**
 * Surface and display concerns that the ExoPlayer and mpv cores implement
 * identically, so a plugin holding either one dispatches without branching
 * on which backend is active.
 *
 * Only backend-independent members belong here: playback control
 * (play/seek/track selection) stays off this interface because mpv drives it
 * through properties and commands where ExoPlayer uses direct method calls.
 */
interface SurfacePlayerCore {
  fun setVisible(visible: Boolean)
  fun updateFrame()

  /**
   * Move/resize the native surface container to the given physical-pixel
   * rectangle (build #16): the Dart `Video` widget sends the rect its
   * layout occupies — the mini-player's 16:9 hole, or the full window for
   * the fullscreen player. Both backends fit the video into the container,
   * so a hole-sized container puts the picture in the hole instead of
   * centered in the full window behind opaque Flutter UI. A rect that
   * covers the whole window restores fullscreen. The core remembers the
   * last rect and applies it when the container is (re)created, so a rect
   * arriving before the container exists is not lost.
   */
  fun setVideoRect(left: Int, top: Int, right: Int, bottom: Int)
  fun onPipModeChanged(isInPipMode: Boolean)
  fun requestAudioFocus(): Boolean
  fun abandonAudioFocus()
  fun clearVideoFrameRate()
  fun setVideoFrameRate(
    fps: Float,
    videoDurationMs: Long,
    extraDelayMs: Long,
    videoWidth: Int,
    videoHeight: Int,
    matchResolution: Boolean,
    onComplete: (switched: Boolean) -> Unit
  )
}
