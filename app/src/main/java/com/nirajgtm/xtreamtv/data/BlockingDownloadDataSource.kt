package com.nirajgtm.xtreamtv.data

import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.SimpleCache
import java.io.IOException

/**
 * A VOD data source that reads bytes ONLY from the on-disk cache and never opens a
 * network connection of its own. It is the player half of the multi-TV design: the
 * [AheadCache] downloader is the single network client, fetching in bursts and
 * idling between them so the account's one connection is free for another device;
 * the player lives entirely off what that downloader has banked.
 *
 * The account allows one connection at a time. If the player were allowed to fall
 * through to HTTP on a cache miss (as [CacheDataSource] with an upstream does) it
 * would hold that connection continuously for the whole film, and no second device
 * could ever get in - which is exactly the problem this removes.
 *
 * On a cache miss this source does NOT open a connection. It asks the downloader to
 * prioritise the missing range ([AheadCache.requestRange]) and then BLOCK-waits,
 * re-checking the cache, until the bytes land. ExoPlayer reads on its own loader
 * thread, so blocking here never touches the UI thread; a per-read cap still guards
 * against an unbounded hang by throwing so the player rebuffers and retries.
 */
@OptIn(UnstableApi::class)
class BlockingDownloadDataSource(
    private val cache: SimpleCache,
    private val ahead: AheadCache
) : BaseDataSource(/* isNetwork = */ false) {

    private companion object {
        /** Matches the downloader's chunk: what we ask it to fetch for a hole. */
        const val CHUNK_BYTES = 24L * 1024 * 1024
        const val DEMAND_BYTES = 3L * 1024 * 1024
        const val TAG = "BlockingSource"
        /** How often to re-check the cache while blocked on a hole. */
        const val POLL_MS = 120L
        /** Cap on blocking for one read; past this, throw so the player rebuffers. */
        const val MAX_HOLE_WAIT_MS = 90_000L
        /** Cap on blocking in open() while the downloader resolves the total length. */
        const val MAX_LENGTH_WAIT_MS = 30_000L
    }

    private var uri: Uri? = null
    private var key: String = ""
    private var position: Long = 0L
    private var readWaitStartedAt = 0L
    /** Bytes left to serve for this open, or C.LENGTH_UNSET if not yet known. */
    private var bytesRemaining: Long = C.LENGTH_UNSET.toLong()
    private var opened = false

    // A lazily-opened cache-ONLY reader (no upstream), reused while reads stay
    // sequential and reopened after any discontinuity. It is only ever asked for
    // byte ranges just confirmed to be cached, so it cannot miss (and if the evictor
    // races it, the read throws and is caught, and the outer loop re-checks/waits).
    private var reader: CacheDataSource? = null
    private var readerNextPos: Long = -1L

    override fun open(dataSpec: DataSpec): Long {
        transferInitializing(dataSpec)
        uri = dataSpec.uri
        key = dataSpec.key ?: dataSpec.uri.toString()
        position = dataSpec.position

        val total = resolveTotalLength()
        bytesRemaining = when {
            dataSpec.length != C.LENGTH_UNSET.toLong() -> dataSpec.length
            total > 0 -> (total - position).coerceAtLeast(0)
            else -> C.LENGTH_UNSET.toLong()
        }

        // Point the downloader at the byte the player is about to read, so it fetches
        // there first (a resume point, a header near EOF, a user seek - all covered).
        val nudge = if (bytesRemaining > 0) minOf(DEMAND_BYTES, bytesRemaining) else DEMAND_BYTES
        try { ahead.requestRange(position, nudge) } catch (_: Exception) {}

        opened = true
        transferStarted(dataSpec)
        android.util.Log.i(TAG, "open @${position / 1_000_000}MB remain=" +
            (if (bytesRemaining > 0) "${bytesRemaining / 1_000_000}MB" else "unknown"))
        return bytesRemaining
    }

    /**
     * Total byte length of the title, obtained WITHOUT opening a connection here.
     * The downloader resolves and records it (and writes it into the cache's content
     * metadata); this blocks briefly for that to happen. Returns <= 0 if it could not
     * be resolved within the cap - the caller then serves an unbounded stream and
     * resolves the length lazily on later reads instead.
     */
    private fun resolveTotalLength(): Long {
        var total = ahead.knownLength(key)
        if (total > 0) return total
        // Nudge the downloader to fetch the header, which resolves the length.
        try { ahead.requestRange(0, CHUNK_BYTES) } catch (_: Exception) {}
        val deadline = System.currentTimeMillis() + MAX_LENGTH_WAIT_MS
        while (System.currentTimeMillis() < deadline) {
            total = ahead.knownLength(key)
            if (total > 0) return total
            try { Thread.sleep(POLL_MS) } catch (_: InterruptedException) {
                Thread.currentThread().interrupt(); break
            }
        }
        return total
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0

        // Resolve the length lazily if open() could not (never opens a connection).
        if (bytesRemaining == C.LENGTH_UNSET.toLong()) {
            val total = ahead.knownLength(key)
            if (total > 0) bytesRemaining = (total - position).coerceAtLeast(0)
        }
        if (bytesRemaining == 0L) return C.RESULT_END_OF_INPUT

        val want = if (bytesRemaining > 0) minOf(length.toLong(), bytesRemaining).toInt() else length

        val deadline = System.currentTimeMillis() + MAX_HOLE_WAIT_MS
        readWaitStartedAt = 0L
        while (true) {
            val cached = try { cache.getCachedLength(key, position, want.toLong()) } catch (_: Exception) { 0L }
            if (cached > 0) {
                if (readWaitStartedAt > 0L) {
                    android.util.Log.i(TAG, "STALL cleared @${position / 1_000_000}MB after " +
                        "${System.currentTimeMillis() - readWaitStartedAt}ms")
                    readWaitStartedAt = 0L
                }
                val toRead = minOf(want.toLong(), cached).toInt()
                val n = readFromCache(buffer, offset, toRead)
                if (n > 0) {
                    position += n
                    if (bytesRemaining > 0) bytesRemaining -= n
                    bytesTransferred(n)
                    return n
                }
                // Reader could not produce bytes (evictor race): loop and re-check.
            } else {
                // A hole: never open a connection here - ask the downloader and wait.
                if (readWaitStartedAt == 0L) {
                    readWaitStartedAt = System.currentTimeMillis()
                    android.util.Log.i(TAG, "STALL waiting @${position / 1_000_000}MB (buffer ran dry)")
                }
                try { ahead.requestRange(position, DEMAND_BYTES) } catch (_: Exception) {}
                if (System.currentTimeMillis() > deadline)
                    throw IOException("timed out waiting for cached bytes: $key @ $position")
                try { Thread.sleep(POLL_MS) } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    throw IOException("interrupted waiting for cached bytes: $key @ $position")
                }
            }
        }
    }

    /** Read [toRead] bytes of the already-confirmed cached run via the inner reader. */
    private fun readFromCache(buffer: ByteArray, offset: Int, toRead: Int): Int {
        var r = reader
        if (r == null || readerNextPos != position) r = openReaderAt(position)
        var n = try { r.read(buffer, offset, toRead) } catch (_: Exception) { -2 }
        if (n < 0) {
            // Bounded span exhausted, or the reader desynced: reopen fresh at position.
            r = openReaderAt(position)
            n = try { r.read(buffer, offset, toRead) } catch (_: Exception) { closeReader(); return 0 }
            if (n < 0) return 0
        }
        readerNextPos = position + n
        return n
    }

    private fun openReaderAt(pos: Long): CacheDataSource {
        closeReader()
        val run = try { cache.getCachedLength(key, pos, Long.MAX_VALUE) } catch (_: Exception) { 0L }
        val len = if (run > 0) run else 1L
        // No upstream factory => a cache-only source that never reaches the network.
        val r = CacheDataSource.Factory().setCache(cache).createDataSource()
        r.open(DataSpec.Builder().setUri(uri!!).setKey(key).setPosition(pos).setLength(len).build())
        reader = r
        readerNextPos = pos
        return r
    }

    private fun closeReader() {
        try { reader?.close() } catch (_: Exception) {}
        reader = null
        readerNextPos = -1L
    }

    override fun getUri(): Uri? = uri

    override fun close() {
        closeReader()
        if (opened) {
            opened = false
            transferEnded()
        }
        uri = null
    }
}
