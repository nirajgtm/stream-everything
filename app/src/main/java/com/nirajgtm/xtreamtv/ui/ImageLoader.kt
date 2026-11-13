package com.nirajgtm.xtreamtv.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.util.LruCache
import android.widget.ImageView
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Async image loader with a two-level cache: an in-memory LRU plus a bounded
 * on-disk cache so thumbnails survive app restarts and don't re-download. Tags
 * each ImageView so recycled rows never show a stale poster.
 */
object ImageLoader {

    private val http = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .build()

    private val memory = object : LruCache<String, Bitmap>(24 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap) = value.byteCount
    }

    private val pool = Executors.newFixedThreadPool(3,
        com.nirajgtm.xtreamtv.util.Threads.lowPriorityFactory("img-loader"))
    private val main = Handler(Looper.getMainLooper())
    private const val TAG_KEY = 0x7f5a0001

    private var diskDir: File? = null
    private const val MAX_DISK_FILES = 600
    private var savesSinceTrim = 0

    // Default decode cap. Art larger than this is downsampled so textures stay small.
    private const val TARGET_MAX_DIM = 500

    fun init(baseDir: File) {
        diskDir = File(baseDir, "imgcache").apply { mkdirs() }
    }

    private fun diskFile(url: String): File? =
        diskDir?.let { File(it, url.hashCode().toString().replace("-", "m") + ".img") }

    /** Drop the image from [view] (the bitmap stays in the caches for a quick return). */
    fun clear(view: ImageView) {
        view.setTag(TAG_KEY, null)
        view.setImageDrawable(null)
    }

    /** [maxDim] caps the decoded size; pass more for full-screen art like backdrops. */
    fun load(view: ImageView, url: String?, placeholderColor: Int, maxDim: Int = TARGET_MAX_DIM) {
        view.setImageDrawable(null)
        view.setBackgroundColor(placeholderColor)
        if (url.isNullOrBlank()) { view.setTag(TAG_KEY, null); return }

        memory.get(url)?.let {
            view.setTag(TAG_KEY, url)
            view.setImageBitmap(it)
            return
        }
        view.setTag(TAG_KEY, url)
        pool.execute {
            var bitmap: Bitmap? = null
            val cached = diskFile(url)
            if (cached != null && cached.exists()) {
                bitmap = try { decodeFileScaled(cached.path, maxDim) } catch (_: Exception) { null }
                if (bitmap != null) cached.setLastModified(System.currentTimeMillis())
            }
            if (bitmap == null) {
                bitmap = downloadAndCache(url, cached, maxDim)
            }
            if (bitmap != null) {
                memory.put(url, bitmap)
                val bmp = bitmap
                main.post { if (view.getTag(TAG_KEY) == url) view.setImageBitmap(bmp) }
            }
        }
    }

    private fun downloadAndCache(url: String, cacheFile: File?, maxDim: Int): Bitmap? {
        return try {
            http.newCall(Request.Builder().url(url).build()).execute().use { response ->
                if (!response.isSuccessful) return@use null
                val bytes = response.body?.bytes() ?: return@use null
                // Cache the original bytes (so a later, larger view could re-decode),
                // but decode to a display-sized bitmap for a cheap GPU upload.
                if (cacheFile != null) {
                    try { cacheFile.writeBytes(bytes); trimDiskIfNeeded() } catch (_: Exception) {}
                }
                decodeByteArrayScaled(bytes, maxDim)
            }
        } catch (_: Exception) { null }
    }

    /** Sample size (power of two) that brings [w]x[h] down near [maxDim] while
     *  staying above it, so the result is sharp but the texture is small. */
    private fun sampleSizeFor(w: Int, h: Int, maxDim: Int): Int {
        var sample = 1
        val longest = maxOf(w, h)
        while (longest / (sample * 2) >= maxDim) sample *= 2
        return sample
    }

    // HARDWARE bitmaps keep their pixels only in GPU memory and are uploaded here,
    // on the decode thread. A normal bitmap costs the same bytes twice (heap copy +
    // texture) and uploads on the UI thread the first time it is drawn.
    private fun decodeOptions(bounds: BitmapFactory.Options, maxDim: Int, hardware: Boolean) =
        BitmapFactory.Options().apply {
            inSampleSize = sampleSizeFor(bounds.outWidth, bounds.outHeight, maxDim)
            if (hardware) inPreferredConfig = Bitmap.Config.HARDWARE
        }

    private fun decodeByteArrayScaled(bytes: ByteArray, maxDim: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        return try {
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, decodeOptions(bounds, maxDim, true))
        } catch (_: Exception) { null }
            ?: BitmapFactory.decodeByteArray(bytes, 0, bytes.size, decodeOptions(bounds, maxDim, false))
    }

    private fun decodeFileScaled(path: String, maxDim: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        return try {
            BitmapFactory.decodeFile(path, decodeOptions(bounds, maxDim, true))
        } catch (_: Exception) { null }
            ?: BitmapFactory.decodeFile(path, decodeOptions(bounds, maxDim, false))
    }
    /** Evict the oldest files when the disk cache grows past the cap. */
    private fun trimDiskIfNeeded() {
        val dir = diskDir ?: return
        if (++savesSinceTrim < 50) return
        savesSinceTrim = 0
        val files = dir.listFiles() ?: return
        if (files.size <= MAX_DISK_FILES) return
        files.sortedBy { it.lastModified() }
            .take(files.size - MAX_DISK_FILES)
            .forEach { it.delete() }
    }
}
