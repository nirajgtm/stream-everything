package com.nirajgtm.xtreamtv.data

/** Live channel categories detected from keywords in the name. */
enum class LiveCategory(val label: String, val keywords: List<String>) {
    SPORTS("Sports", listOf("SPORT", "SOCCER", "FOOTBALL", "NBA", "NFL", "UFC", "F1",
        "CRICKET", "GOLF", "TENNIS", "RUGBY", "BOXING", "HOCKEY", "BASEBALL")),
    NEWS("News", listOf("NEWS", "CNN", "BBC", "FOX", "ALJAZEERA")),
    MOVIES("Movies", listOf("CINEMA", "MOVIE", "FILM")),
    KIDS("Kids", listOf("KIDS", "CARTOON", "DISNEY", "NICK", "BABY")),
    MUSIC("Music", listOf("MUSIC", "MTV", "RADIO", "HITS")),
    DOCS("Docs", listOf("DOCU", " DOC", "HISTORY", "NATURE", "DISCOVERY", "NAT GEO", "GEO")),
    GENERAL("General", emptyList());

    companion object {
        fun of(name: String): LiveCategory {
            val upper = name.uppercase()
            for (cat in listOf(SPORTS, NEWS, MOVIES, KIDS, MUSIC, DOCS)) {
                if (cat.keywords.any { upper.contains(it) }) return cat
            }
            return GENERAL
        }
    }
}

/**
 * Buckets live channels into language groups from their region-code prefix
 * (US/UK/IN/NP/...). English, Hindi, and Nepali come first by request; the rest
 * are alphabetical. Filters the Arabic-script channels that the provider
 * mislabels under NP:.
 */
object LiveCatalog {

    // Region code -> (language/bucket label). Grouped so several regions can
    // share one bucket (US/UK/CA all -> English).
    private val regionToBucket: Map<String, String> = buildMap {
        // English split by region (plain "English" was too broad to navigate).
        put("US", "English US"); put("USA", "English US")
        put("UK", "English UK"); put("GB", "English UK"); put("IE", "English UK")
        put("CA", "English CA")
        put("AU", "English AU/NZ"); put("NZ", "English AU/NZ")
        put("EN", "English")
        for (r in listOf("IN", "HINDI", "INDIA", "DESI")) put(r, "Hindi")
        for (r in listOf("NP", "NEPAL", "NEPALI")) put(r, "Nepali")
        put("AR", "Arabic"); put("FR", "French"); put("DE", "German"); put("IT", "Italian")
        put("TR", "Turkish"); put("NL", "Dutch"); put("ES", "Spanish"); put("GR", "Greek")
        put("AL", "Albanian"); put("BE", "Belgian"); put("SE", "Swedish"); put("IR", "Persian")
        put("IL", "Hebrew"); put("RU", "Russian"); put("HR", "Croatian"); put("BG", "Bulgarian")
        put("DK", "Danish"); put("PH", "Filipino"); put("NO", "Norwegian"); put("BR", "Brazilian")
        put("RS", "Serbian"); put("FI", "Finnish"); put("PT", "Portuguese"); put("CZ", "Czech")
        put("MX", "Mexican"); put("PL", "Polish"); put("RO", "Romanian"); put("HU", "Hungarian")
        put("UA", "Ukrainian"); put("VN", "Vietnamese"); put("TH", "Thai"); put("ID", "Indonesian")
        put("MY", "Malay"); put("KR", "Korean"); put("JP", "Japanese"); put("CN", "Chinese")
        put("PK", "Pakistani"); put("BD", "Bengali"); put("LK", "Sri Lankan"); put("EG", "Egyptian")
        put("MA", "Moroccan"); put("AT", "Austrian"); put("CH", "Swiss")
        // Indian languages that carry their own prefix.
        put("HINDI", "Hindi"); put("TAMIL", "Tamil"); put("TELUGU", "Telugu")
        put("MARATHI", "Marathi"); put("GUJARATI", "Gujarati"); put("PUNJABI", "Punjabi")
        put("BENGALI", "Bengali"); put("KANNADA", "Kannada"); put("MALAYALAM", "Malayalam")
        put("BHOJPURI", "Bhojpuri"); put("ODIA", "Odia"); put("ASSAMESE", "Assamese")
        put("URDU", "Urdu"); put("AFR", "African"); put("EXYU", "Ex-Yugoslav")
    }

    private val regionPrefix = Regex("^\\s*([A-Za-z]{2,12})\\s*[:|]")
    private val arabicScript = Regex("[\\u0600-\\u06FF]")

    /**
     * The region code from the channel's PREFIX only (before the first : or |).
     * A prefix-only match avoids false hits like "Men IN Black" landing in Hindi.
     */
    fun regionOf(name: String): String? {
        val code = regionPrefix.find(name)?.groupValues?.get(1)?.uppercase() ?: return null
        return if (regionToBucket.containsKey(code)) code else null
    }

    fun bucketOf(name: String): String {
        val region = regionOf(name) ?: return "Other"
        val bucket = regionToBucket[region] ?: "Other"
        // Drop Arabic-script channels mislabeled under NP: from the Nepali bucket.
        if (bucket == "Nepali" && arabicScript.containsMatchIn(name)) return "Arabic"
        return bucket
    }

