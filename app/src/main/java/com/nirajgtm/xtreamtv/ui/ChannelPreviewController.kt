package com.nirajgtm.xtreamtv.ui

import android.app.Activity
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import android.widget.AdapterView
import android.widget.FrameLayout
import android.widget.ListView
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import java.util.concurrent.TimeUnit

/**
 * A single muted live preview that follows the focused row of a channel list.
 * After a short dwell on a row (so fast scrolling doesn't thrash the one hardware
 * decoder), it plays that channel into the row's preview slot. Frames are cached
 * continuously while it plays (5-min TTL) and the newest one is painted onto the
 * row as focus leaves, so a row you've watched keeps showing what was on rather
 * than snapping back to the station logo. Only one row ever previews at a time.
 */
class ChannelPreviewController(
    private val activity: Activity,
    private val listView: ListView,
    /** (channelId, liveUrl) for a list position, or null if unavailable. */
    private val targetAt: (Int) -> Pair<Long, String>?
) {
    private val handler = Handler(Looper.getMainLooper())
    private val dwellMs = 800L
    private val captureEveryMs = 1_000L

    private var player: ExoPlayer? = null
    private var texture: TextureView? = null
    private var currentId = 0L
    private var currentSlot: FrameLayout? = null
    /** getBitmap only returns real pixels once the decoder has drawn to the surface. */
    private var frameRendered = false

    // Keep a still fresh the whole time a row previews, so leaving at any moment
    // (mid-buffer, mid-rebuffer, straight after the first frame) already has one.
    private val captureTick = object : Runnable {
        override fun run() {
            captureFrame()
            handler.postDelayed(this, captureEveryMs)
        }
    }

    /** Hook the controller to the list's selection changes. */
    fun attach() {
        listView.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(p: AdapterView<*>?, view: View?, pos: Int, id: Long) = onSelected(view, pos)
            override fun onNothingSelected(p: AdapterView<*>?) = stopPreview()
        }
        // The list losing focus entirely (moving up to the search box, or the whole
        // view being swapped out) does not fire onNothingSelected, so a channel
        // would otherwise keep playing off-screen.
        listView.setOnFocusChangeListener { _, hasFocus ->
            if (!hasFocus) { handler.removeCallbacksAndMessages(null); stopPreview() }
        }
    }

    private fun onSelected(rowView: View?, position: Int) {
        handler.removeCallbacksAndMessages(null)
        stopPreview()
        if (rowView == null) return
        handler.postDelayed({ startPreview(rowView, position) }, dwellMs)
    }

    private fun startPreview(rowView: View, position: Int) {
        // Only ever play for the row that is still selected, still on screen and
        // still focused. Without this the dwell timer can fire after the results
        // were replaced or the screen was left, starting a channel nobody is on.
        if (!listView.isShown || !listView.hasFocus()) return
        if (listView.selectedItemPosition != position) return
        if (rowView.parent == null) return // row recycled out from under us
        val target = targetAt(position) ?: return
        val slot = rowView.findViewById<FrameLayout>(ChannelRowAdapter.PREVIEW_SLOT_ID) ?: return
        ensurePlayer()
        val tex = texture ?: return
        (tex.parent as? ViewGroup)?.removeView(tex)
        slot.addView(tex, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        currentId = target.first
        currentSlot = slot
        frameRendered = false
        player?.apply {
            setMediaItem(MediaItem.fromUri(target.second))
            playWhenReady = true
            prepare()
        }
        handler.postDelayed(captureTick, captureEveryMs)
    }

    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    private fun ensurePlayer() {
        if (player != null) return
        texture = TextureView(activity)
        val http = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(15_000).setReadTimeoutMs(15_000)
            .setUserAgent("XtreamTV/1.0")
        player = ExoPlayer.Builder(activity)
            .setMediaSourceFactory(DefaultMediaSourceFactory(http))
            .build().apply {
                volume = 1f // preview plays with sound
                setVideoTextureView(texture)
                addListener(object : Player.Listener {
                    override fun onPlayerError(error: PlaybackException) { /* preview: ignore */ }
                    override fun onRenderedFirstFrame() {
                        frameRendered = true
                        // Grab one right away so even a one-second dwell leaves a still;
                        // a beat later than the callback so the surface has settled.
                        handler.postDelayed({ captureFrame() }, 150)
                    }
                })
            }
    }

    /**
     * Cache whatever is on the surface, keyed by channel, ignoring grabs taken
     * before the first frame or while the surface is gone.
     * @return the stored frame, or null if there was nothing usable to store.
     */
    private fun captureFrame(): Bitmap? {
        val tex = texture ?: return null
        val id = currentId
        if (id == 0L || !frameRendered || !tex.isAvailable) return null
        val bmp = try { tex.getBitmap(320, 180) } catch (_: Exception) { null } ?: return null
        return if (PreviewCache.put(id, bmp)) bmp else null
    }

    /** Stop the preview, leaving its last frame on the row, and detach the surface. */
    private fun stopPreview() {
        handler.removeCallbacks(captureTick)
        // Fall back to the newest cached frame: the final grab can fail (surface
        // already torn down, black gap) after earlier ticks captured a good one.
        val frame = captureFrame() ?: PreviewCache.get(currentId)
        val slot = currentSlot
        if (frame != null && slot != null) ChannelRowAdapter.showFrame(slot, frame)
        currentId = 0L
        currentSlot = null
        frameRendered = false
        player?.stop()
        (texture?.parent as? ViewGroup)?.removeView(texture)
    }

    /** Free the decoder when leaving the screen (e.g. starting full playback). */
    fun pause() {
        handler.removeCallbacksAndMessages(null)
        stopPreview()
    }

    fun release() {
        handler.removeCallbacksAndMessages(null)
        stopPreview()
        player?.release(); player = null; texture = null
    }
}
