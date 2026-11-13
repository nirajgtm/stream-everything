package com.nirajgtm.xtreamtv.ui

import android.content.Context
import android.graphics.Color
import android.graphics.Rect
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView

/** Extra detail shown when a card is focused for a moment (the hover preview). */
class ExpandData(
    val title: String,
    val year: String,
    val isSeries: Boolean,
    val overview: String,
    val loadCast: () -> String
)

/**
 * An ImageView whose box never depends on its image. Swapping the image then only
 * repaints; the stock view asks for a layout pass, and on home that means
 * re-measuring every card on every rail each time a poster arrives or is released.
 */
private class FixedSizeImageView(context: Context) : ImageView(context) {
    private var swappingImage = false
    override fun setImageDrawable(drawable: android.graphics.drawable.Drawable?) {
        swappingImage = true
        try { super.setImageDrawable(drawable) } finally { swappingImage = false }
    }
    override fun requestLayout() { if (!swappingImage) super.requestLayout() }
}

/**
 * A rail card: a poster with a title. When focused for ~2s it expands to the
 * right into a wide panel showing the title, year, plot, and cast — like a peek
 * at the detail screen without leaving the row.
 */
class RailCard(context: Context) : LinearLayout(context) {
    private val poster: ImageView = FixedSizeImageView(context).apply { scaleType = ImageView.ScaleType.CENTER_CROP }
    private val label = TextView(context).apply {
        setTextColor(Color.WHITE); textSize = 13f; maxLines = 2; setPadding(4, 6, 4, 0)
    }
    private val progressBar = android.widget.ProgressBar(
        context, null, android.R.attr.progressBarStyleHorizontal).apply {
        max = 100
        visibility = GONE
        progressTintList = android.content.res.ColorStateList.valueOf(Color.parseColor("#80CBC4"))
        secondaryProgressTintList = android.content.res.ColorStateList.valueOf(Color.parseColor("#59FFFFFF"))
    }
    private val posterCol = LinearLayout(context).apply {
        orientation = VERTICAL
        addView(poster, LayoutParams(220, 320))
        addView(progressBar, LayoutParams(220, 8))
        addView(label, LayoutParams(220, LayoutParams.WRAP_CONTENT))
    }

    /** Watched (teal) + downloaded (translucent) under the poster; hidden if neither. */
    fun setProgress(fraction: Float, prefetched: Float = 0f) {
        progressBar.secondaryProgress = (prefetched.coerceIn(0f, 1f) * 100).toInt()
        if (fraction !in 0.001f..1f && prefetched > 0.001f) {
            progressBar.progress = 0
            progressBar.visibility = VISIBLE
            return
        }
        if (fraction > 0.01f && fraction < 0.99f) {
            progressBar.progress = (fraction * 100).toInt()
            progressBar.visibility = VISIBLE
        } else progressBar.visibility = GONE
    }

    private val detailTitle = TextView(context).apply {
        setTextColor(Color.WHITE); textSize = 18f; setPadding(0, 0, 0, 6)
    }
    private val detailMeta = TextView(context).apply {
        setTextColor(Color.parseColor("#80CBC4")); textSize = 13f; setPadding(0, 0, 0, 8)
    }
    private val detailOverview = TextView(context).apply {
        setTextColor(Color.parseColor("#CCD6DD")); textSize = 14f; maxLines = 8
        ellipsize = android.text.TextUtils.TruncateAt.END; setLineSpacing(4f, 1f)
    }
    private val detailCast = TextView(context).apply {
        setTextColor(Color.parseColor("#99A6B0")); textSize = 13f; setPadding(0, 10, 0, 0)
    }
    private val detailPanel = LinearLayout(context).apply {
        orientation = VERTICAL
        setPadding(24, 6, 12, 6)
        visibility = GONE
        addView(detailTitle); addView(detailMeta); addView(detailOverview); addView(detailCast)
    }

    private var expand: ExpandData? = null
    private var castLoaded = false
    private val handler = Handler(Looper.getMainLooper())
    private val expandRunnable = Runnable { expandCard() }

