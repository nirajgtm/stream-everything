package com.nirajgtm.xtreamtv

import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.KeyEvent
import android.view.WindowManager
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import com.nirajgtm.xtreamtv.ui.ImageLoader
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.exoplayer.ExoPlayer
import com.nirajgtm.xtreamtv.data.AheadCache
import com.nirajgtm.xtreamtv.data.BlockingDownloadDataSource
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.PlayerView

class PlayerActivity : Activity() {

    private var player: ExoPlayer? = null
    private lateinit var playerView: PlayerView
    private lateinit var livePlaceholder: ImageView // last preview frame during live buffering
    private lateinit var seekIndicator: TextView

    private var seekStreak = 0
    private var lastSeekPressMs = 0L
    private val indicatorHandler = Handler(Looper.getMainLooper())

    private var resumeKey: String? = null
    private var resumePosition = 0L
    private var isLive = false
    private var liveRetries = 0
    // Startup timing (logged once per playback under the XtreamPerf tag).
    private var playerStartedAt = 0L
    private var firstFrameLoggedAt = 0L
    private val recoverHandler = Handler(Looper.getMainLooper())
    // Live stall detection (a wedged stream that never reports an error).
    private val liveWatchdogHandler = Handler(Looper.getMainLooper())
    private var liveStalledSince = 0L
    private val aheadHandler = Handler(Looper.getMainLooper())
    // The VOD playback strategy chosen once in onCreate: direct streaming (proven,
    // holds the connection) vs shared-connection (plays from disk, frees the wire).
    // Null for live, which is separate and always streams straight from the network.
    private var vodMode: VodPlaybackMode? = null
    private var lastLivePosition = -1L
    private val saveHandler = Handler(Looper.getMainLooper()) // periodic resume-position save
    // Live channel zapping (up/down like a TV), fed by the launching screen.
    private var zapList: List<XtreamApp.LiveZapItem> = emptyList()
    private var zapIndex = 0
    private var liveChannelId = 0L // current live channel (for favoriting)
    private lateinit var zapOverlay: LinearLayout      // translucent up/down channel list
    private lateinit var zapNowLine: TextView          // "Now: ..." under the current channel
    private lateinit var favButton: android.widget.Button // ♥ in the live control bar
    private val bannerHandler = Handler(Looper.getMainLooper())
    private var bannerGen = 0
    // Whole-series playlist (empty for movies / live / single episode).
    private var epUrls: List<String> = emptyList()
    private var epTitles: List<String> = emptyList()
    private var epKeys: List<String> = emptyList()
    private var epPlots: List<String> = emptyList()
    private var epSeasons: IntArray = IntArray(0)
    private var epNums: IntArray = IntArray(0)
    private val multiEpisode get() = epUrls.size > 1
    private var advancePending = false
    private lateinit var nextPrompt: TextView
    private lateinit var nextButton: android.widget.Button
    private val advanceHandler = Handler(Looper.getMainLooper())
    private val positionHandler = Handler(Looper.getMainLooper())
    private var nextUpRecorded = false // queued the next episode into Continue Watching
    private var nextButtonDismissed = false // user dismissed the "Play next episode" button
    // Next episode queued with the ahead-cache once under 2 min remain.
    private var prefetchedForIndex = -1
    // "Connection limit reached" notice, shown only when it can actually bite.
    private lateinit var connectionNotice: TextView
    private lateinit var pauseOverlay: android.view.View
    private var hasOverlayContent = false
    private lateinit var ovTitleView: TextView
    private lateinit var ovMetaView: TextView
    private lateinit var ovPlotView: TextView
    private lateinit var ovPosterView: ImageView
    private lateinit var ovCastRow: LinearLayout
    private lateinit var ovCastScroll: android.widget.HorizontalScrollView
    private var detailsFetched = false

    @OptIn(UnstableApi::class)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        goFullscreen()

        val url = intent.getStringExtra("url") ?: run { finish(); return }
        isLive = intent.getBooleanExtra("isLive", false)
        resumeKey = intent.getStringExtra("resumeKey")
        resumePosition = intent.getLongExtra("resumePosition", 0L)
        epUrls = intent.getStringArrayListExtra("epUrls") ?: emptyList()
        epTitles = intent.getStringArrayListExtra("epTitles") ?: emptyList()
        epKeys = intent.getStringArrayListExtra("epKeys") ?: emptyList()
        epPlots = intent.getStringArrayListExtra("epPlots") ?: emptyList()
        epSeasons = intent.getIntArrayExtra("epSeasons") ?: IntArray(0)
        epNums = intent.getIntArrayExtra("epNums") ?: IntArray(0)
        val startIndex = intent.getIntExtra("epStartIndex", 0)

