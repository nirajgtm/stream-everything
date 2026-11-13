package com.nirajgtm.xtreamtv.data

/** A pill to render after a title: readable text + background color. */
data class Pill(val text: String, val color: String)

/** A title split into a clean display name plus readable pills. */
data class ParsedTitle(
    val clean: String,
    val year: String?,
    val pills: List<Pill>
)

/**
 * Turns a raw provider title like "4K-NF - Mousetrap (2026) (KR)" into a clean
 * name ("Mousetrap") plus readable pills (Netflix, 4K, 2026, Korean). Unknown
 * prefix tokens are kept in the title so nothing silently disappears.
 */
object TitleParser {

    private val yearRegex = Regex("\\((19|20)\\d{2}\\)")
    private val trailingCountry = Regex("\\(([A-Z]{2})\\)\\s*$")
    private val leadingQualityColon = Regex("(?i)^\\s*(4K|UHD|FHD|HD|SD|RAW)\\s*:\\s*")
    private val superscriptJunk = Regex("[³⁸⁴⁰ᴾᴺᴹ]+")
    private val decorations = Regex("#{2,}|▶|★|●|•")

    fun parse(raw: String): ParsedTitle {
        var work = raw
        val pills = LinkedHashMap<String, Pill>() // dedupe by text, keep order

        // Superscript quality marks (live): ᵁᴴᴰ, ᴿᴬᵂ -> pills, then strip below.
        for ((mark, label) in listOf("ᵁᴴᴰ" to "4K", "ᴿᴬᵂ" to "RAW")) {
            if (work.contains(mark)) {
                addPill(pills, label, TitleRules.COLOR_QUALITY)
                work = work.replace(mark, " ")
            }
        }

        // Leading "4K:" style quality prefix (live channels).
        leadingQualityColon.find(work)?.let { match ->
            val q = TitleRules.quality[match.groupValues[1].uppercase()]
            if (q != null) addPill(pills, q, TitleRules.COLOR_QUALITY)
            work = work.removeRange(match.range).trim()
        }

        // Trailing country code, e.g. "... (KR)".
        trailingCountry.find(work)?.let { match ->
            TitleRules.languages[match.groupValues[1]]?.let {
                addPill(pills, it, TitleRules.COLOR_LANGUAGE)
            }
            work = work.removeRange(match.range).trim()
        }

        // Year, e.g. "(2026)".
        var year: String? = null
        yearRegex.find(work)?.let { match ->
            year = match.value.trim('(', ')')
            addPill(pills, year!!, TitleRules.COLOR_YEAR)
        }

        // Prefix tag segments before the main title, split on " - " / "|".
        val parts = work.split(Regex("\\s*[-|]\\s*"))
        if (parts.size > 1) {
            var consumed = 0
            for (part in parts.dropLast(1)) {
                if (!classifyPrefix(part.trim(), pills)) break
                consumed++
            }
            if (consumed > 0) work = parts.drop(consumed).joinToString(" - ")
        }

        // Final cleanup: drop the year from the title, then decoration/whitespace.
        work = yearRegex.replaceFirst(work, "")
        work = decorations.replace(work, " ")
        work = superscriptJunk.replace(work, " ")
        work = work.replace(Regex("\\s{2,}"), " ").trim(' ', '-', ':', '|', '.', '·', '–')

        return ParsedTitle(work.ifEmpty { raw.trim() }, year, pills.values.toList())
    }

    /** Try to read one prefix chunk as tags; return true if it was fully tags. */
    private fun classifyPrefix(chunk: String, pills: LinkedHashMap<String, Pill>): Boolean {
        if (chunk.isEmpty() || chunk.length > 8) return false
        val token = chunk.uppercase()
        return when {
            TitleRules.quality.containsKey(token) -> {
                addPill(pills, TitleRules.quality.getValue(token), TitleRules.COLOR_QUALITY); true
            }
            TitleRules.sources.containsKey(token) -> {
                val (label, color) = TitleRules.sources.getValue(token)
                addPill(pills, label, color); true
            }
            TitleRules.languages.containsKey(token) -> {
                addPill(pills, TitleRules.languages.getValue(token), TitleRules.COLOR_LANGUAGE); true
            }
            TitleRules.hints.containsKey(token) -> {
                addPill(pills, TitleRules.hints.getValue(token), TitleRules.COLOR_HINT); true
            }
            TitleRules.dropTokens.contains(token) -> true // drop silently
            else -> false
        }
    }

    private fun addPill(pills: LinkedHashMap<String, Pill>, text: String, color: String) {
        pills.putIfAbsent(text, Pill(text, color))
    }
}
