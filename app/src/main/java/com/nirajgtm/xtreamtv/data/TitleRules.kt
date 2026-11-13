package com.nirajgtm.xtreamtv.data

/**
 * Human-readable dictionaries for the acronyms and tags that appear in title
 * prefixes, derived from a frequency analysis of the whole catalog. Editable by
 * hand: add a code here and it becomes a readable pill everywhere. Unknown codes
 * pass through as-is so new content stays visible.
 */
object TitleRules {

    // Region/language codes seen as title prefixes -> readable label.
    val languages: Map<String, String> = mapOf(
        "EN" to "English", "AR" to "Arabic", "DE" to "German", "FR" to "French",
        "IN" to "Hindi", "GR" to "Greek", "IR" to "Persian", "ES" to "Spanish",
        "AL" to "Albanian", "PT" to "Portuguese", "NL" to "Dutch", "SE" to "Swedish",
        "TR" to "Turkish", "IT" to "Italian", "PL" to "Polish", "RU" to "Russian",
        "RO" to "Romanian", "BG" to "Bulgarian", "IL" to "Hebrew", "PH" to "Filipino",
        "TL" to "Tagalog", "KU" to "Kurdish", "SO" to "Somali", "MM" to "Burmese",
        "EG" to "Egyptian", "DK" to "Danish", "KH" to "Khmer", "NO" to "Norwegian",
        "BE" to "Belgian", "QC" to "Québécois", "MA" to "Moroccan", "FI" to "Finnish",
        "CZ" to "Czech", "HU" to "Hungarian", "HR" to "Croatian", "RS" to "Serbian",
        "UA" to "Ukrainian", "VN" to "Vietnamese", "TH" to "Thai", "ID" to "Indonesian",
        "MY" to "Malay", "KR" to "Korean", "JP" to "Japanese", "CN" to "Chinese",
        "TW" to "Taiwanese", "HK" to "Cantonese", "US" to "American", "GB" to "British",
        "CA" to "Canadian", "AU" to "Australian", "MX" to "Mexican", "BR" to "Brazilian",
        "PK" to "Pakistani", "BD" to "Bengali", "LK" to "Sri Lankan", "NP" to "Nepali"
    )

    // Streaming source / network codes -> readable label + brand color.
    val sources: Map<String, Pair<String, String>> = mapOf(
        "NF" to ("Netflix" to "#E50914"),
        "AMZ" to ("Prime Video" to "#00A8E1"),
        "AMZN" to ("Prime Video" to "#00A8E1"),
        "D+" to ("Disney+" to "#113CCF"),
        "DSNY" to ("Disney+" to "#113CCF"),
        "A+" to ("Apple TV+" to "#7D7D7D"),
        "ATV" to ("Apple TV+" to "#7D7D7D"),
        "HBO" to ("HBO Max" to "#8E44AD"),
        "MAX" to ("HBO Max" to "#8E44AD"),
        "HULU" to ("Hulu" to "#1CE783"),
        "PMT" to ("Paramount+" to "#0064FF"),
        "P+" to ("Paramount+" to "#0064FF"),
        "PCK" to ("Peacock" to "#FA6400"),
        "TOP" to ("New Release" to "#F5A623"),
        "4KTOP" to ("New Release" to "#F5A623")
    )

    // Content/audio hints -> readable label.
    val hints: Map<String, String> = mapOf(
        "SUBS" to "Subtitles", "SUB" to "Subtitles", "DUB" to "Dubbed",
        "MULTI" to "Multi-audio", "ANM" to "Anime", "DOC" to "Documentary",
        "KIDS" to "Kids", "XXX" to "Adult", "VIP" to "VIP", "SOC" to "Soccer",
        "SPORT" to "Sport", "SC" to "Sport"
    )

    // Quality/format codes (including unicode superscript variants) -> readable label.
    val quality: Map<String, String> = mapOf(
        "4K" to "4K", "UHD" to "4K", "ᵁᴴᴰ" to "4K", "FHD" to "FHD", "HD" to "HD",
        "SD" to "SD", "RAW" to "RAW", "ᴿᴬᵂ" to "RAW", "HDR" to "HDR", "HEVC" to "HEVC",
        "DV" to "Dolby Vision", "3D" to "3D", "IMAX" to "IMAX"
    )

    // Provider's own brand tag and pure decoration to drop silently.
    val dropTokens: Set<String> = setOf("SHAM", "EX", "S", "B", "D", "AS")

    // Pill palette for categories without a brand color.
    const val COLOR_LANGUAGE = "#4A6FA5"
    const val COLOR_QUALITY = "#B8860B"
    const val COLOR_HINT = "#2E8B78"
    const val COLOR_YEAR = "#556677"
}