    init {
        orientation = HORIZONTAL
        isFocusable = true
        isFocusableInTouchMode = false
        setPadding(10, 10, 10, 10)
        addView(posterCol)
        addView(detailPanel, LayoutParams(480, LayoutParams.WRAP_CONTENT))
        setOnFocusChangeListener { _, focused ->
            background = GradientDrawable().apply {
                cornerRadius = 12f
                setColor(Color.parseColor(if (focused) "#22303C" else "#00000000"))
                if (focused) setStroke(4, Color.parseColor("#80CBC4"))
            }
            handler.removeCallbacks(expandRunnable)
            if (focused && expand != null) handler.postDelayed(expandRunnable, 2000)
            else collapse()
        }
    }

    fun bind(title: String, posterUrl: String?) {
        label.text = title
        setImage(posterUrl, Color.parseColor("#22303C"))
    }

    // Rails are plain rows, not recycling lists, so every card on home exists at
    // once. A card therefore holds its bitmap only while its RailRow says it is on
    // or near the screen; hundreds of off-screen posters kept in memory is what got
    // the app killed in the background on a 2 GB device.
    private var imageUrl: String? = null
    private var imageColor = 0
    private var imageShown = false

    private fun setImage(url: String?, placeholderColor: Int) {
        imageUrl = url
        imageColor = placeholderColor
        imageShown = false
        ImageLoader.clear(poster)
        poster.setBackgroundColor(placeholderColor)
        (parent as? RailRow)?.scheduleImageCheck()
    }

    /** Called by the owning [RailRow] as the card moves near to or away from the screen. */
    fun showImage(near: Boolean) {
        val url = imageUrl ?: return
        if (near && !imageShown) {
            imageShown = true
            ImageLoader.load(poster, url, imageColor)
        } else if (!near && imageShown) {
            imageShown = false
            ImageLoader.clear(poster)
        }
    }

    fun setExpand(data: ExpandData?) {
        expand = data
        castLoaded = false
        collapse()
    }

    private fun expandCard() {
        val e = expand ?: return
        detailTitle.text = e.title
        detailMeta.text = listOfNotNull(
            e.year.ifBlank { null }, if (e.isSeries) "Series" else "Movie").joinToString("  ·  ")
        detailOverview.text = e.overview.ifBlank { "No description available." }
        if (!castLoaded) {
            detailCast.text = "Cast: …"
            castLoaded = true
            Thread {
                val cast = e.loadCast()
                handler.post { detailCast.text = if (cast.isNotBlank()) "Cast: $cast" else "" }
            }.start()
        }
        detailPanel.visibility = VISIBLE
        post { requestRectangleOnScreen(Rect(0, 0, width, height), false) }
    }

    private fun collapse() {
        handler.removeCallbacks(expandRunnable)
        detailPanel.visibility = GONE
    }

    /** Landscape tile bound to a bundled drawable (Live TV language tiles). */
    fun bindTile(title: String, drawableRes: Int) {
        label.text = title
        poster.layoutParams = LayoutParams(360, 202)
        poster.scaleType = ImageView.ScaleType.FIT_CENTER
        poster.setBackgroundColor(Color.parseColor("#0B0F14"))
        imageUrl = null
        poster.setImageResource(drawableRes)
        label.layoutParams = LayoutParams(360, LayoutParams.WRAP_CONTENT)
    }

    /** Landscape tile from a generated typography bitmap (no bundled image). */
    fun bindArt(bitmap: android.graphics.Bitmap) {
        label.text = ""
        poster.layoutParams = LayoutParams(360, 202)
        poster.scaleType = ImageView.ScaleType.FIT_XY
        imageUrl = null
        poster.setImageBitmap(bitmap)
    }

    /** Provider logo entry card (landscape, dark, FIT), loaded from a URL. */
    fun bindLogo(caption: String, logoUrl: String?) {
        label.text = caption
        poster.layoutParams = LayoutParams(300, 202)
        poster.scaleType = ImageView.ScaleType.FIT_CENTER
        poster.setPadding(28, 28, 28, 28)
        poster.setBackgroundColor(Color.parseColor("#0B0F14"))
        setImage(logoUrl, Color.parseColor("#0B0F14"))
        label.layoutParams = LayoutParams(300, LayoutParams.WRAP_CONTENT)
    }
}

