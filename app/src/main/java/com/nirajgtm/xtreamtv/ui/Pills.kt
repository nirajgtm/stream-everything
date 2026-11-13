package com.nirajgtm.xtreamtv.ui

import android.content.Context
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.BackgroundColorSpan
import android.text.style.ForegroundColorSpan
import android.text.style.RelativeSizeSpan
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import com.nirajgtm.xtreamtv.data.Pill

/** A horizontal strip of colored pill chips (for the detail screen). */
fun pillStrip(context: Context, pills: List<Pill>): LinearLayout {
    val row = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        setPadding(0, 12, 0, 12)
    }
    for (pill in pills) {
        val chip = TextView(context).apply {
            text = pill.text
            textSize = 13f
            setTextColor(Color.WHITE)
            setPadding(20, 8, 20, 8)
            background = Squircle(Color.parseColor(pill.color))
        }
        row.addView(chip, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginEnd = 12 })
    }
    return row
}

/**
 * Inline pills appended to a single-line list row as colored text spans (the
 * result list uses a plain TextView per row, so real chip views aren't an
 * option there).
 */
fun appendInlinePills(builder: SpannableStringBuilder, pills: List<Pill>) {
    for (pill in pills) {
        builder.append("  ")
        val start = builder.length
        builder.append(" ${pill.text} ")
        val flags = Spanned.SPAN_EXCLUSIVE_EXCLUSIVE
        builder.setSpan(BackgroundColorSpan(Color.parseColor(pill.color)), start, builder.length, flags)
        builder.setSpan(ForegroundColorSpan(Color.WHITE), start, builder.length, flags)
        builder.setSpan(RelativeSizeSpan(0.8f), start, builder.length, flags)
    }
}
