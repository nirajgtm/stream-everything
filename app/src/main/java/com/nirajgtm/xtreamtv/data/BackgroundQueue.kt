package com.nirajgtm.xtreamtv.data

import java.util.concurrent.Executors
import java.util.concurrent.ThreadFactory

/**
 * Runs background startup work one task at a time instead of all at once.
 *
 * Catalog loading, TMDB rail rebuilds, title indexing and resume pre-caching used
 * to each spawn their own thread the moment home appeared. Together they saturated
 * the CPU and the network on a Chromecast, so the UI stuttered exactly when the
 * user was trying to navigate. Serializing them keeps total work the same while
 * leaving the main thread responsive, and ordering matters: whatever the user sees
 * first should be queued first.
 *
 * Tasks run at low priority on a single daemon thread; failures are swallowed so
 * one broken task cannot stall the rest of the queue.
 */
class BackgroundQueue(name: String = "bg-queue") {

    private val exec = Executors.newSingleThreadExecutor(ThreadFactory { r ->
        Thread(r, name).apply { isDaemon = true; priority = Thread.MIN_PRIORITY }
    })

    /** Queue [task]; it runs after everything already queued. */
    fun submit(task: () -> Unit) {
        try {
            exec.execute {
                try { task() } catch (_: Exception) { /* one failure must not stall the queue */ }
            }
        } catch (_: Exception) { /* executor shut down */ }
    }

    fun shutdown() {
        try { exec.shutdownNow() } catch (_: Exception) {}
    }
}
