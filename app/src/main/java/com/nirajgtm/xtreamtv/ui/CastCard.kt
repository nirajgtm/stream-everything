package com.nirajgtm.xtreamtv.ui

import android.content.Context
import android.graphics.Color
import android.graphics.Outline
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView

/** Apple TV-style cast tile: a circular headshot with the actor + character name. */
fun buildCastCard(context: Context, name: String, character: String, profileUrl: String): View {
    val img = ImageView(context).apply {
        scaleType = ImageView.ScaleType.CENTER_CROP
        setBackgroundColor(Color.parseColor("#22303C"))
        clipToOutline = true
        outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(view: View, outline: Outline) =
                outline.setOval(0, 0, view.width, view.height)
        }
        if (profileUrl.isNotBlank()) ImageLoader.load(this, profileUrl, Color.parseColor("#22303C"))
    }
    val nameView = TextView(context).apply {
        text = name; textSize = 12f; setTextColor(Color.WHITE)
        maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END
        gravity = Gravity.CENTER_HORIZONTAL; setPadding(0, 8, 0, 0)
    }
    val charView = TextView(context).apply {
        text = character; textSize = 11f; setTextColor(Color.parseColor("#8195A2"))
        maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END
        gravity = Gravity.CENTER_HORIZONTAL
        visibility = if (character.isBlank()) View.GONE else View.VISIBLE
    }
    return LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER_HORIZONTAL
        setPadding(0, 0, 28, 0)
        addView(img, LinearLayout.LayoutParams(150, 150))
        addView(nameView, LinearLayout.LayoutParams(150, ViewGroup.LayoutParams.WRAP_CONTENT))
        addView(charView, LinearLayout.LayoutParams(150, ViewGroup.LayoutParams.WRAP_CONTENT))
    }
}
