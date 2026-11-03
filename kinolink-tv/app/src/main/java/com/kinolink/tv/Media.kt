package com.kinolink.tv

/** Человеческое имя релиза из «технического» названия раздачи/файла. */
data class Clean(val name: String, val year: Int?, val season: Int?, val episode: Int?) {
    /** «2 сезон · 5 серия» или год; пусто, если нечего показать. */
    fun label(): String = listOfNotNull(
        season?.let { "$it сезон" }, episode?.let { "$it серия" }.takeIf { season != null || episode != null },
    ).joinToString(" · ").ifEmpty { year?.toString() ?: "" }
}

private val EXT = Regex("(?i)\\.(mkv|mp4|avi|m4v|mov|ts|m2ts|webm|torrent)$")
private val SXE = Regex("(?i)\\bS(\\d{1,2})[ ._-]?E(\\d{1,3})\\b")
private val NXN = Regex("(?i)\\b(\\d{1,2})x(\\d{2,3})\\b")
private val RU_SEASON = Regex("(?i)\\b(\\d{1,2})\\s*(?:сезон|season)")
private val RU_EP = Regex("(?i)\\b(\\d{1,3})\\s*(?:серия|серии|серий|episode|ep)\\b|\\bE(\\d{2,3})\\b")
private val YEAR = Regex("\\b(19[3-9]\\d|20[0-4]\\d)\\b")
private val TAGS = Regex(
    "(?i)\\b(2160p|1080[pi]|720p|480p|4k|uhd|hdr10?\\+?|web-?dl|web-?rip|bd-?rip|bdremux|remux|hdtv|hdrip|dvdrip|x26[45]|h\\.?26[45]|hevc|avc|aac|ac3|dts|atmos|nnmclub|rutor|lostfilm|hdrezka|kinozal|rutracker|tfile|proper|repack|extended|unrated|dub|mvo|dvo|vo)\\b",
)

fun cleanTitle(raw: String): Clean {
    val file = raw.substringAfterLast('/').replace(EXT, "")
    val spaced = file.replace('.', ' ').replace('_', ' ')
    var season: Int? = null; var episode: Int? = null
    SXE.find(spaced)?.let { season = it.groupValues[1].toInt(); episode = it.groupValues[2].toInt() }
        ?: NXN.find(spaced)?.let { season = it.groupValues[1].toInt(); episode = it.groupValues[2].toInt() }
    if (season == null) RU_SEASON.find(spaced)?.let { season = it.groupValues[1].toInt() }
    if (episode == null) RU_EP.find(spaced)?.let { episode = (it.groupValues[1].ifEmpty { it.groupValues[2] }).toInt() }
    val year = YEAR.find(spaced)?.value?.toInt()
    // имя = всё до первой «технической» отметки; альтернативное название после « / » отбрасываем
    val cuts = listOfNotNull(SXE.find(spaced), NXN.find(spaced), YEAR.find(spaced), TAGS.find(spaced), RU_SEASON.find(spaced), RU_EP.find(spaced))
        .map { it.range.first }.filter { it > 0 }
    var name = spaced.substring(0, cuts.minOrNull() ?: spaced.length)
    name = name.replace(Regex("\\[[^\\]]*]|\\([^)]*\\)?"), " ").substringBefore(" / ")
    name = name.replace(Regex("\\s+"), " ").trim(' ', '-', '–', '—', '|', ',')
    if (name.isEmpty()) name = spaced.replace(Regex("\\[[^\\]]*]"), " ").replace(Regex("\\s+"), " ").trim()
    return Clean(name, year, season, episode)
}

/** Самопроверка без тестового фреймворка: вызывается из отладочной сборки и в юнит-тесте. */
internal fun cleanTitleSelfCheck() {
    fun eq(a: Any?, b: Any?) = check(a == b) { "cleanTitle: ожидали $b, получили $a" }
    cleanTitle("Холоп.3.2026.WEBRip.[1080p].NNMClub.mkv").let { eq(it.name, "Холоп 3"); eq(it.year, 2026) }
    cleanTitle("Полураспад.S01E05.1080p.WEB-DL.mkv").let { eq(it.name, "Полураспад"); eq(it.season, 1); eq(it.episode, 5) }
    cleanTitle("Show/Season 2/Show - 2x07 - Title.mkv").let { eq(it.season, 2); eq(it.episode, 7) }
    eq(cleanTitle("The.Matrix.1999.BDRip.x264.mkv").name, "The Matrix")
    eq(cleanTitle("Avatar 2009 BDRemux 2160p").label(), "2009")
}
