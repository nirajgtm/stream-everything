package com.nirajgtm.xtreamtv.ui

import android.app.Activity
import android.graphics.Color
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import com.nirajgtm.xtreamtv.data.Episode
import com.nirajgtm.xtreamtv.data.ResumeStore
import com.nirajgtm.xtreamtv.data.TmdbClient

/** Apple TV-style episode card: 16:9 thumbnail (+ progress), number, title, plot, runtime. */
fun buildEpisodeCard(activity: Activity, episode: Episode, meta: TmdbClient.EpisodeMeta?,
                     store: ResumeStore, onClick: () -> Unit): View {
    val cardW = 380; val thumbW = 340; val thumbH = 191 // 16:9 thumbnail inside padded card
    // Prefer TMDB name/overview/still/runtime; fall back to provider data.
    val titleText = meta?.name?.takeIf { it.isNotBlank() } ?: "Episode ${episode.number}"
    val descText = meta?.overview?.takeIf { it.isNotBlank() } ?: episode.plot
    val stillUrl = meta?.still?.takeIf { it.isNotBlank() } ?: episode.thumb
    val runtimeMin = meta?.runtimeMin?.takeIf { it > 0 } ?: (episode.durationSecs / 60)
    val thumb = ImageView(activity).apply {
        scaleType = ImageView.ScaleType.CENTER_CROP
        setBackgroundColor(Color.parseColor("#1A2029"))
    }
    val frac = store.watchedFraction("ep:${episode.id}")
    val bar = View(activity).apply {
        setBackgroundColor(Color.parseColor("#80CBC4"))
        if (frac <= 0.02f) visibility = View.GONE
    }
    val thumbFrame = android.widget.FrameLayout(activity).apply {
        clipToOutline = true
        outlineProvider = object : android.view.ViewOutlineProvider() {
            override fun getOutline(v: View, o: android.graphics.Outline) =
                o.setRoundRect(0, 0, v.width, v.height, 22f)
        }
        addView(thumb, android.widget.FrameLayout.LayoutParams(thumbW, thumbH))
        addView(bar, android.widget.FrameLayout.LayoutParams(
            (thumbW * frac).toInt(), 8, Gravity.BOTTOM or Gravity.START))
    }
    ImageLoader.load(thumb, stillUrl, Color.parseColor("#1A2029"), maxDim = 380)
    val epNum = TextView(activity).apply {
        text = "EPISODE ${episode.number}"; textSize = 11.5f; letterSpacing = 0.06f
        setTextColor(Color.parseColor("#8A93A0")); setPadding(2, 14, 2, 2)
    }
    val epTitle = TextView(activity).apply {
        text = titleText
        textSize = 17f; setTextColor(Color.WHITE)
        setTypeface(typeface, android.graphics.Typeface.BOLD)
        maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END; setPadding(2, 0, 2, 0)
    }
    val epDesc = TextView(activity).apply {
        text = descText; textSize = 13f; setTextColor(Color.parseColor("#AEB8C2"))
        setLineSpacing(4f, 1f); maxLines = 2; ellipsize = android.text.TextUtils.TruncateAt.END
        setPadding(2, 6, 2, 0)
        visibility = if (descText.isBlank()) View.GONE else View.VISIBLE
    }
    val epRuntime = TextView(activity).apply {
        text = if (runtimeMin > 0) "▶  ${runtimeMin}m" else "▶  Play"
        textSize = 13f; setTextColor(Color.parseColor("#AEB8C2")); setPadding(2, 10, 2, 0)
    }
    // Reliable focus border via a state-list drawable (auto-shows on focus).
    val focusedBg = android.graphics.drawable.GradientDrawable().apply {
        cornerRadius = 26f; setColor(Color.parseColor("#2A3540")); setStroke(7, Color.WHITE)
    }
    val normalBg = android.graphics.drawable.GradientDrawable().apply {
        cornerRadius = 26f; setColor(Color.TRANSPARENT)
    }
    val bg = android.graphics.drawable.StateListDrawable().apply {
        addState(intArrayOf(android.R.attr.state_focused), focusedBg)
        addState(intArrayOf(), normalBg)
    }
    return LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        isFocusable = true; isFocusableInTouchMode = true
        layoutParams = LinearLayout.LayoutParams(cardW, ViewGroup.LayoutParams.WRAP_CONTENT)
            .apply { marginEnd = 30 }
        setPadding(10, 10, 10, 10)
        background = bg
        addView(thumbFrame, LinearLayout.LayoutParams(thumbW, thumbH))
        addView(epNum); addView(epTitle); addView(epDesc); addView(epRuntime)
        setOnClickListener { onClick() }
        // NOTE: never bringToFront() here — in a LinearLayout it reorders the
        // child list, which physically relays out the focused card to the end
        // (scrambling episode order) and breaks D-pad traversal ("sticks" on
        // the same card). The 30px gap already prevents scale overlap.
        setOnFocusChangeListener { v, f ->
            v.animate().scaleX(if (f) 1.07f else 1f).scaleY(if (f) 1.07f else 1f).setDuration(140).start()
        }
    }
}