/**
 * The row of cards inside a rail. Decides, once per rail rather than once per card,
 * which cards are close enough to the screen to hold their image.
 */
class RailRow(context: Context) : LinearLayout(context) {
    private val handler = Handler(Looper.getMainLooper())
    private var checkPending = false
    private var anyShown = false
    private val at = IntArray(2)
    private val checkRunnable = Runnable { checkPending = false; updateImages() }
    private val onScroll = android.view.ViewTreeObserver.OnScrollChangedListener { scheduleImageCheck() }
    private val onLayout = android.view.ViewTreeObserver.OnGlobalLayoutListener { scheduleImageCheck() }

    init { orientation = HORIZONTAL }

    fun scheduleImageCheck() {
        if (checkPending) return
        checkPending = true
        handler.postDelayed(checkRunnable, 80)
    }

    private fun updateImages() {
        val metrics = resources.displayMetrics
        val marginX = metrics.widthPixels / 2
        val marginY = metrics.heightPixels / 2
        var railNear = isAttachedToWindow && isShown && windowVisibility == VISIBLE
        if (railNear) {
            getLocationOnScreen(at)
            railNear = at[1] + height > -marginY && at[1] < metrics.heightPixels + marginY
        }
        if (!railNear && !anyShown) return
        anyShown = false
        for (i in 0 until childCount) {
            val card = getChildAt(i) as? RailCard ?: continue
            val x = at[0] + card.left
            val near = railNear && x + card.width > -marginX && x < metrics.widthPixels + marginX
            card.showImage(near)
            if (near) anyShown = true
        }
    }

    override fun onViewAdded(child: View?) { super.onViewAdded(child); scheduleImageCheck() }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        viewTreeObserver.addOnScrollChangedListener(onScroll)
        viewTreeObserver.addOnGlobalLayoutListener(onLayout)
        scheduleImageCheck()
    }

    override fun onDetachedFromWindow() {
        viewTreeObserver.removeOnScrollChangedListener(onScroll)
        viewTreeObserver.removeOnGlobalLayoutListener(onLayout)
        handler.removeCallbacks(checkRunnable)
        checkPending = false
        for (i in 0 until childCount) (getChildAt(i) as? RailCard)?.showImage(false)
        anyShown = false
        super.onDetachedFromWindow()
    }

    override fun onWindowVisibilityChanged(visibility: Int) {
        super.onWindowVisibilityChanged(visibility)
        scheduleImageCheck()   // another screen (e.g. the player) is in front: let go
    }
}

/** Builds a labeled horizontal rail; [bindCard] fills each card by index. */
fun buildRail(
    context: Context,
    title: String,
    count: Int,
    bindCard: (RailCard, Int) -> Unit,
    onClick: (Int) -> Unit,
    leadTitle: String? = null,
    leadPosterUrl: String? = null,
    leadOnClick: (() -> Unit)? = null,
    onLongClick: ((Int) -> Boolean)? = null,
    expandFor: ((Int) -> ExpandData?)? = null
): View {
    val header = TextView(context).apply {
        text = title
        textSize = 18f
        setTextColor(Color.parseColor("#CCD6DD"))
        setPadding(24, 20, 24, 8)
    }
    val row = RailRow(context).apply { setPadding(14, 0, 14, 0) }
    if (leadOnClick != null) {
        val lead = RailCard(context)
        lead.bindLogo(leadTitle ?: "Browse ›", leadPosterUrl)
        lead.setOnClickListener { leadOnClick() }
        row.addView(lead)
    }
    for (i in 0 until count) {
        val card = RailCard(context)
        bindCard(card, i)
        if (expandFor != null) card.setExpand(expandFor(i))
        card.setOnClickListener { onClick(i) }
        if (onLongClick != null) card.setOnLongClickListener { onLongClick(i) }
        row.addView(card)
    }
    val scroller = HorizontalScrollView(context).apply {
        isHorizontalScrollBarEnabled = false
        addView(row)
    }
    return LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        addView(header)
        addView(scroller)
    }
}
