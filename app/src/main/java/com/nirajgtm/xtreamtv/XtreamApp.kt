package com.nirajgtm.xtreamtv

import android.app.Application
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import com.nirajgtm.xtreamtv.data.HomeCache
import com.nirajgtm.xtreamtv.data.ResumeStore
import com.nirajgtm.xtreamtv.data.TmdbClient
import com.nirajgtm.xtreamtv.data.XtreamClient
import com.nirajgtm.xtreamtv.ui.ImageLoader
import java.io.File

class XtreamApp : Application() {
    val client: XtreamClient by lazy { XtreamClient(filesDir, this) }
    val resume: ResumeStore by lazy { ResumeStore(File(filesDir, "resume.json")) }
    val tmdb: TmdbClient by lazy { TmdbClient(filesDir) }
    val watchmode: com.nirajgtm.xtreamtv.data.WatchmodeClient by lazy {
        com.nirajgtm.xtreamtv.data.WatchmodeClient(filesDir)
    }
    val homeCache: HomeCache by lazy { HomeCache(File(filesDir, "home_snapshot.json")) }

    /** How often each streaming platform is actually watched, for ordering home rails. */
    val affinity: com.nirajgtm.xtreamtv.data.PlatformAffinity by lazy {
        com.nirajgtm.xtreamtv.data.PlatformAffinity(File(filesDir, "platform_affinity.txt"))
    }

    /** The title on screen or playing right now; its cache is never swept. */
    @Volatile var activeMediaUrl: String = ""

    /** Drops cached video older than a couple of hours, and more if space is tight. */
    val cacheJanitor: com.nirajgtm.xtreamtv.data.CacheJanitor by lazy {
        com.nirajgtm.xtreamtv.data.CacheJanitor(videoCache, cacheDir)
    }

    /** Fills a deep on-disk cushion ahead of whatever is playing. */
    val aheadCache: com.nirajgtm.xtreamtv.data.AheadCache by lazy {
        com.nirajgtm.xtreamtv.data.AheadCache(this)
    }

    /** Serializes heavy startup work so it can't all stampede at once. */
    val background: com.nirajgtm.xtreamtv.data.BackgroundQueue by lazy {
        com.nirajgtm.xtreamtv.data.BackgroundQueue("startup-work")
    }

    /** Warms the video cache with the head + resume-point of recent items so they
     *  start instantly. Bounded to the top items, short window, 24h TTL. */
    val resumePrefetcher: com.nirajgtm.xtreamtv.data.ResumePrefetcher by lazy {
        com.nirajgtm.xtreamtv.data.ResumePrefetcher(this, File(filesDir, "prefetch_meta.txt"))
    }

    /** Where to return after playing a series episode (survives Activity recreation). */
    data class SeriesReturn(val id: Long, val name: String, val season: Int, val episode: Int)
    @Volatile var pendingSeriesReturn: SeriesReturn? = null

    /** One live channel in the current zap list (up/down channel switching). */
    data class LiveZapItem(val id: Long, val url: String, val title: String)
    // The channel list the player zaps through, set by whatever screen launched
    // live playback. Held here (not in the Intent) to dodge the Binder size limit.
    @Volatile var liveZapList: List<LiveZapItem> = emptyList()

    // Disk video cache, least-recently-used. Sized from what the device can
    // actually spare rather than a fixed number: this box has ~4 GB of user
    // storage, so a large fixed cap would fill it. Whatever the limit, the evictor
    // keeps the cache at or under it — it never grows without bound.
    @OptIn(UnstableApi::class)
    val videoCache: SimpleCache by lazy {
        SimpleCache(
            File(cacheDir, "videocache"),
            LeastRecentlyUsedCacheEvictor(videoCacheBytes()),
            StandaloneDatabaseProvider(this)
        )
    }

    /** The evictor's byte limit, exposed so the ahead-fill can respect it: fetching
     *  past what the cache will retain just makes the LRU throw the excess away. */
    @Volatile var videoCacheLimit = 0L; private set

    /** Whatever the device can spare, with no fixed ceiling: a roomy box should be
     *  free to hold whole films, a tight one shrinks to fit. */
    private fun videoCacheBytes(): Long {
        val dir = File(cacheDir, "videocache")
        val existing = try {
            dir.walkTopDown().filter { it.isFile }.map { it.length() }.sum()
        } catch (_: Exception) { 0L }
        val free = try { android.os.StatFs(cacheDir.path).availableBytes } catch (_: Exception) { 0L }
        // Never squeeze the device below a comfortable margin: the limit is
        // whatever is spare after leaving 500 MB free, so the cache can never be
        // the reason storage runs out. No upper bound beyond that - on a device
        // with room, holding a whole title is exactly what we want.
        val spare = (free + existing) - 500L * 1024 * 1024
        return spare.coerceAtLeast(300L * 1024 * 1024).also { videoCacheLimit = it }
    }

    private val startedAt = System.currentTimeMillis()

    override fun onCreate() {
        super.onCreate()
        ImageLoader.init(cacheDir)
        installCrashRecovery()
        // Sweep stale cached video off the disk at startup, off the main thread.
        background.submit { cacheJanitor.sweep(setOfNotNull(activeMediaUrl.ifBlank { null })) }
    }

    /** On an uncaught crash, relaunch to home — unless it crashed almost
     *  immediately (which would loop), in which case let it die. */
    private fun installCrashRecovery() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            android.util.Log.e("XtreamCrash", "uncaught", error)
            val ranLongEnough = System.currentTimeMillis() - startedAt > 8000
            if (ranLongEnough) {
                try {
                    val intent = android.content.Intent(this, MainActivity::class.java)
                        .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK or
                            android.content.Intent.FLAG_ACTIVITY_CLEAR_TASK)
                    val flags = android.app.PendingIntent.FLAG_ONE_SHOT or android.app.PendingIntent.FLAG_IMMUTABLE
                    val pi = android.app.PendingIntent.getActivity(this, 0, intent, flags)
                    (getSystemService(ALARM_SERVICE) as android.app.AlarmManager)
                        .set(android.app.AlarmManager.RTC, System.currentTimeMillis() + 500, pi)
                } catch (_: Exception) {}
                android.os.Process.killProcess(android.os.Process.myPid())
                kotlin.system.exitProcess(1)
            } else {
                previous?.uncaughtException(thread, error)
            }
        }
    }
}
