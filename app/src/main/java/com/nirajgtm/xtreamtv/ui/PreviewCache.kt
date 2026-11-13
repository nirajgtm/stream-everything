package com.nirajgtm.xtreamtv.ui

import android.graphics.Bitmap

/**
 * Short-lived cache of channel "last frame" thumbnails, keyed by channel id.
 * Populated when you leave a channel (full playback) or after an in-row preview,
 * and shown as that channel's row image until it expires. TTL 5 minutes; bounded
 * so bitmaps don't pile up.
 */
object PreviewCache {

    private const val TTL_MS = 5 * 60 * 1000L
    private const val MAX = 24

    private class Frame(val bmp: Bitmap, val at: Long)

    private val map = object : LinkedHashMap<Long, Frame>(32, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Long, Frame>) = size > MAX
    }

    /** @return true if the frame was worth keeping (blank grabs are dropped). */
    @Synchronized
    fun put(channelId: Long, bmp: Bitmap): Boolean {
        if (channelId == 0L || isBlank(bmp)) return false
        map[channelId] = Frame(bmp, System.currentTimeMillis())
        return true
    }

    /**
     * A grab taken before the decoder has drawn anything (or during a black gap)
     * comes back flat black. Storing it would replace a perfectly good still with
     * something the user can't read, so sample a coarse grid and reject frames
     * that are essentially dark or completely uniform.
     */
    private fun isBlank(bmp: Bitmap): Boolean {
        if (bmp.width < 8 || bmp.height < 8) return true
        var brightest = 0
        var firstPixel = 0
        var varied = false
        var n = 0
        for (y in 1 until 5) for (x in 1 until 7) {
            val px = bmp.getPixel(bmp.width * x / 7, bmp.height * y / 5)
            val lum = maxOf((px shr 16) and 0xFF, (px shr 8) and 0xFF, px and 0xFF)
            if (lum > brightest) brightest = lum
            if (n++ == 0) firstPixel = px else if (px != firstPixel) varied = true
        }
        return brightest < 16 || !varied
    }

    /** Fresh thumbnail for the channel, or null if none / expired. */
    @Synchronized
    fun get(channelId: Long): Bitmap? {
        val frame = map[channelId] ?: return null
        if (System.currentTimeMillis() - frame.at > TTL_MS) { map.remove(channelId); return null }
        return frame.bmp
    }
}