    data class Group(val label: String, val channels: List<Entry>)

    /**
     * Tag-based lists that cut across languages (a channel can match several).
     * Used to pull items out of the huge English/Other buckets and browse by
     * type or sport instead of region.
     */
    data class SmartList(val label: String, val keys: List<String>) {
        fun matches(upperName: String): Boolean = keys.any { upperName.contains(it) }
    }

    val smartLists: List<SmartList> = listOf(
        SmartList("Live Events", listOf("EVENT")),
        SmartList("PPV", listOf("PPV")),
        SmartList("24/7 Movies & Series", listOf("24/7", "24-7")),
        SmartList("📰 News", listOf("NEWS", "CNN", "ALJAZEERA", "AL JAZEERA", "MSNBC",
            "EURONEWS", "SKY NEWS", "FOX NEWS", "GB NEWS", "CNBC", "BLOOMBERG")),
        SmartList("🎬 Movies", listOf("CINEMA", "MOVIE", " FILM", "CINE ", "PELICULA")),
        SmartList("🎞 Documentary", listOf("DOCU", " DOC ", "HISTORY", "DISCOVERY",
            "NAT GEO", "NATGEO", "NATURE", "ANIMAL PLANET")),
        SmartList("🧸 Kids", listOf("KIDS", "DISNEY", "NICK", "BABY", "JUNIOR")),
        SmartList("🍥 Anime", listOf("ANIME", "CRUNCHYROLL", "TOONAMI", "MANGA")),
        SmartList("✏ Animation", listOf("ANIMATION", "CARTOON", "ANIMATED", "TOONS")),
        SmartList("🎵 Music", listOf("MUSIC", "MTV", "VEVO", " HITS", "RADIO")),
        SmartList("⚽ Soccer", listOf("SOCCER", "FOOTBALL", "FUTBOL", "CALCIO", " LIGA",
            "LALIGA", "PREMIER LEAGUE", "UEFA", "CHAMPIONS LEAGUE", "EUROPA", "SERIE A",
            "BUNDESLIGA", "LIGUE 1", "EREDIVISIE", "MLS", "EPL", "FA CUP", "CONMEBOL")),
        SmartList("🏀 Basketball", listOf("BASKETBALL", "NBA", "EUROLEAGUE")),
        SmartList("🏈 American Football", listOf("NFL", "AMERICAN FOOTBALL", "SUPER BOWL")),
        SmartList("🥊 Boxing & MMA", listOf("BOXING", "UFC", " MMA", "BELLATOR", "WBC", " FIGHT")),
        SmartList("🤼 Wrestling", listOf("WWE", "WRESTL", "AEW", " NXT")),
        SmartList("🏏 Cricket", listOf("CRICKET", " IPL", " BBL", " PSL", " T20")),
        SmartList("🎾 Tennis", listOf("TENNIS", " ATP", " WTA", "WIMBLEDON", "ROLAND")),
        SmartList("⛳ Golf", listOf("GOLF", " PGA", "RYDER")),
        SmartList("🏎 Motorsport", listOf("FORMULA", "MOTOGP", "NASCAR", "RACING", "MOTORSPORT", " F1")),
        SmartList("🏒 Hockey", listOf("HOCKEY", " NHL")),
        SmartList("⚾ Baseball", listOf("BASEBALL", " MLB"))
    )

    /** Channels (across all languages) matching a smart list. */
    fun channelsFor(live: List<Entry>, smart: SmartList): List<Entry> =
        live.filter { smart.matches(it.name.uppercase()) && !hidden(it) }

    /** Adult titles are filtered out of every browse surface, not just search. */
    private fun hidden(entry: Entry): Boolean = adultFilterOn && entry.adult

    /** Set by the app from Settings; regrouping is forced when it changes. */
    @Volatile var adultFilterOn: Boolean = true
        set(value) { if (field != value) { field = value; cachedGroups = null }; }

    @Volatile private var cachedGroups: List<Group>? = null

    /** Drop the memoized grouping (the catalogue was replaced, e.g. account switch). */
    @Synchronized
    fun invalidate() { cachedGroups = null }

    /** Ordered language groups: English, Hindi, Nepali, then alphabetical. Cached. */
    @Synchronized
    fun group(live: List<Entry>): List<Group> {
        cachedGroups?.let { return it }
        if (live.isEmpty()) return emptyList()
        val byBucket = LinkedHashMap<String, MutableList<Entry>>()
        for (channel in live) {
            if (hidden(channel)) continue
            byBucket.getOrPut(bucketOf(channel.name)) { mutableListOf() }.add(channel)
        }
        // Biggest languages first (no hardcoded priority); "Other" always last.
        val ordered = ArrayList<Group>()
        byBucket.entries
            .filter { it.key != "Other" }
            .sortedByDescending { it.value.size }
            .forEach { ordered.add(Group(it.key, it.value)) }
        byBucket["Other"]?.let { ordered.add(Group("Other", it)) }
        cachedGroups = ordered
        return ordered
    }
}