        if (isLive) {
            zapList = (application as XtreamApp).liveZapList
            zapIndex = intent.getIntExtra("liveIndex", 0).coerceIn(0, maxOf(0, zapList.size - 1))
            liveChannelId = zapList.getOrNull(zapIndex)?.id ?: intent.getLongExtra("channelId", 0L)
        }
        playerView = PlayerView(this).apply {
            useController = true
            controllerShowTimeoutMs = 4000
            // Live: don't let the bar auto-pop on channel changes (it would fight
            // up/down zapping). It only appears on an explicit OK press.
            controllerAutoShow = !isLive
            // Live has no subtitles/tracks to pick and no episode skip — keep the bar clean.
            setShowSubtitleButton(!isLive) // CC button (VOD only)
            setShowNextButton(multiEpisode)     // ⏭ jump to next episode
            setShowPreviousButton(multiEpisode) // ⏮ jump to previous episode
        }
        seekIndicator = TextView(this).apply {
            textSize = 22f
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.parseColor("#AA101820"))
            setPadding(32, 16, 32, 16)
            visibility = android.view.View.GONE
        }
        pauseOverlay = buildPauseOverlay()
        nextPrompt = TextView(this).apply {
            textSize = 18f; setTextColor(Color.WHITE)
            setBackgroundColor(Color.parseColor("#CC101820")); setPadding(40, 22, 40, 22)
            visibility = android.view.View.GONE
        }
        connectionNotice = TextView(this).apply {
            textSize = 17f; setTextColor(Color.WHITE)
            setBackgroundColor(Color.parseColor("#CC101820")); setPadding(40, 22, 40, 22)
            visibility = android.view.View.GONE
        }
        nextButton = android.widget.Button(this).apply {
            text = "▶  Play next episode"
            isAllCaps = false; textSize = 16f
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.parseColor("#E6008577"))
            setPadding(36, 16, 36, 16)
            visibility = android.view.View.GONE
            setOnClickListener { playNext() }
        }
        zapOverlay = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#B3101820")) // translucent
            setPadding(28, 24, 28, 24)
            visibility = android.view.View.GONE
        }
        favButton = android.widget.Button(this).apply {
            isAllCaps = false; textSize = 16f
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.parseColor("#E6008577"))
            setPadding(30, 14, 30, 14)
            visibility = android.view.View.GONE
            setOnClickListener { toggleLiveFavorite() }
        }
        // Behind the video: the last preview frame, so a live handoff shows a
        // still (not black) while the stream buffers. The shutter is transparent
        // for live so this shows through until the first frame renders.
        livePlaceholder = ImageView(this).apply {
            scaleType = ImageView.ScaleType.CENTER_CROP
            visibility = android.view.View.GONE
        }
        if (isLive) {
            playerView.setShutterBackgroundColor(android.graphics.Color.TRANSPARENT)
            com.nirajgtm.xtreamtv.ui.PreviewCache.get(liveChannelId)?.let {
                livePlaceholder.setImageBitmap(it); livePlaceholder.visibility = android.view.View.VISIBLE
            }
        }
        val root = FrameLayout(this).apply {
            addView(livePlaceholder) // behind the player
            addView(playerView)
            addView(pauseOverlay) // above the video, below focus (non-focusable)
            addView(zapOverlay, FrameLayout.LayoutParams(
                560, FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER_VERTICAL or Gravity.START))
            // Sits just above the control bar; appears with the controls (live only).
            addView(favButton, FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM or Gravity.END).apply { bottomMargin = 200; marginEnd = 48 })
            addView(nextButton, FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM or Gravity.END).apply { bottomMargin = 220; marginEnd = 60 })
            addView(nextPrompt, FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM or Gravity.END).apply { bottomMargin = 140; marginEnd = 60 })
            addView(seekIndicator, FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply { bottomMargin = 120 })
            addView(connectionNotice, FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.TOP or Gravity.CENTER_HORIZONTAL).apply { topMargin = 56 })
        }
        setContentView(root)

        // Clear green focus ring on the custom on-screen buttons.
        withFocusBorder(nextButton)
        withFocusBorder(favButton)

        // Live: start with the bar hidden so up/down zap cleanly.
        if (isLive) {
            playerView.post { playerView.hideController() }
            updateFavButton()
            playerView.setControllerVisibilityListener(
                androidx.media3.ui.PlayerView.ControllerVisibilityListener { visibility ->
                    favButton.visibility = if (visibility == android.view.View.VISIBLE)
                        android.view.View.VISIBLE else android.view.View.GONE
                })
        }

        // What is actually about to play: for a series that is the episode the
        // playlist starts on, which is not always the plain "url" extra.
        val playingUrl = if (multiEpisode) epUrls.getOrElse(startIndex) { url } else url

        // Live is an endless, rolling HLS stream — caching it to disk is pointless
        // and causes segment-expiry errors, so live plays straight from the network.
        // VOD goes through a playback MODE chosen ONCE here (the single place the
        // multi-TV setting is read): OFF is the proven cache-backed direct stream
        // that holds the connection; ON reads only from disk while a single
        // background downloader owns the one connection and frees it between bursts.
        if (!isLive) {
            (application as XtreamApp).activeMediaUrl = playingUrl
            val app = application as XtreamApp
            // VOD streams through a CacheDataSource: it reads bytes already on disk
            // from the cache and fetches the rest from the server, writing them back
            // so a rewind or re-open is instant. The page's prefetcher warms the
            // resume region ahead of time, but the player is the authority once it
            // opens.
            vodMode = SharedConnectionMode(this, app, playingUrl)
        }
        // On a single-connection account the player must own that connection from its
        // very first byte. Stop every other network client BEFORE exo.prepare() rather
        // than after the player is already built: otherwise the still-running
        // prefetcher holds the one slot through the whole first-frame window, which is
        // what turned a warmed resume into a 30-second wait.
        if (!isLive) {
            try { (application as XtreamApp).aheadCache.stop() } catch (_: Exception) {}
            try { (application as XtreamApp).resumePrefetcher.pause() } catch (_: Exception) {}
        }
        val sourceFactory: DataSource.Factory =
            if (isLive) httpFactory() else vodMode!!.dataSourceFactory()
        val startPos = if (resumePosition > 0) maxOf(0L, resumePosition - 3000L)
            else androidx.media3.common.C.TIME_UNSET
        // The default LoadControl holds the first frame back until 2.5s of media is
        // buffered — a fixed delay that applies even when every byte is already on
        // disk, which is why a warmed resume still never felt instant. Start
        // rendering as soon as there is a little to show; keep the steady-state
        // buffer generous so playback stays smooth once it is running.
        val loadControl = androidx.media3.exoplayer.DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                /* minBufferMs = */ 20_000,
                /* maxBufferMs = */ 50_000,
                // Fast first frame, but not so eager that playback starts on fumes.
                // VOD reads from local disk, so the start threshold can be tiny:
                // the buffer refills orders of magnitude faster than realtime and
                // the only real wait left is decoder init.
                /* bufferForPlaybackMs = */ if (isLive) 1_000 else 250,
                // After a stall, refill properly. Resuming on 1.5s of video just
                // runs dry again, which is what turns one hiccup into a repeating
                // play-a-few-seconds / stop-a-few-seconds loop.
                /* bufferForPlaybackAfterRebufferMs = */ if (isLive) 3_000 else 5_000)
            // Cap the buffer by BYTES, not just time. Buffering 4K by duration alone
            // means ~300 MB of video in RAM on a 40 Mbps stream, which exhausts the
            // heap and turns playback into a GC stall — the buffer target must be a
            // memory budget on a device with 384 MB to work with.
            .setTargetBufferBytes(48 * 1024 * 1024)
            .setPrioritizeTimeOverSizeThresholds(false)
            .build()
        // Async codec queueing moves MediaCodec input/output handling off the playback
        // thread, which cuts frame-drop stutter on weak devices like this Chromecast.
        // Decoder fallback lets a flaky hardware decoder degrade to another decoder
        // instead of failing the whole stream.
        playerStartedAt = android.os.SystemClock.elapsedRealtime()
        val renderers = androidx.media3.exoplayer.DefaultRenderersFactory(this)
            .forceEnableMediaCodecAsynchronousQueueing()
            .setEnableDecoderFallback(true)
        player = ExoPlayer.Builder(this, renderers)
            .setMediaSourceFactory(DefaultMediaSourceFactory(sourceFactory))
            .setLoadControl(loadControl)
            .build().also { exo ->
            playerView.player = exo
            if (multiEpisode) {
                // Full-series playlist: powers ⏮/⏭ and rolls across seasons.
                exo.setMediaItems(epUrls.map { MediaItem.fromUri(it) }, startIndex, startPos)
                // Hold at each episode's end so the 8s "Up next" prompt can show
                // instead of jumping straight in.
                exo.pauseAtEndOfMediaItems = true
            } else {
                exo.setMediaItem(MediaItem.fromUri(url))
                if (startPos != androidx.media3.common.C.TIME_UNSET) exo.seekTo(startPos)
            }
            applySubtitlePref(exo) // remembered subtitle on/off + language
            exo.playWhenReady = true
            exo.addListener(object : Player.Listener {
                override fun onPlayerError(error: PlaybackException) = handlePlayerError(error)
                override fun onTrackSelectionParametersChanged(parameters: androidx.media3.common.TrackSelectionParameters) =
                    persistSubtitleChoice(parameters)
                override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                    updatePauseOverlay()
                    if (!playWhenReady) saveResume() // save the moment playback is paused
                }
                override fun onPlaybackStateChanged(state: Int) {
                    updatePauseOverlay()
                    if (state == Player.STATE_READY) {
                        liveRetries = 0 // healthy again: next outage starts from a short backoff
                        liveStalledSince = 0L
                    }
                    if (state == Player.STATE_ENDED) maybeShowNext()
                }
                override fun onMediaItemTransition(item: MediaItem?, reason: Int) = onEpisodeChanged()
                // Startup timing, read with:
                //   adb logcat -s XtreamPerf
                // so "is it faster?" is a measurement, not a feeling.
                override fun onRenderedFirstFrame() {
                    if (firstFrameLoggedAt == 0L) {
                        firstFrameLoggedAt = android.os.SystemClock.elapsedRealtime()
                        val ms = firstFrameLoggedAt - playerStartedAt
                        android.util.Log.i("XtreamPerf",
                            "first-frame ${ms}ms live=$isLive resume=${resumePosition > 0}")
                    }
                }
            })
            exo.prepare()
        }
        startPositionPolling()
        startPeriodicSave()
        startLiveWatchdog()
        // Hand the player to the chosen VOD mode. The shared-connection mode starts
        // the downloader, wires the connection notice, and mirrors the on-disk region
        // onto the seek bar; the direct-stream mode does nothing here.
        vodMode?.let { mode ->
            player?.let { mode.onPlayerReady(it) }
            startVodAheadTick(mode)
        }
    }

    /** VOD: report the play position to the current mode every few seconds. The
     *  shared-connection mode uses it to steer the downloader and refresh the
     *  loaded-region bar; the direct-stream mode ignores it. */
    private fun startVodAheadTick(mode: VodPlaybackMode) {
        val tick = object : Runnable {
            override fun run() {
                player?.let { mode.onPositionUpdate(it.currentPosition, it.duration.coerceAtLeast(0)) }
                aheadHandler.postDelayed(this, 5_000)
            }
        }
        aheadHandler.postDelayed(tick, 5_000)
    }

    /** Safety net: persist the resume position every minute while playing, with an
     *  early first checkpoint so leaving quickly still records progress. The write
     *  is debounced and runs off the UI thread, so this is effectively free. */
    private fun startPeriodicSave() {
        val tick = object : Runnable {
            override fun run() {
                saveResume()
                saveHandler.postDelayed(this, 60_000)
            }
        }
        saveHandler.postDelayed(tick, 15_000) // first checkpoint early, then every minute
    }

    /** Apply the remembered subtitle preference (on/off + language) to the player. */
    private fun applySubtitlePref(exo: ExoPlayer) {
        val (on, lang) = (application as XtreamApp).resume.subtitlePref()
        exo.trackSelectionParameters = exo.trackSelectionParameters.buildUpon()
            .setPreferredTextLanguage(if (on) lang.ifBlank { "en" } else null)
            .setTrackTypeDisabled(androidx.media3.common.C.TRACK_TYPE_TEXT, !on)
            .build()
    }

    /** Read the (enabled, language) subtitle choice from track-selection params. */
    private fun textPrefFrom(p: androidx.media3.common.TrackSelectionParameters): Pair<Boolean, String> {
        if (p.disabledTrackTypes.contains(androidx.media3.common.C.TRACK_TYPE_TEXT)) return false to ""
        for (group in p.overrides.keys) if (group.type == androidx.media3.common.C.TRACK_TYPE_TEXT && group.length > 0)
            return true to (group.getFormat(0).language ?: "")
        if (p.preferredTextLanguages.isNotEmpty()) return true to p.preferredTextLanguages[0]
        return false to ""
    }

    /** When the user changes subtitles (CC dialog), remember it for future videos. */
    private fun persistSubtitleChoice(params: androidx.media3.common.TrackSelectionParameters) {
        val (on, lang) = textPrefFrom(params)
        val store = (application as XtreamApp).resume
        if (store.subtitlePref() != (on to lang)) store.setSubtitlePref(on, lang)
    }

    /** HTTP source tuned for flaky IPTV servers: follow http/https redirects
     *  (Xtream often bounces to a CDN) and give slow segments time to arrive. */
    private fun httpFactory() = DefaultHttpDataSource.Factory()
        .setAllowCrossProtocolRedirects(true)
        .setConnectTimeoutMs(30_000)
        .setReadTimeoutMs(30_000)
        .setUserAgent("XtreamTV/1.0")

    /** Live streams drop segments and reset connections routinely; instead of
     *  bailing to the menu on every blip, jump back to the live edge and re-prepare.
     *  Live NEVER gives up — a channel left on for hours will hit more outages than
     *  any fixed retry budget allows, and giving up is what forced a manual back-and-
     *  reopen. Retries back off so a long outage doesn't hammer the server, and the
     *  counter resets as soon as playback is healthy again (see STATE_READY).
     *  VOD errors stay fatal (a broken file won't fix itself). */
    private fun handlePlayerError(error: PlaybackException) {
        val exo = player
        if (isLive && exo != null) {
            liveRetries++
            recoverLive(backoffMs())
            return
        }
        Toast.makeText(this, "Playback failed: ${error.errorCodeName}", Toast.LENGTH_LONG).show()
        finish()
    }

    /** 1.5s, 3s, 6s, 12s, then every 15s for as long as the outage lasts. */
    private fun backoffMs(): Long =
        minOf(15_000L, 1_500L * (1L shl minOf(liveRetries - 1, 3).coerceAtLeast(0)))

    /** Re-attach to the live edge after [delayMs]. */
    private fun recoverLive(delayMs: Long) {
        recoverHandler.removeCallbacksAndMessages(null)
        liveStalledSince = 0L
        recoverHandler.postDelayed({
            val p = player ?: return@postDelayed
            p.seekToDefaultPosition() // live edge
            p.prepare()
            p.playWhenReady = true
        }, delayMs)
    }

    /**
     * Watchdog for live streams that wedge WITHOUT reporting an error — the player
     * just sits buffering, or the position stops advancing, and nothing ever fires
     * [handlePlayerError]. That silent stall is the other way a long-running channel
     * "stops" until you back out and return, so re-attach to the live edge instead.
     */
    private fun startLiveWatchdog() {
        if (!isLive) return
        val tick = object : Runnable {
            override fun run() {
                val exo = player
                if (exo != null && exo.playWhenReady) {
                    val pos = exo.currentPosition
                    val stuck = exo.playbackState == Player.STATE_BUFFERING ||
                        (exo.playbackState == Player.STATE_READY && pos == lastLivePosition)
                    if (stuck) {
                        if (liveStalledSince == 0L) liveStalledSince = System.currentTimeMillis()
                        else if (System.currentTimeMillis() - liveStalledSince > 20_000) {
                            liveRetries++
                            recoverLive(0)
                        }
                    } else liveStalledSince = 0L
                    lastLivePosition = pos
                }
                liveWatchdogHandler.postDelayed(this, 2_000)
            }
        }
        liveWatchdogHandler.postDelayed(tick, 5_000)
    }

    /** Live channel up/down (dir -1 = previous, +1 = next), wrapping around. */
    private fun zapChannel(dir: Int) {
        val exo = player ?: return
        if (zapList.size < 2) return
        zapIndex = ((zapIndex + dir) % zapList.size + zapList.size) % zapList.size
        val ch = zapList[zapIndex]
        liveChannelId = ch.id
        liveRetries = 0
        // Show the new channel's last frame (if any) while it buffers.
        com.nirajgtm.xtreamtv.ui.PreviewCache.get(ch.id)?.let {
            livePlaceholder.setImageBitmap(it); livePlaceholder.visibility = android.view.View.VISIBLE
        } ?: run { livePlaceholder.visibility = android.view.View.GONE }
        playerView.hideController() // keep the bar hidden while zapping
        exo.setMediaItem(MediaItem.fromUri(ch.url))
        exo.prepare()
        exo.playWhenReady = true
        ovTitleView.text = ch.title
        (application as XtreamApp).resume.bumpPlay("live:${ch.id}")
        updateFavButton()
        showZapList()
    }

    /** Translucent left-side list: a few channels above/below the current one,
     *  current highlighted with a lazily-loaded "Now:" line. Auto-hides. */
    private fun showZapList() {
        if (zapList.isEmpty()) return
        val gen = ++bannerGen
        val resume = (application as XtreamApp).resume
        zapOverlay.removeAllViews()
        val radius = 3
        for (i in maxOf(0, zapIndex - radius)..minOf(zapList.size - 1, zapIndex + radius)) {
            val ch = zapList[i]
            val current = i == zapIndex
            val fav = if (resume.isFavorite(ch.id)) "♥ " else ""
            zapOverlay.addView(TextView(this).apply {
                text = "${i + 1}. $fav${ch.title}"
                textSize = if (current) 19f else 15f
                setTextColor(if (current) Color.WHITE else Color.parseColor("#9FB3C0"))
                setPadding(24, 12, 24, if (current) 2 else 12)
                maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END
                if (current) setBackgroundColor(Color.parseColor("#5980CBC4"))
            })
            if (current) {
                zapNowLine = TextView(this).apply {
                    text = "Now: …"; textSize = 13f
                    setTextColor(Color.parseColor("#CFE8E4")); setPadding(24, 0, 24, 12)
                    setBackgroundColor(Color.parseColor("#5980CBC4"))
                }
                zapOverlay.addView(zapNowLine)
            }
        }
        zapOverlay.visibility = android.view.View.VISIBLE
        bannerHandler.removeCallbacksAndMessages(null)
        bannerHandler.postDelayed({ if (gen == bannerGen) zapOverlay.visibility = android.view.View.GONE }, 4500)
        val ch = zapList[zapIndex]
        Thread {
            val epg = try { (application as XtreamApp).client.shortEpg(ch.id) } catch (_: Exception) { emptyList() }
            val now = epg.firstOrNull { it.nowPlaying } ?: epg.firstOrNull()
            runOnUiThread {
                if (gen == bannerGen && ::zapNowLine.isInitialized)
                    zapNowLine.text = if (now != null) "Now: ${now.title}" else "No guide"
            }
        }.start()
    }

    /** Star/unstar the channel currently playing (♥ button, Menu/Info, long-press OK). */
    private fun toggleLiveFavorite() {
        if (liveChannelId == 0L) return
        val nowFav = (application as XtreamApp).resume.toggleFavorite(liveChannelId)
        Toast.makeText(this, if (nowFav) "♥ Added to favorites" else "Removed from favorites",
            Toast.LENGTH_SHORT).show()
        updateFavButton()
        if (zapOverlay.visibility == android.view.View.VISIBLE) showZapList() // refresh ♥ marks
    }

    /** Give a button a bright-green border when focused (easy to spot on a TV). */
    private fun withFocusBorder(button: android.widget.Button) {
        fun bg(focused: Boolean) = android.graphics.drawable.GradientDrawable().apply {
            setColor(Color.parseColor("#E6008577"))
            cornerRadius = 12f
            if (focused) setStroke(6, Color.parseColor("#00E676"))
        }
        button.background = bg(false)
        button.setOnFocusChangeListener { _, hasFocus -> button.background = bg(hasFocus) }
    }

    /** Reflect the current channel's favorite state on the control-bar button. */
    private fun updateFavButton() {
        if (!isLive || !::favButton.isInitialized) return
        val fav = liveChannelId != 0L && (application as XtreamApp).resume.isFavorite(liveChannelId)
        favButton.text = if (fav) "♥ Favorited" else "♡ Favorite"
    }

    /** Soft top-anchored details panel shown while paused; never takes focus. */
    private fun buildPauseOverlay(): android.view.View {
        val poster = intent.getStringExtra("ovPoster") ?: ""
        val title = intent.getStringExtra("ovTitle") ?: (intent.getStringExtra("title") ?: "")
        val plot = intent.getStringExtra("ovPlot") ?: ""

        ovTitleView = TextView(this).apply { text = title; textSize = 30f; setTextColor(Color.WHITE) }
        ovMetaView = TextView(this).apply {
            textSize = 15f; setTextColor(Color.parseColor("#80CBC4")); setPadding(0, 8, 0, 8)
            text = intent.getStringExtra("ovYear") ?: ""
            visibility = if (text.isBlank()) android.view.View.GONE else android.view.View.VISIBLE
        }
        ovPlotView = TextView(this).apply {
            textSize = 16f; setTextColor(Color.parseColor("#DDE4E8"))
            maxLines = 6; ellipsize = android.text.TextUtils.TruncateAt.END; setLineSpacing(5f, 1f)
            text = plot
            visibility = if (text.isBlank()) android.view.View.GONE else android.view.View.VISIBLE
        }
        ovCastRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        ovCastScroll = android.widget.HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false; addView(ovCastRow)
            setPadding(0, 18, 0, 0); visibility = android.view.View.GONE
        }
        val text = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(ovTitleView); addView(ovMetaView); addView(ovPlotView); addView(ovCastScroll)
        }
        ovPosterView = ImageView(this).apply { scaleType = ImageView.ScaleType.FIT_CENTER }
        if (poster.isNotBlank()) ImageLoader.load(ovPosterView, poster, Color.parseColor("#00000000"))

        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(64, 56, 64, 24)
            addView(text, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            addView(ovPosterView, LinearLayout.LayoutParams(300, 440).apply { marginStart = 40 })
        }
        hasOverlayContent = title.isNotBlank()
        return FrameLayout(this).apply {
            isFocusable = false
            isClickable = false
            visibility = android.view.View.GONE
            background = android.graphics.drawable.GradientDrawable(
                android.graphics.drawable.GradientDrawable.Orientation.TOP_BOTTOM,
                intArrayOf(Color.parseColor("#E6101820"), Color.parseColor("#00101820")))
            addView(panel, FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP))
        }
    }

    private fun updatePauseOverlay() {
        if (!hasOverlayContent) return
        val exo = player ?: return
        val paused = !exo.playWhenReady &&
            (exo.playbackState == Player.STATE_READY || exo.playbackState == Player.STATE_ENDED)
        pauseOverlay.visibility = if (paused) android.view.View.VISIBLE else android.view.View.GONE
        if (paused) fetchDetailsOnce()
    }

    /** On first pause, fetch plot/cast/year (movie or episode) to enrich the panel. */
    @OptIn(UnstableApi::class)
    private fun fetchDetailsOnce() {
        if (detailsFetched) return
        val movieId = intent.getLongExtra("ovMovieId", 0L)
        val seriesId = intent.getLongExtra("ovSeriesId", 0L)
        if (movieId == 0L && seriesId == 0L) return
        detailsFetched = true
        val client = (application as XtreamApp).client
        Thread {
            var plot = ""; var meta = ""; var poster = ""
            var tmdbId = 0; var isSeries = false; var castNames = ""
            try {
                if (movieId != 0L) {
                    val info = client.movieInfo(movieId)
                    plot = info.plot; poster = info.poster
                    tmdbId = info.tmdbId; castNames = info.cast
                    meta = listOfNotNull(info.year.ifBlank { null }, info.genre.ifBlank { null })
                        .joinToString("   •   ")
                } else {
                    // Current episode's season/number (tracks playlist transitions).
                    val idx = player?.currentMediaItemIndex ?: 0
                    val season = if (multiEpisode) epSeasons.getOrElse(idx) { -1 } else intent.getIntExtra("ovSeason", -1)
                    val number = if (multiEpisode) epNums.getOrElse(idx) { -1 } else intent.getIntExtra("ovEpisode", -1)
                    val detail = client.seriesDetail(seriesId)
                    isSeries = true; tmdbId = detail.tmdbId; castNames = detail.cast
                    val ep = detail.episodes.firstOrNull { it.season == season && it.number == number }
                    val epTitle = com.nirajgtm.xtreamtv.data.cleanEpisodeTitle(ep?.title ?: "")
                    meta = listOfNotNull(
                        if (season >= 0 && number >= 0) "Season $season · Episode $number" else null,
                        epTitle.ifBlank { null },
                        ep?.durationSecs?.takeIf { it > 0 }?.let { "${it / 60} min" }
                    ).joinToString("   •   ")
                    plot = ep?.plot ?: "" // keep the HQ series cover already shown
                }
            } catch (_: Exception) {}
            // Cast headshots (main actors/characters) for the paused panel.
            val cast = try {
                if (tmdbId != 0) (application as XtreamApp).tmdb.castWithImages(tmdbId, isSeries) else emptyList()
            } catch (_: Exception) { emptyList() }
            runOnUiThread {
                if (plot.isNotBlank() && ovPlotView.text.isBlank()) {
                    ovPlotView.text = plot; ovPlotView.visibility = android.view.View.VISIBLE
                }
                if (meta.isNotBlank()) { ovMetaView.text = meta; ovMetaView.visibility = android.view.View.VISIBLE }
                if (poster.isNotBlank()) ImageLoader.load(ovPosterView, poster, Color.parseColor("#00000000"))
                ovCastRow.removeAllViews()
                if (cast.isNotEmpty()) {
                    cast.forEach { ovCastRow.addView(
                        com.nirajgtm.xtreamtv.ui.buildCastCard(this, it.name, it.character, it.profileUrl)) }
                    ovCastScroll.visibility = android.view.View.VISIBLE
                } else if (castNames.isNotBlank()) {
                    castNames.split(",").map { it.trim() }.filter { it.isNotEmpty() }
                        .forEach { ovCastRow.addView(com.nirajgtm.xtreamtv.ui.buildCastCard(this, it, "", "")) }
                    ovCastScroll.visibility = android.view.View.VISIBLE
                }
            }
        }.start()
    }

    /**
     * For VOD, the first D-pad press just reveals the playback controls (with
     * play/pause focused) — it doesn't seek. Once the controls are up, keys go to
     * them (forward/rewind/scrub). Live keeps its own up/down channel zapping.
     */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val exo = player ?: return super.dispatchKeyEvent(event)
        if (event.action == KeyEvent.ACTION_DOWN) {
            // While the "up next" prompt shows, OK plays it now.
            if (advancePending && (event.keyCode == KeyEvent.KEYCODE_DPAD_CENTER ||
                    event.keyCode == KeyEvent.KEYCODE_ENTER)) {
                playNext(); return true
            }
            // "Play next episode" button showing: OK plays next; a direction dismisses
            // it and brings up the playback controls (play/pause focused).
            if (nextButton.visibility == android.view.View.VISIBLE) when (event.keyCode) {
                KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER -> { playNext(); return true }
                KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT,
                KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_DPAD_DOWN -> {
                    nextButton.visibility = android.view.View.GONE
                    nextButtonDismissed = true
                    playerView.showController()
                    return true
                }
            }
            // Live TV: up/down ALWAYS change channel and never surface the controls
            // (press OK or left/right for those). Hide the bar if it happens to be up.
            if (isLive && zapList.size > 1) when (event.keyCode) {
                KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_CHANNEL_UP -> { playerView.hideController(); zapChannel(-1); return true }
                KeyEvent.KEYCODE_DPAD_DOWN, KeyEvent.KEYCODE_CHANNEL_DOWN -> { playerView.hideController(); zapChannel(+1); return true }
            }
            // Menu/Info: options (audio/aspect) for VOD, favorite toggle for live.
            if (event.keyCode == KeyEvent.KEYCODE_MENU || event.keyCode == KeyEvent.KEYCODE_INFO) {
                if (isLive) toggleLiveFavorite() else showOptions()
                return true
            }
            // Long-press OK favorites the live channel (Chromecast remote has no
            // Menu button); a normal OK press still toggles play/controls.
            if (isLive && event.isLongPress &&
                (event.keyCode == KeyEvent.KEYCODE_DPAD_CENTER || event.keyCode == KeyEvent.KEYCODE_ENTER)) {
                toggleLiveFavorite(); return true
            }
            // Remotes with dedicated skip keys jump episodes directly.
            if (multiEpisode) when (event.keyCode) {
                KeyEvent.KEYCODE_MEDIA_NEXT -> { playNext(); return true }
                KeyEvent.KEYCODE_MEDIA_PREVIOUS -> { playPrevious(); return true }
            }
        }
        // Any transport action (OK/seek/skip) checkpoints the position, so leaving
        // right after interacting never loses progress.
        if (!isLive && event.action == KeyEvent.ACTION_UP) when (event.keyCode) {
            KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER,
            KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT,
            KeyEvent.KEYCODE_MEDIA_PLAY, KeyEvent.KEYCODE_MEDIA_PAUSE,
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.KEYCODE_MEDIA_REWIND,
            KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> saveResume()
        }
        // VOD: any D-pad/OK press with the controls hidden just brings them up
        // (play/pause focused) instead of acting; the next press uses them.
        if (!isLive && event.action == KeyEvent.ACTION_DOWN && !playerView.isControllerFullyVisible) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT,
                KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_DPAD_DOWN,
                KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER -> {
                    playerView.showController(); return true
                }
            }
        }
        return super.dispatchKeyEvent(event)
    }

    /** Edge-to-edge immersive: no status/navigation bars, video fills the screen. */
    @Suppress("DEPRECATION")
    private fun goFullscreen() {
        window.decorView.systemUiVisibility = (
            android.view.View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                or android.view.View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                or android.view.View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                or android.view.View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or android.view.View.SYSTEM_UI_FLAG_FULLSCREEN
                or android.view.View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) goFullscreen() // re-assert after the system may have reset it
    }

    override fun onPause() {
        super.onPause()
        captureLiveFrame() // stash the last frame so the channel list can show it
    }

    /** Copy the current live frame into the 5-min preview cache (surface still up). */
    @OptIn(UnstableApi::class)
    private fun captureLiveFrame() {
        if (!isLive || liveChannelId == 0L || android.os.Build.VERSION.SDK_INT < 24) return
        val surface = playerView.videoSurfaceView as? android.view.SurfaceView ?: return
        try {
            val bmp = android.graphics.Bitmap.createBitmap(320, 180, android.graphics.Bitmap.Config.ARGB_8888)
            val id = liveChannelId
            android.view.PixelCopy.request(surface, bmp, { result ->
                if (result == android.view.PixelCopy.SUCCESS)
                    com.nirajgtm.xtreamtv.ui.PreviewCache.put(id, bmp)
            }, Handler(Looper.getMainLooper()))
        } catch (_: Exception) {}
    }

    // ---- Episode navigation (playlist: ⏮/⏭, 1-min button, end-of-episode prompt) ----

    /** True while there's a following episode/season to advance into. */
    private fun hasNext(): Boolean = player?.hasNextMediaItem() == true

    /** End-of-episode "Up next" prompt with an 8s countdown, then auto-advance. */
    private fun maybeShowNext() {
        if (!hasNext()) return
        val idx = player?.currentMediaItemIndex ?: return
        advancePending = true
        nextButton.visibility = android.view.View.GONE
        nextPrompt.text = "Up next: ${epTitles.getOrElse(idx + 1) { "Next episode" }}\nPlaying in 8s   ·   OK to play now   ·   Back to stay"
        nextPrompt.visibility = android.view.View.VISIBLE
        advanceHandler.removeCallbacksAndMessages(null)
        advanceHandler.postDelayed({ playNext() }, 8000)
    }

    /** Advance to the next episode now (from the prompt, the 1-min button, or ⏭). */
    private fun playNext() {
        val exo = player ?: return
        if (!exo.hasNextMediaItem()) return
        advancePending = false
        advanceHandler.removeCallbacksAndMessages(null)
        nextPrompt.visibility = android.view.View.GONE
        nextButton.visibility = android.view.View.GONE
        exo.seekToNextMediaItem()
        exo.playWhenReady = true
    }

    private fun playPrevious() {
        val exo = player ?: return
        if (!exo.hasPreviousMediaItem()) return
        nextButton.visibility = android.view.View.GONE
        exo.seekToPreviousMediaItem()
        exo.playWhenReady = true
    }

    /** On an episode change, refresh resume key, title, plot, and history. */
    private fun onEpisodeChanged() {
        val exo = player ?: return
        if (!multiEpisode) return
        val idx = exo.currentMediaItemIndex
        if (idx !in epUrls.indices) return
        advancePending = false
        advanceHandler.removeCallbacksAndMessages(null)
        nextPrompt.visibility = android.view.View.GONE
        nextButton.visibility = android.view.View.GONE
        // Move the fill onto the episode now playing (and re-arm for the one after
        // it). Without this the fetcher keeps filling the finished episode while
        // the new one streams off the network.
        val app = application as XtreamApp
        app.activeMediaUrl = epUrls[idx]
        vodMode?.onEpisodeSwitched(epUrls[idx])
        prefetchedForIndex = -1
        nextUpRecorded = false
        nextButtonDismissed = false
        resumeKey = epKeys.getOrNull(idx)
        val title = epTitles.getOrElse(idx) { "" }
        ovTitleView.text = title
        ovPlotView.text = epPlots.getOrElse(idx) { "" }
        detailsFetched = false
        val poster = intent.getStringExtra("ovPoster") ?: ""
        resumeKey?.let {
            (application as XtreamApp).resume.remember(it, title, poster, "series", epUrls[idx],
                seriesId = intent.getLongExtra("ovSeriesId", 0L),
                seriesName = title.substringBefore("  S").trim(),
                season = epSeasons.getOrElse(idx) { 0 }, episodeNum = epNums.getOrElse(idx) { 0 })
        }
    }

    /** Poll playback position; surface the "Play next episode" button in the
     *  last minute of a series episode when a next one exists. */
    private fun startPositionPolling() {
        if (!multiEpisode) return
        val tick = object : Runnable {
            override fun run() {
                val exo = player
                if (exo != null) {
                    val dur = exo.duration
                    val pos = exo.currentPosition
                    // Offer "Play next episode" in the last 2 minutes (unless dismissed).
                    val inWindow = dur > 0 && pos >= dur - 120_000L && pos < dur - 1_000L
                    val show = inWindow && hasNext() && !advancePending && !nextButtonDismissed
                    if (show && nextButton.visibility != android.view.View.VISIBLE) {
                        nextButton.visibility = android.view.View.VISIBLE
                        nextButton.requestFocus() // preselect it: OK plays next
                    } else if (!show && !advancePending && nextButton.visibility == android.view.View.VISIBLE)
                        nextButton.visibility = android.view.View.GONE
                    // Under 2 min left: start pulling the next episode's head down.
                    if (dur > 0 && pos >= dur - 120_000L && hasNext()) prefetchNext()
                    // Once under 2 min left, this episode counts as finished: queue
                    // the next one into Continue Watching (this one drops off there).
                    if (dur > 0 && pos >= dur - 120_000L && hasNext() && !nextUpRecorded) {
                        recordNextUp(); nextUpRecorded = true
                    }
                }
                positionHandler.postDelayed(this, 1000)
            }
        }
        positionHandler.postDelayed(tick, 1000)
    }

    /** Queue the next episode into Continue Watching (so the finished one drops off). */
    private fun recordNextUp() {
        val exo = player ?: return
        val nIdx = exo.currentMediaItemIndex + 1
        if (nIdx !in epUrls.indices) return
        val title = epTitles.getOrElse(nIdx) { "" }
        val key = epKeys.getOrElse(nIdx) { return }
        (application as XtreamApp).resume.rememberNextUp(
            key = key, title = title, poster = intent.getStringExtra("ovPoster") ?: "",
            playUrl = epUrls[nIdx], seriesId = intent.getLongExtra("ovSeriesId", 0L),
            seriesName = title.substringBefore("  S").trim(),
            season = epSeasons.getOrElse(nIdx) { 0 }, episodeNum = epNums.getOrElse(nIdx) { 0 },
            now = System.currentTimeMillis())
    }

    /**
     * Hand the next episode to the ahead-cache so its head is on disk before the
     * switch. It goes through the same fetcher as everything else deliberately:
     * one component owns the single connection, keeps every request a complete
     * closed range, and keeps the long idle gaps. The old version opened its own
     * unbounded stream alongside playback, which on a one-connection account is
     * precisely what makes the provider refuse everything.
     */
    private fun prefetchNext() {
        val exo = player ?: return
        val nextIdx = exo.currentMediaItemIndex + 1
        if (nextIdx !in epUrls.indices || prefetchedForIndex == nextIdx) return
        prefetchedForIndex = nextIdx
        vodMode?.queueNextEpisode(epUrls[nextIdx])
    }

    /** Back hides the controls first when they're showing; a second Back exits. */
    override fun onBackPressed() {
        when {
            advancePending -> { // cancel auto-advance, stay on the finished episode
                advancePending = false
                advanceHandler.removeCallbacksAndMessages(null)
                nextPrompt.visibility = android.view.View.GONE
            }
            nextButton.visibility == android.view.View.VISIBLE -> { // first Back hides it
                nextButton.visibility = android.view.View.GONE
                nextButtonDismissed = true
            }
            playerView.isControllerFullyVisible -> playerView.hideController()
            else -> super.onBackPressed()
        }
    }

    // ---- Options: audio track + aspect ratio ----

    @OptIn(UnstableApi::class)
    private fun showOptions() {
        val exo = player ?: return
        val audioGroups = exo.currentTracks.groups.filter {
            it.type == androidx.media3.common.C.TRACK_TYPE_AUDIO && it.isSupported
        }
        val labels = ArrayList<String>()
        audioGroups.forEach { g ->
            val f = g.mediaTrackGroup.getFormat(0)
            val lang = f.language ?: "und"
            labels.add("Audio: ${f.label ?: lang}${if (g.isSelected) "  ✓" else ""}")
        }
        val fillOn = playerView.resizeMode == androidx.media3.ui.AspectRatioFrameLayout.RESIZE_MODE_ZOOM
        labels.add(if (fillOn) "Aspect: Fill  ✓" else "Aspect: Fit → switch to Fill")
        android.app.AlertDialog.Builder(this)
            .setTitle("Options")
            .setItems(labels.toTypedArray()) { _, which ->
                if (which < audioGroups.size) {
                    exo.trackSelectionParameters = exo.trackSelectionParameters.buildUpon()
                        .setOverrideForType(androidx.media3.common.TrackSelectionOverride(
                            audioGroups[which].mediaTrackGroup, 0)).build()
                } else {
                    playerView.resizeMode = if (fillOn)
                        androidx.media3.ui.AspectRatioFrameLayout.RESIZE_MODE_FIT
                    else androidx.media3.ui.AspectRatioFrameLayout.RESIZE_MODE_ZOOM
                }
            }
            .show()
    }

    private fun nextSeekStepMs(): Long {
        val now = System.currentTimeMillis()
        seekStreak = if (now - lastSeekPressMs < 800) seekStreak + 1 else 0
        lastSeekPressMs = now
        val multiplier = 1L shl minOf(seekStreak / 2, 4) // 1,1,2,2,4,4,8,8,16,16...
        return 15_000L * multiplier
    }

    private fun seekBy(exo: ExoPlayer, deltaMs: Long) {
        val duration = exo.duration
        val target = (exo.currentPosition + deltaMs)
            .coerceIn(0L, if (duration > 0) duration else Long.MAX_VALUE)
        exo.seekTo(target)
        val sign = if (deltaMs >= 0) "+" else "-"
        val step = kotlin.math.abs(deltaMs) / 1000
        seekIndicator.text = "$sign${step}s   ${formatTime(target)}"
        seekIndicator.visibility = android.view.View.VISIBLE
        indicatorHandler.removeCallbacksAndMessages(null)
        indicatorHandler.postDelayed({
            seekIndicator.visibility = android.view.View.GONE
        }, 900)
    }

    private fun formatTime(ms: Long): String {
        val totalSeconds = ms / 1000
        val hours = totalSeconds / 3600
        val minutes = (totalSeconds % 3600) / 60
        val seconds = totalSeconds % 60
        return if (hours > 0) "%d:%02d:%02d".format(hours, minutes, seconds)
        else "%d:%02d".format(minutes, seconds)
    }

    override fun onStop() {
        super.onStop()
        saveResume()
        markCurrentWarmed() // playback already cached this item to disk -> instant on return
        (application as XtreamApp).resume.flushNow() // durable write before we may be reclaimed
        indicatorHandler.removeCallbacksAndMessages(null)
        advanceHandler.removeCallbacksAndMessages(null)
        positionHandler.removeCallbacksAndMessages(null)
        recoverHandler.removeCallbacksAndMessages(null)
        liveWatchdogHandler.removeCallbacksAndMessages(null)
        aheadHandler.removeCallbacksAndMessages(null)
        // Leave the fill running: returning to the title should not re-download,
        // and the next episode's page will switch it over anyway. Only stop
        // reporting to a window that is going away - resetting the position here
        // would send the fetcher back to the start of the film.
        vodMode?.release()
        bannerHandler.removeCallbacksAndMessages(null)
        saveHandler.removeCallbacksAndMessages(null)
        // Protect whatever is still on screen: leaving the player does not mean
        // the title is finished with, and a paused show must keep its bytes.
        val app = application as XtreamApp
        val keep = setOfNotNull(app.activeMediaUrl.ifBlank { null })
        app.background.submit { app.cacheJanitor.sweep(keep) }
        player?.release()
        player = null
        finish()
    }

    /**
     * Mirror the downloaded region onto the seek bar. ExoPlayer only shows its own
     * in-memory buffer as the pale "loaded" section; the on-disk download runs far
     * ahead of that, and the viewer should see how much is safely banked.
     */
    // Refreshed by the 5s tick; applied on every controller redraw. The controller
    // repaints the bar each second with ExoPlayer's own (much smaller) in-memory
    // buffer, so setting ours on a slower timer made the loaded section flicker in
    // and out - it must be re-applied after every repaint, from a cached value.
    @Volatile private var loadedUpToMs = 0L

    private fun updateLoadedIndicator() {
        try {
            loadedUpToMs = (application as XtreamApp).aheadCache.downloadedUpToMs()
            applyLoadedIndicator()
        } catch (_: Exception) { /* cosmetic only - never disturb playback */ }
    }

    private fun applyLoadedIndicator() {
        try {
            val ms = loadedUpToMs
            if (ms <= 0) return
            val bar = playerView.findViewById<androidx.media3.ui.DefaultTimeBar>(
                androidx.media3.ui.R.id.exo_progress) ?: return
            if (ms > (player?.bufferedPosition ?: 0)) bar.setBufferedPosition(ms)
        } catch (_: Exception) {}
    }

    /** Re-assert the loaded region after each controller repaint. */
    private fun hookProgressUpdates() {
        try {
            val controller = playerView.findViewById<androidx.media3.ui.PlayerControlView>(
                androidx.media3.ui.R.id.exo_controller) ?: return
            controller.setProgressUpdateListener { _, _ -> applyLoadedIndicator() }
        } catch (_: Exception) {}
    }

    /**
     * Tell the viewer the account's connection limit is the reason nothing is
     * downloading - but only when it can actually reach them. With a deep cushion
     * on disk a refused top-up changes nothing they can see, and an alarming
     * banner over a film playing perfectly well is worse than saying nothing.
     */
    private fun showConnectionNotice(attempt: Int, bankedSeconds: Long) {
        val exo = player
        val stalled = exo != null && exo.playWhenReady &&
            exo.playbackState == Player.STATE_BUFFERING
        if (bankedSeconds > 120 && !stalled) return          // invisible to them: stay quiet
        val limit = (application as XtreamApp).client.maxConnections
        val counts = if (limit > 0) " ($limit/$limit)" else ""
        connectionNotice.text = "Connection limit reached$counts. Another device is using " +
            "the connection.\nRetrying automatically (retry $attempt). Playback continues " +
            "as soon as the connection frees up."
        connectionNotice.visibility = android.view.View.VISIBLE
    }

    private fun hideConnectionNotice() { connectionNotice.visibility = android.view.View.GONE }

    private fun saveResume() {
        val key = resumeKey ?: return
        val exo = player ?: return
        val position = exo.currentPosition
        val duration = exo.duration.takeIf { it > 0 } ?: 0L
        if (position <= 0) return
        (application as XtreamApp).resume.save(key, position, duration, System.currentTimeMillis())
    }

    /** VOD only: playback streams through the disk cache, so the bytes at our stop
     *  point are already on disk. Tell the prefetcher so it protects them instead of
     *  re-fetching when we land back on home. */
    private fun markCurrentWarmed() {
        if (isLive) return
        val exo = player ?: return
        val uri = exo.currentMediaItem?.localConfiguration?.uri?.toString() ?: return
        if (exo.currentPosition > 0) (application as XtreamApp).resumePrefetcher.markWarmed(uri, exo.currentPosition)
    }

    // ---- VOD playback modes ----
    //
    // How ExoPlayer gets its bytes for a movie/episode. There are two strategies and
    // the choice (the multi-TV setting) is made exactly once in onCreate; from then on
    // PlayerActivity only calls the mode's methods, so no `if (multiTvMode)` is
    // scattered through playback. Live is not a VodPlaybackMode - it always streams
    // straight from the network and is handled separately.

    /** Base strategy: shared behaviour lives here, mode-specific behaviour is overridden. */
    @OptIn(UnstableApi::class)
    abstract class VodPlaybackMode(
        protected val activity: PlayerActivity,
        protected val app: XtreamApp,
        protected val playingUrl: String
    ) {
        /** How ExoPlayer obtains bytes for this title. */
        abstract fun dataSourceFactory(): DataSource.Factory
        /** Player built and prepared; wire up anything that needs it. */
        open fun onPlayerReady(player: ExoPlayer) {}
        /** Periodic (~5s) play-position report while VOD is on screen. */
        open fun onPositionUpdate(positionMs: Long, durationMs: Long) {}
        /** The playlist moved to another episode ([url] now playing). */
        open fun onEpisodeSwitched(url: String) {}
        /** The next episode is coming up; get its head ready if appropriate. */
        open fun queueNextEpisode(url: String) {}
        /** The player is going away. */
        open fun release() {}
    }

    /**
     * How every VOD title plays: the player streams straight from the server and
     * reads any bytes that are already on disk from the cache, writing what it
     * fetches back so a rewind or a re-open is instant. This is the only path that
     * starts a cold title in a second or two - a player detached from the network
     * can do nothing but wait for a background downloader to feed it byte by byte,
     * which on a single connection is minutes, not seconds.
     *
     * The page's pre-open prefetch (DetailActivity) fills the same cache with the
     * resume region before Play is pressed, so resuming lands on already-cached
     * bytes. Once playback starts the background downloader is stopped: the player
     * is now the app's one network client for VOD, so the two never compete.
     */
    @OptIn(UnstableApi::class)
    class SharedConnectionMode(
        activity: PlayerActivity, app: XtreamApp, playingUrl: String
    ) : VodPlaybackMode(activity, app, playingUrl) {

        override fun dataSourceFactory(): DataSource.Factory =
            CacheDataSource.Factory()
                .setCache(app.videoCache)
                .setUpstreamDataSourceFactory(activity.httpFactory())
                .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)

        override fun onPlayerReady(player: ExoPlayer) {
            // The player owns the connection now; silence every other network client
            // so none can contend for the single slot the account allows. Both calls
            // abort any in-flight request immediately, not after a read-timeout.
            try { app.aheadCache.stop() } catch (_: Exception) {}
            try { app.resumePrefetcher.pause() } catch (_: Exception) {}
        }

        override fun onEpisodeSwitched(url: String) {
            try { app.aheadCache.stop() } catch (_: Exception) {}
            try { app.resumePrefetcher.pause() } catch (_: Exception) {}
        }

        override fun release() {
            app.aheadCache.listener = null
        }
    }
}
