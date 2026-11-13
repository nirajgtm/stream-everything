package com.nirajgtm.xtreamtv.data

/**
 * Hides adult titles from search, Live TV, hubs and rails. On by default.
 *
 * Tuned against the whole catalogue (181k movies / 57k channels / 48k series), and
 * the tiering is the point: a single broad word list blocks ~370 legitimate titles
 * ("Masters of Sex", "Cougar Town", "Young Adult", "Striptease", a radio format
 * called ADULT ALTERNATIVE, and a UFC card featuring a fighter named Hooker).
 *
 *  - [CONTEXT] is the provider's own marker. Every adult movie is named "XXX - ..."
 *    and every adult channel "ADULT: ...", so anchoring to the start is exact —
 *    and it leaves "NF - xXx: Return of Xander Cage" alone, which has a language
 *    prefix first.
 *  - [HARD] terms effectively never occur in mainstream titles, so one is enough.
 *  - [SOFT] terms occur constantly in mainstream titles, so one means nothing;
 *    two different ones together is the signal.
 *  - [ALLOW] covers the handful the rules still get wrong, mostly the xXx films
 *    and documentaries *about* the industry.
 */
object AdultFilter {

    // A word boundary rather than a separator, so decorated names like
    // "####### ADULT ᴿᴬᵂ #######" are caught too. Legitimate titles never *open*
    // with these markers; the ones that come close are covered by [ALLOW].
    private val CONTEXT = Regex("""^\s*[#*\s]*(XXX|ADULT)(?!\s*SWIM)\b""", RegexOption.IGNORE_CASE)

    private val HARD = Regex(
        """(^|[^a-z])(""" +
        """xxx|pr0n|hentai|creampie|blowjob|cumshot|handjob|gangbang|bukkake|""" +
        """deepthroat|fisting|footjob|titjob|rimjob|squirting|""" +
        """brazzers|dorcel|evilangel|bangbros|naughty\s*america|realitykings|mofos|""" +
        """twistys|sextreme|dogfart|pornhub|xhamster|redtube|youporn|""" +
        """hustler\s*tv|playboy\s*tv|penthouse\s*tv|vivid\s*tv|private\s*tv|redlight|""" +
        """camgirl|chaturbate|camsoda|""" +
        """hardcore\s*(sex|porn)|softcore|porno|""" +
        """anal\s|anal$|bdsm|bondage\s*porn|fetish\s*(porn|model)""" +
        """)([^a-z]|$)""", RegexOption.IGNORE_CASE)

    private val SOFT = Regex(
        """(^|[^a-z])(""" +
        """sex|sexy|sexo|sesso|seks|sexe|porn|adult|erotic|erotik|erotique|""" +
        """nude|nudist|naked|topless|stripper|striptease|strip\s*club|""" +
        """fetish|kink|taboo|voyeur|swinger|orgy|orgasm|escort|hooker|""" +
        """boobs|tits|pussy|horny|onlyfans|18\+|21\+|hardcore|playboy|penthouse|hustler""" +
        """)([^a-z]|$)""", RegexOption.IGNORE_CASE)

    /**
     * Titles the rules misjudge. Two groups: the xXx action franchise (every
     * language variant), and documentaries/comedies *about* the industry. The
     * racier mainstream reality shows (MILF Manor, Extreme Cougar Wives, X-Rated
     * Queen...) are deliberately allowed through too — they are ordinary TV.
     */
    private val ALLOW = listOf(
        // xXx franchise
        "xander cage", "triple x", "xxx 2:", "xxx2", "xxx²", "xxx: state of the union",
        "xxx - il ritorno", "xxx: o regresso", "estado de emergencia", "xxx (2002)",
        "xxx: the next level", "xxx 2: the next level",
        // documentaries and comedies about the industry
        "my dad wrote a porno", "money shot: the pornhub story", "my dead dad's porno tapes",
        "porno y helado", "hardcore: no submundo", "after porn ends", "hippy porn",
        "the hentai prince", "x-rated queen", "porn king", "thinking xxx",
        "historia de pornhub", "make a porno", "bdsm en vaerld",
        // racy-but-mainstream reality/TV
        "milf manor", "milf of norway", "extreme cougar wives", "cougar town",
        "milf - ferien", "milf (2018)", "aspirational slut", "fifty shades of fetish model",
        "the escort", "escort boys", "secret escort", "escort in love", "cougar hunting",
        "adult swim", "adult-swim", "adult alternative", "adult animation",
        "adult material", "young adult", "adult best friends", "adult life skills"
    )

    /**
     * "NF - xXx", "FR - xXx : Reactivated" — the action franchise. It always sits
     * behind a language prefix, whereas an adult title *opens* with its XXX marker,
     * so the prefix is what tells them apart without listing every translation.
     */
    private val FRANCHISE = Regex("""^[A-Za-z0-9+\-]{1,6}\s*-\s*xxx\b""", RegexOption.IGNORE_CASE)

    private fun allowed(name: String): Boolean {
        if (FRANCHISE.containsMatchIn(name.trim())) return true
        val lower = name.lowercase()
        return ALLOW.any { lower.contains(it) }
    }

    /**
     * Cheap pre-screen. Every rule below needs one of these fragments somewhere in
     * the title, so a plain substring scan rejects the overwhelming majority of the
     * catalogue without allocating a Matcher. This matters: the search loop runs
     * over hundreds of thousands of entries.
     */
    private val MARKERS = arrayOf(
        "xxx", "adult", "porn", "sex", "seks", "sesso", "sexe", "sexo", "erot",
        "nude", "nudist", "naked", "topless", "strip", "hardcore", "softcore",
        "milf", "cougar", "slut", "whore", "anal", "bdsm", "bondage", "fetish",
        "kink", "taboo", "voyeur", "swinger", "orgy", "orgasm", "escort", "hooker",
        "boobs", "tits", "pussy", "horny", "onlyfans", "18+", "21+", "hentai",
        "creampie", "blowjob", "cumshot", "handjob", "gangbang", "bukkake",
        "deepthroat", "fisting", "footjob", "titjob", "rimjob", "squirt",
        "brazzers", "dorcel", "evilangel", "bangbros", "naughty", "realitykings",
        "mofos", "twistys", "sextreme", "dogfart", "xhamster", "redtube", "youporn",
        "hustler", "playboy", "penthouse", "vivid", "private", "redlight",
        "camgirl", "chaturbate", "camsoda", "pr0n", "x-rated", "xrated"
    )

    /** True when [name] (the raw provider title) should be hidden. */
    fun isAdult(name: String): Boolean {
        if (name.isBlank()) return false
        val lower = name.lowercase()
        if (MARKERS.none { lower.contains(it) }) return false // fast path: no regex
        if (allowed(name)) return false // exceptions win over every rule below
        if (CONTEXT.containsMatchIn(name)) return true
        if (HARD.containsMatchIn(name)) return true
        // A soft word alone is meaningless; two distinct ones is the signal.
        val soft = HashSet<String>(4)
        for (m in SOFT.findAll(name)) {
            soft.add(m.groupValues[2].lowercase())
            if (soft.size >= 2) return true
        }
        return false
    }

    /** Whole categories named for adult content ("FOR ADULTS"). */
    fun isAdultCategory(categoryName: String): Boolean {
        val lower = categoryName.lowercase().trim()
        if (lower.contains("adult swim") || lower.contains("adult-swim")) return false
        return lower == "for adults" || lower.startsWith("xxx") ||
            lower.startsWith("adult") || lower.contains("porn")
    }
}
