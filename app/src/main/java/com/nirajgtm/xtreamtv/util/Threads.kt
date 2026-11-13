package com.nirajgtm.xtreamtv.util

import android.os.Process
import java.util.concurrent.ThreadFactory

/**
 * All non-UI work runs below the UI thread.
 *
 * On a large catalog (hundreds of thousands of entries) the parse, image decode,
 * TMDB and EPG work can peg every CPU core. At the default thread priority that
 * work competes with the main thread as an equal, so the first frame is never
 * drawn and the system kills the app for not responding - and while browsing, it
 * is what makes scrolling stutter. Pinning every background thread to
 * THREAD_PRIORITY_BACKGROUND lets the Linux scheduler always hand the CPU to
 * rendering first, so the app stays responsive no matter how big the catalog is;
 * the background work simply takes a little longer, which is invisible.
 */
object Threads {

    /** A daemon ThreadFactory whose threads run below the UI thread. */
    fun lowPriorityFactory(name: String): ThreadFactory = ThreadFactory { r ->
        Thread({
            Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
            r.run()
        }, name).apply { isDaemon = true }
    }

    /** Start a background-priority daemon thread. Drop-in for kotlin's thread{}. */
    fun bg(name: String? = null, block: () -> Unit): Thread =
        Thread({
            Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
            block()
        }).apply { isDaemon = true; name?.let { this.name = it }; start() }
}
