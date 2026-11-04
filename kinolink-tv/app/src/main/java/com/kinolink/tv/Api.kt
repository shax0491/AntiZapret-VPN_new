package com.kinolink.tv

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.net.URLEncoder
import java.util.UUID
import java.util.concurrent.TimeUnit

data class Item(
    val id: String, val title: String, val sub: String, val type: String,
    val imgId: String, val backdropId: String, val seriesId: String?,
    val posTicks: Long, val runTicks: Long, val rating: Double, val overview: String,
    val torrentHash: String? = null, val torrentPoster: String? = null,
    val url: String? = null,           // готовая ссылка на поток (Filmix / онлайн через Lampac)
    val qualities: Map<String, String> = emptyMap(),   // онлайн: качество -> ссылка (1080p, 720p...)
    val year: String = "",             // дата выхода (гггг-мм-дд или год) для сортировки по году
)

data class Stream(val index: Int, val type: String, val title: String, val codec: String, val lang: String)
data class Info(val msId: String, val psId: String, val streams: List<Stream>)

/** Лестница качества как в Lampa/Jellyfin: «Авто» = Direct Play, дальше битрейты от большего к меньшему. */
enum class Quality(val label: String, val kbps: Int, val h: Int) {
    AUTO("Оригинал", 0, 0), P2160("4K", 40_000, 2160), P1080("1080p", 8_000, 1080), P720("720p", 4_000, 720), P480("480p", 1_500, 480)
}

/** Номинальное разрешение по ширине кадра: у широких фильмов высота меньше (3840x1600 — это 4K, а не 1600p). */
fun nomH(w: Int, h: Int): Int = when { w >= 3600 -> 2160; w >= 2400 -> 1440; w >= 1800 -> 1080; w >= 1200 -> 720; w >= 800 -> 480; else -> h }
fun qLabel(h: Int): String = if (h >= 2000) "4K" else if (h >= 1400) "2K" else "${h}p"

class Api(ctx: Context) {
    private val sp = ctx.getSharedPreferences("kl", Context.MODE_PRIVATE)
    private val http = OkHttpClient.Builder().connectTimeout(15, TimeUnit.SECONDS).readTimeout(30, TimeUnit.SECONDS).build()
    val deviceId: String = sp.getString("dev", null) ?: UUID.randomUUID().toString().also { sp.edit().putString("dev", it).apply() }

    /** Сервер зашит в приложение: пользователь вводит только логин и пароль. */
    val servers = listOf("https://jellyfin.hoststatus2342.ru:8443", "http://192.168.1.109:8096")
    var base: String get() = sp.getString("base", null)?.takeIf { it.isNotBlank() } ?: servers[0]; set(v) = sp.edit().putString("base", v.trim().trimEnd('/')).apply()
    /** Плеер: false = встроенный ExoPlayer, true = внешний (Intent ACTION_VIEW: VLC, MX Player и т.д.) */
    var externalPlayer: Boolean get() = sp.getBoolean("extplayer", false); set(v) = sp.edit().putBoolean("extplayer", v).apply()
    var token: String get() = sp.getString("token", "")!!; set(v) = sp.edit().putString("token", v).apply()
    var uid: String get() = sp.getString("uid", "")!!; set(v) = sp.edit().putString("uid", v).apply()
    private val LAN_TS = "http://192.168.1.115:9085"
    /** TorrServer: дома — напрямую (быстро), снаружи — через публичный прокси Lampac /ts (логин = uid Lampac, пароль ts).
     *  Режим: 0 авто (проверка LAN при старте), 1 только внешний, 2 только дома. Пустое значение в настройках = авто. */
    @Volatile var tsLan = false
    var tsMode: Int get() = sp.getInt("tsmode", 0); set(v) = sp.edit().putInt("tsmode", v).apply()
    private val lanNow get() = when (tsMode) { 1 -> false; 2 -> true; else -> tsLan }
    var ts: String
        get() = sp.getString("ts", "")!!.takeIf { it.isNotBlank() && it != LAN_TS && !it.contains(":9118") } ?: if (lanNow) LAN_TS else "$lampac/ts"
        set(v) = sp.edit().putString("ts", v.trim().trimEnd('/')).apply()
    var tsAuth: String
        get() = sp.getString("tsAuth", "")!!.takeIf { it.isNotBlank() && it != Secrets.TS_AUTH } ?: if (lanNow) Secrets.TS_AUTH else "$lampacUid:ts"
        set(v) = sp.edit().putString("tsAuth", v).apply()
    private val probeHttp = OkHttpClient.Builder().connectTimeout(1200, TimeUnit.MILLISECONDS).readTimeout(1500, TimeUnit.MILLISECONDS).build()
    /** Дома ли мы: LAN-адрес TorrServer отвечает за ~1 с. Вызывать при старте и при возврате на главную. */
    suspend fun probeTs() { tsLan = withContext(Dispatchers.IO) { runCatching { probeHttp.newCall(Request.Builder().url("$LAN_TS/echo").build()).execute().use { it.isSuccessful } }.getOrDefault(false) } }
    fun tsWhere() = if (ts.startsWith(LAN_TS)) "дома (напрямую)" else if (ts.startsWith(lampac)) "через сервер (из любой сети)" else ts
    fun tsHeader() = "Basic " + android.util.Base64.encodeToString(tsAuth.toByteArray(), android.util.Base64.NO_WRAP)
    var user: String get() = sp.getString("user", "")!!; set(v) = sp.edit().putString("user", v).apply()
    val loggedIn get() = token.isNotEmpty() && uid.isNotEmpty()

    fun jfHeader() = auth()
    private fun auth(withToken: Boolean = true) =
        "MediaBrowser Client=\"KinolinkTV\", Device=\"AndroidTV\", DeviceId=\"$deviceId\", Version=\"0.1\"" +
            if (withToken && token.isNotEmpty()) ", Token=\"$token\"" else ""

    private fun call(method: String, url: String, body: String? = null, withToken: Boolean = true): String {
        val rb = body?.toRequestBody("application/json".toMediaType())
        val req = Request.Builder().url(url).header("Authorization", if (url.startsWith(ts)) tsHeader() else auth(withToken))
            .method(method, rb ?: if (method == "GET" || method == "DELETE") null else "".toRequestBody()).build()
        http.newCall(req).execute().use { r ->
            val s = r.body?.string() ?: ""
            if (!r.isSuccessful) throw RuntimeException("HTTP ${r.code}")
            return s
        }
    }

    private suspend fun io(f: () -> String) = withContext(Dispatchers.IO) { f() }
    private fun e(s: String) = URLEncoder.encode(s, "UTF-8")

    suspend fun login(user: String, pw: String) {
        val j = JSONObject(io { call("POST", "$base/Users/AuthenticateByName", JSONObject().put("Username", user).put("Pw", pw).toString(), false) })
        // другой пользователь на том же устройстве: свой uid Lampac (Filmix, TorrServer-доступ), чужой не наследуем
        if (!this.user.equals(user, ignoreCase = true) || uid != j.getJSONObject("User").getString("Id")) lampacUid = ""
        token = j.getString("AccessToken"); uid = j.getJSONObject("User").getString("Id"); this.user = user
        repeat(3) { if (lampacUid.isEmpty()) runCatching { registerLampac(user, pw) } }   // персональный uid Lampac для Filmix/онлайн
    }

    private suspend fun registerLampac(user: String, pw: String) = withContext(Dispatchers.IO) {
        val form = okhttp3.FormBody.Builder().add("username", user).add("password", pw).add("uid", deviceId.take(16)).build()
        http.newCall(Request.Builder().url("$lampac/jfauth/login").post(form).build()).execute().use { r ->
            val j = JSONObject(r.body!!.string())
            if (j.optBoolean("ok") && j.optString("uid").isNotEmpty()) lampacUid = j.getString("uid")
        }
    }

    private fun parse(arr: JSONArray?): List<Item> = if (arr == null) emptyList() else (0 until arr.length()).mapNotNull { i ->
        runCatching {
            val o = arr.getJSONObject(i)
            val id = o.optString("Id").ifEmpty { return@runCatching null }
            val type = o.optString("Type")
            val ud = o.optJSONObject("UserData")
            val ep = type == "Episode"
            val sid = o.optString("SeriesId").ifEmpty { null }
            val sub = if (ep) "${o.optString("SeriesName")} · S${o.optInt("ParentIndexNumber")}E${o.optInt("IndexNumber")}" else o.optInt("ProductionYear").let { if (it > 0) "$it" else "" }
            Item(id, o.optString("Name"), sub, type, id, if (ep && sid != null) sid else id, sid,
                ud?.optLong("PlaybackPositionTicks") ?: 0, o.optLong("RunTimeTicks"), o.optDouble("CommunityRating", 0.0), o.optString("Overview"))
        }.getOrNull()
    }

    private val fields = "Fields=Overview,PremiereDate,DateCreated,CommunityRating,ProductionYear,SeriesId,SeriesName&EnableImageTypes=Primary,Backdrop"

    suspend fun resume(): List<Item> = parse(JSONObject(io { call("GET", "$base/Users/$uid/Items/Resume?MediaTypes=Video&Limit=20&$fields") }).optJSONArray("Items"))

    /** sort: PremiereDate | DateCreated | CommunityRating */
    suspend fun catalog(types: String, sort: String, limit: Int = 60): List<Item> = parse(JSONObject(io {
        call("GET", "$base/Users/$uid/Items?Recursive=true&IncludeItemTypes=$types&SortBy=$sort&SortOrder=Descending&Limit=$limit&$fields")
    }).optJSONArray("Items"))

    /** Избранное пользователя Jellyfin (сердечко в любом клиенте Jellyfin). */
    suspend fun favorites(): List<Item> = parse(JSONObject(io {
        call("GET", "$base/Users/$uid/Items?Recursive=true&IncludeItemTypes=Movie,Series&Filters=IsFavorite&SortBy=SortName&Limit=200&$fields")
    }).optJSONArray("Items"))

    suspend fun setFavorite(id: String, on: Boolean) { io { call(if (on) "POST" else "DELETE", "$base/Users/$uid/FavoriteItems/$id") } }

    suspend fun isFavorite(id: String): Boolean = runCatching {
        JSONObject(io { call("GET", "$base/Users/$uid/Items/$id") }).optJSONObject("UserData")?.optBoolean("IsFavorite") ?: false
    }.getOrDefault(false)

    suspend fun searchJellyfin(term: String): List<Item> = parse(JSONObject(io {
        call("GET", "$base/Users/$uid/Items?Recursive=true&IncludeItemTypes=Movie,Series&SearchTerm=${e(term)}&Limit=30&$fields")
    }).optJSONArray("Items"))

    suspend fun episodes(seriesId: String): List<Item> = parse(JSONObject(io {
        call("GET", "$base/Shows/$seriesId/Episodes?UserId=$uid&$fields")
    }).optJSONArray("Items"))

    suspend fun nextUp(seriesId: String): Item? = parse(JSONObject(io {
        call("GET", "$base/Shows/NextUp?UserId=$uid&SeriesId=$seriesId&Limit=1&$fields")
    }).optJSONArray("Items")).firstOrNull()

    fun img(id: String, kind: String = "Primary", w: Int = 400) = "$base/Items/$id/Images/$kind?maxWidth=$w&api_key=$token"

    suspend fun info(itemId: String): Info {
        val j = JSONObject(io { call("POST", "$base/Items/$itemId/PlaybackInfo?UserId=$uid&AutoOpenLiveStream=false", "{}") })
        val ms = j.optJSONArray("MediaSources")?.optJSONObject(0) ?: throw RuntimeException("Jellyfin не вернул источник видео")
        val st = ms.optJSONArray("MediaStreams") ?: JSONArray()
        val list = (0 until st.length()).map { st.getJSONObject(it) }.filter { it.optString("Type") in listOf("Audio", "Subtitle") }.map {
            Stream(it.optInt("Index"), it.optString("Type"), it.optString("DisplayTitle", it.optString("Language", "?")), it.optString("Codec"), it.optString("Language"))
        }
        return Info(ms.optString("Id"), j.optString("PlaySessionId", UUID.randomUUID().toString().replace("-", "")), list)
    }

    /** Прямой поток (Direct Play) или HLS-транскод с заданным битрейтом. Каждый вызов — новый PlaySessionId. */
    fun url(itemId: String, info: Info, q: Quality, audioIdx: Int?): Pair<String, String> {
        val ps = UUID.randomUUID().toString().replace("-", "")
        if (q == Quality.AUTO)
            return "$base/Videos/$itemId/stream?static=true&MediaSourceId=${info.msId}&PlaySessionId=$ps&api_key=$token" to ps
        val bps = q.kbps * 1000
        val h = q.h
        return ("$base/Videos/$itemId/master.m3u8?MediaSourceId=${info.msId}&PlaySessionId=$ps&api_key=$token&DeviceId=$deviceId" +
            "&VideoCodec=hevc,h264&AudioCodec=ac3,aac&TranscodingMaxAudioChannels=6&SegmentContainer=ts&MinSegments=1&BreakOnNonKeyFrames=true" +
            "&VideoBitrate=${(bps * 0.9).toInt()}&MaxStreamingBitrate=$bps&MaxHeight=$h&AllowVideoStreamCopy=false" +
            (audioIdx?.let { "&AudioStreamIndex=$it" } ?: "")) to ps
    }

    fun subUrl(itemId: String, info: Info, idx: Int) = "$base/Videos/$itemId/${info.msId}/Subtitles/$idx/0/Stream.vtt?api_key=$token"

    private fun body(itemId: String, info: Info, ps: String, ticks: Long) =
        JSONObject().put("ItemId", itemId).put("MediaSourceId", info.msId).put("PlaySessionId", ps).put("PositionTicks", ticks).toString()

    suspend fun reportStart(itemId: String, info: Info, ps: String) { runCatching { io { call("POST", "$base/Sessions/Playing", body(itemId, info, ps, 0)) } } }
    suspend fun reportProgress(itemId: String, info: Info, ps: String, ms: Long) { runCatching { io { call("POST", "$base/Sessions/Playing/Progress", body(itemId, info, ps, ms * 10_000)) } } }
    suspend fun reportStop(itemId: String, info: Info, ps: String, ms: Long) { runCatching { io { call("POST", "$base/Sessions/Playing/Stopped", body(itemId, info, ps, ms * 10_000)) } } }

    /** Останавливаем ffmpeg предыдущего транскода — иначе сегменты копятся на диске CT106. */
    suspend fun stopEncoding(ps: String) { runCatching { io { call("DELETE", "$base/Videos/ActiveEncodings?deviceId=${e(deviceId)}&playSessionId=${e(ps)}") } } }

    // ---- TorrServer ----
    suspend fun torrents(): List<Item> {
        val a = JSONArray(io { call("POST", "$ts/torrents", JSONObject().put("action", "list").toString(), false) })
        return (0 until a.length()).map { a.getJSONObject(it) }.map {
            val c = cleanTitle(it.optString("title").ifEmpty { it.optString("name") })
            Item(it.optString("hash"), c.name, c.label().ifEmpty { "Торрент" }, "Torrent", "", "", null, 0, 0, 0.0, "",
                it.optString("hash"), it.optString("poster").ifEmpty { null })
        }
    }

    /** Постер по названию через TMDB (прокси Lampac). */
    suspend fun tmdbPoster(name: String): String? = withContext(Dispatchers.IO) {
        runCatching {
            val body = http.newCall(Request.Builder().url("$lampac/tmdb/api/3/search/multi?api_key=${Secrets.TMDB}&language=ru-RU&query=${e(name)}&uid=$lampacUid").build()).execute().use { it.body!!.string() }
            val arr = JSONObject(body).getJSONArray("results")
            (0 until arr.length()).map { arr.getJSONObject(it) }.firstOrNull { it.optString("poster_path").isNotEmpty() }
                ?.let { "$lampac/tmdb/img/t/p/w500${it.optString("poster_path")}?uid=$lampacUid" }
        }.getOrNull()
    }

    /** Лента TMDB как в Lampa: path - запрос вида "movie/popular" или "discover/tv?with_original_language=ko&...". */
    /** Невышедшее (дата выхода позже сегодняшней) на главной не показываем; без даты — оставляем. */
    private fun released(o: JSONObject): Boolean {
        val d = o.optString("release_date").ifEmpty { o.optString("first_air_date") }
        return d.isEmpty() || d <= java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).format(java.util.Date())
    }

    suspend fun tmdbList(path: String, serial: Boolean, page: Int = 1): List<Item> = withContext(Dispatchers.IO) {
        val sep = if ('?' in path) "&" else "?"
        val r = http.newCall(Request.Builder().url("$lampac/tmdb/api/3/$path${sep}api_key=${Secrets.TMDB}&language=ru-RU&page=$page&uid=$lampacUid").build()).execute().use { it.body!!.string() }
        val arr = JSONObject(r).getJSONArray("results")
        (0 until arr.length()).map { arr.getJSONObject(it) }.filter { it.optString("poster_path").isNotEmpty() && released(it) }.map {
            Item(it.optString("id"), it.optString("title").ifEmpty { it.optString("name") }, if (serial) "Сериал" else "Фильм", "Trend", "",
                it.optString("backdrop_path").let { b -> if (b.isNotEmpty()) "$lampac/tmdb/img/t/p/w1280$b?uid=$lampacUid" else "" }, null, 0, 0,
                it.optDouble("vote_average", 0.0), it.optString("overview"), null, "$lampac/tmdb/img/t/p/w500${it.optString("poster_path")}?uid=$lampacUid",
                year = it.optString("release_date").ifEmpty { it.optString("first_air_date") })
        }
    }

    /** Данные TMDB для карточки: рейтинг, голоса, жанры, длительность, режиссёр, актёры. */
    data class Tmdb(val rating: Double, val votes: Int, val year: String, val runtime: Int, val genres: List<String>,
                    val cast: List<String>, val director: String, val tagline: String, val overview: String)

    suspend fun tmdbInfo(title: String, serial: Boolean): Tmdb? = withContext(Dispatchers.IO) {
        runCatching {
            val kind = if (serial) "tv" else "movie"
            fun get(path: String) = JSONObject(http.newCall(Request.Builder().url("$lampac/tmdb/api/3/$path${if ('?' in path) "&" else "?"}api_key=${Secrets.TMDB}&language=ru-RU&uid=$lampacUid").build()).execute().use { it.body!!.string() })
            val id = get("search/$kind?query=${e(title)}").getJSONArray("results").getJSONObject(0).getInt("id")
            val d = get("$kind/$id?append_to_response=credits")
            val cr = d.optJSONObject("credits")
            val cast = cr?.optJSONArray("cast")?.let { a -> (0 until minOf(a.length(), 6)).map { a.getJSONObject(it).optString("name") } } ?: emptyList()
            val dir = cr?.optJSONArray("crew")?.let { a -> (0 until a.length()).map { a.getJSONObject(it) }.firstOrNull { it.optString("job") == "Director" }?.optString("name") }
                ?: d.optJSONArray("created_by")?.let { a -> (0 until a.length()).joinToString(", ") { a.getJSONObject(it).optString("name") } } ?: ""
            val g = d.optJSONArray("genres")?.let { a -> (0 until a.length()).map { a.getJSONObject(it).optString("name") } } ?: emptyList()
            val rt = d.optInt("runtime").takeIf { it > 0 } ?: d.optJSONArray("episode_run_time")?.optInt(0) ?: 0
            Tmdb(d.optDouble("vote_average", 0.0), d.optInt("vote_count"), (d.optString("release_date").ifEmpty { d.optString("first_air_date") }).take(4), rt, g, cast, dir, d.optString("tagline"), d.optString("overview"))
        }.getOrNull()
    }

    // ---- Локальное избранное для карточек TMDB (у Jellyfin их нет): на пользователя, хранится на устройстве ----
    private fun lfavRead(): JSONArray = runCatching { JSONArray(sp.getString("lfav_$uid", "[]")) }.getOrDefault(JSONArray())
    fun localFavs(): List<Item> {
        val a = lfavRead()
        return (0 until a.length()).mapNotNull { i -> runCatching { a.getJSONObject(i).let { o ->
            Item(o.getString("id"), o.getString("t"), o.optString("s"), "Trend", "", o.optString("b"), null, 0, 0, o.optDouble("r", 0.0), o.optString("ov"), null, o.optString("p")) } }.getOrNull() }
    }
    fun isLocalFav(id: String) = localFavs().any { it.id == id }
    /** Переключает; возвращает новое состояние (true = в избранном). */
    fun toggleLocalFav(it: Item): Boolean {
        val cur = localFavs()
        val now = cur.none { x -> x.id == it.id }
        val out = JSONArray()
        (if (now) listOf(it) + cur else cur.filter { x -> x.id != it.id }).forEach { x ->
            out.put(JSONObject().put("id", x.id).put("t", x.title).put("s", x.sub).put("b", x.backdropId).put("r", x.rating).put("ov", x.overview).put("p", x.torrentPoster ?: ""))
        }
        sp.edit().putString("lfav_$uid", out.toString()).apply()
        return now
    }

    // ---- Интерфейс: тяжёлые эффекты, которые отключают на слабых устройствах ----
    var fxAnim: Boolean get() = sp.getBoolean("fx_anim", true); set(v) = sp.edit().putBoolean("fx_anim", v).apply()
    var fxFocus: Boolean get() = sp.getBoolean("fx_focus", true); set(v) = sp.edit().putBoolean("fx_focus", v).apply()
    var fxKen: Boolean get() = sp.getBoolean("fx_ken", true); set(v) = sp.edit().putBoolean("fx_ken", v).apply()
    var fxGlass: Boolean get() = sp.getBoolean("fx_glass", true); set(v) = sp.edit().putBoolean("fx_glass", v).apply()

    // ---- Заставка (экранная): настройки хранятся на устройстве ----
    var ssOn: Boolean get() = sp.getBoolean("ss_on", true); set(v) = sp.edit().putBoolean("ss_on", v).apply()
    var ssMin: Int get() = sp.getInt("ss_min", 5); set(v) = sp.edit().putInt("ss_min", v).apply()
    var ssTheme: String get() = sp.getString("ss_theme", "new")!!; set(v) = sp.edit().putString("ss_theme", v).apply()

    private fun tmdbGet(path: String): JSONObject =
        JSONObject(http.newCall(Request.Builder().url("$lampac/tmdb/api/3/$path${if ('?' in path) "&" else "?"}api_key=${Secrets.TMDB}&language=ru-RU&uid=$lampacUid").build()).execute().use { it.body!!.string() })

    /** Баннер заставки: lang = "ru" или "en" (оба с названием на картинке). Чистые кадры не берём. */
    data class Ban(val url: String, val lang: String)

    private fun tmdbBackdrops(path: String): List<Ban> {
        val arr = tmdbGet(path).getJSONArray("results")
        val kind = if (path.contains("/tv") || path.startsWith("tv")) "tv" else "movie"
        val pool = java.util.concurrent.Executors.newFixedThreadPool(8)
        try {
            return (0 until minOf(arr.length(), 40)).map { arr.getJSONObject(it) }.map { r ->
                pool.submit<Ban?> {
                    runCatching {
                        val k = r.optString("media_type").ifEmpty { kind }
                        val b = tmdbGet("$k/${r.getInt("id")}/images?include_image_language=ru,en").getJSONArray("backdrops")
                        val l = (0 until b.length()).map { b.getJSONObject(it) }.filter { it.optInt("width") >= 1280 }
                        fun best(c: String) = l.filter { it.optString("iso_639_1") == c }.maxByOrNull { it.optDouble("vote_average") }
                        (best("ru") ?: best("en"))?.let { Ban("$lampac/tmdb/img/t/p/w1280${it.optString("file_path")}?uid=$lampacUid", it.optString("iso_639_1")) }
                    }.getOrNull()
                }
            }.mapNotNull { it.get() }
        } finally { pool.shutdown() }
    }

    /** Картинки для заставки по теме: new / trend / library / cartoon / anime / nature (документальное кино о природе). */
    suspend fun screensaverImages(theme: String): List<Ban> = withContext(Dispatchers.IO) {
        runCatching {
            val today = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).format(java.util.Date())
            when (theme) {
                "trend" -> tmdbBackdrops("trending/all/week")
                "library" -> catalog("Movie,Series", "DateCreated", 40).filter { it.backdropId.isNotEmpty() }.map { Ban(img(it.backdropId, "Backdrop", 1280), "ru") }
                "cartoon" -> tmdbBackdrops("discover/movie?with_genres=16&sort_by=popularity.desc")
                "anime" -> tmdbBackdrops("discover/tv?with_genres=16&with_original_language=ja&sort_by=popularity.desc")
                "nature" -> tmdbBackdrops("discover/movie?with_genres=99&sort_by=popularity.desc") + tmdbBackdrops("discover/tv?with_genres=99&sort_by=popularity.desc")
                else -> tmdbBackdrops("discover/movie?sort_by=primary_release_date.desc&primary_release_date.lte=$today&vote_count.gte=15") +
                    tmdbBackdrops("discover/tv?sort_by=first_air_date.desc&first_air_date.lte=$today&vote_count.gte=5")
            }.shuffled().sortedBy { it.lang != "ru" } // русские баннеры идут первыми
        }.getOrDefault(emptyList())
    }

    // ---- Полная карточка TMDB: страна, дата, статус, режиссёры и актёры с фото, рекомендации и похожие ----
    data class Person(val name: String, val role: String, val photo: String)
    data class TmdbFull(val country: String, val release: String, val status: String, val directors: List<Person>, val actors: List<Person>, val recs: List<Item>, val similar: List<Item>)

    private fun tmdbItem(it: JSONObject, serial: Boolean) = Item(it.optString("id"), it.optString("title").ifEmpty { it.optString("name") }, if (serial) "Сериал" else "Фильм", "Trend", "",
        it.optString("backdrop_path").let { b -> if (b.isNotEmpty()) "$lampac/tmdb/img/t/p/w1280$b?uid=$lampacUid" else "" }, null, 0, 0,
        it.optDouble("vote_average", 0.0), it.optString("overview"), null, "$lampac/tmdb/img/t/p/w500${it.optString("poster_path")}?uid=$lampacUid")

    suspend fun tmdbFull(item: Item, serial: Boolean): TmdbFull? = withContext(Dispatchers.IO) {
        runCatching {
            val kind = if (serial) "tv" else "movie"
            val id = if (item.type == "Trend") item.id else tmdbGet("search/$kind?query=${e(item.title)}").getJSONArray("results").getJSONObject(0).getInt("id").toString()
            val d = tmdbGet("$kind/$id?append_to_response=credits,recommendations,similar")
            val months = listOf("Января", "Февраля", "Марта", "Апреля", "Мая", "Июня", "Июля", "Августа", "Сентября", "Октября", "Ноября", "Декабря")
            val rel = d.optString("release_date").ifEmpty { d.optString("first_air_date") }.split("-").let { p -> if (p.size == 3) "${p[2].toInt()} ${months[p[1].toInt() - 1]} ${p[0]}" else "" }
            val country = d.optJSONArray("production_countries")?.let { c -> (0 until c.length()).joinToString(", ") { c.getJSONObject(it).optString("iso_3166_1").let { iso -> java.util.Locale("", iso).getDisplayCountry(java.util.Locale("ru")).ifEmpty { iso } } } }?.takeIf { it.isNotEmpty() }
                ?: d.optJSONArray("origin_country")?.let { c -> (0 until c.length()).joinToString(", ") { c.getString(it).let { iso -> java.util.Locale("", iso).getDisplayCountry(java.util.Locale("ru")).ifEmpty { iso } } } } ?: ""
            val status = when (d.optString("status")) { "Released" -> "Выпущенный"; "Returning Series" -> "Выходит"; "Ended" -> "Завершён"; "In Production" -> "В производстве"; "Canceled" -> "Закрыт"; else -> d.optString("status") }
            fun photo(o: JSONObject) = o.optString("profile_path").takeIf { it.isNotEmpty() }?.let { "$lampac/tmdb/img/t/p/w185$it?uid=$lampacUid" } ?: ""
            val cr = d.optJSONObject("credits")
            val dirs = cr?.optJSONArray("crew")?.let { c -> (0 until c.length()).map { c.getJSONObject(it) }.filter { it.optString("job") == "Director" }.take(4).map { Person(it.optString("name"), "Режиссёр", photo(it)) } } ?: emptyList()
            val acts = cr?.optJSONArray("cast")?.let { c -> (0 until minOf(c.length(), 14)).map { c.getJSONObject(it) }.map { Person(it.optString("name"), it.optString("character"), photo(it)) } } ?: emptyList()
            fun list(key: String) = d.optJSONObject(key)?.optJSONArray("results")?.let { r -> (0 until r.length()).map { r.getJSONObject(it) }.filter { it.optString("poster_path").isNotEmpty() }.map { tmdbItem(it, serial) } } ?: emptyList()
            TmdbFull(country, rel, status, dirs, acts, list("recommendations"), list("similar"))
        }.getOrNull()
    }

    // ---- История просмотра торрентов: у каждого пользователя Jellyfin своя (ключ по uid), хранится на устройстве ----
    private fun histKey() = "hist_$uid"
    private fun histRead(): JSONArray = runCatching { JSONArray(sp.getString(histKey(), "[]")) }.getOrDefault(JSONArray())

    /** «Продолжить просмотр» по торрентам: новые первыми, с человеческим названием, постером, сезоном/серией и позицией. */
    fun history(): List<Item> {
        val a = histRead()
        return (0 until a.length()).mapNotNull { i ->
            runCatching {
                val o = a.getJSONObject(i); val h = o.getString("h"); val idx = o.optInt("i", 1)
                Item("$h:$idx", o.getString("t"), o.optString("s"), "Torrent", "", "", null, o.optLong("p") * 10_000, o.optLong("d") * 10_000, 0.0, "",
                    h, o.optString("po").ifEmpty { null }, "$ts/stream?link=$h&index=$idx&play")
            }.getOrNull()
        }
    }

    fun saveHistory(it: Item, posMs: Long, durMs: Long) {
        val h = it.torrentHash ?: return
        if (posMs < 10_000) return
        val idx = it.id.substringAfter(':', "1").toIntOrNull() ?: 1
        val old = histRead()
        val out = JSONArray()
        val finished = durMs > 0 && posMs > durMs * 0.95
        if (!finished) out.put(JSONObject().put("h", h).put("i", idx).put("t", it.title).put("s", it.sub.takeIf { s -> s != "Торрент" } ?: "")
            .put("po", it.torrentPoster ?: "").put("p", posMs).put("d", durMs).put("ts", System.currentTimeMillis()))
        for (k in 0 until old.length()) { val o = old.getJSONObject(k); if (!(o.optString("h") == h && o.optInt("i", 1) == idx) && out.length() < 30) out.put(o) }
        sp.edit().putString(histKey(), out.toString()).apply()
    }

    /** Рекомендации Jellyfin (по просмотрам пользователя). */
    suspend fun suggestions(): List<Item> = parse(JSONObject(io {
        call("GET", "$base/Items/Suggestions?userId=$uid&mediaType=Video&type=Movie,Series&limit=30&$fields")
    }).optJSONArray("Items"))

    /** У старых сессий имя не сохранялось: подтягиваем с сервера. */
    suspend fun ensureUser() {
        if (user.isNotEmpty() || !loggedIn) return
        runCatching { user = JSONObject(io { call("GET", "$base/Users/$uid") }).optString("Name") }
    }

    suspend fun addMagnet(link: String) { io { call("POST", "$ts/torrents", JSONObject().put("action", "add").put("link", link).put("save_to_db", true).toString(), false) } }
    fun torrentUrl(hash: String) = "$ts/stream/file?link=$hash&index=1&play"

    // ---- Filmix и онлайн-источники через Lampac (токены и прокси лежат на сервере CT112) ----
    val lampac = "https://lampa.hoststatus2343.ru:8443"
    /** Личный uid Lampac: выдаётся сервером при входе (/jfauth/login, по учётке Jellyfin) и хранится на устройстве. Можно вписать свой в настройках. */
    var lampacUid: String get() = sp.getString("luid", "")!!; set(v) = sp.edit().putString("luid", v.trim()).apply()

    private fun lampacGet(url: String): JSONObject {
        var last: Exception? = null
        repeat(3) {
            try {
                if (lampacUid.isEmpty()) throw RuntimeException("нет uid Lampac: выйдите и войдите заново или впишите uid в настройках")
                val u = (if (url.startsWith("http")) url else lampac + url).let { it + (if ('?' in it) "&" else "?") + "uid=$lampacUid&rjson=true" }
                val req = Request.Builder().url(u).build()
                http.newCall(req).execute().use { r -> if (r.isSuccessful) return JSONObject(r.body!!.string()); last = RuntimeException("HTTP ${r.code}") }
            } catch (e: Exception) { last = e }
            Thread.sleep(700)
        }
        throw last ?: RuntimeException("lampac")
    }

    private val cardCache = HashMap<String, String>()

    data class Ep(val num: Int, val name: String, val still: String, val date: String, val overview: String)

    /** Серии сезона из TMDB (кадр, название, дата выхода, описание) — для экрана выбора серии, как в Lampa. */
    suspend fun tmdbSeasonEps(title: String, season: Int): List<Ep> = withContext(Dispatchers.IO) {
        runCatching {
            val id = Regex("(?:^|&)id=(\\d+)").find(cardQuery(title, true))!!.groupValues[1]
            val a = tmdbGet("tv/$id/season/$season").getJSONArray("episodes")
            (0 until a.length()).map { a.getJSONObject(it) }.map { e ->
                Ep(e.optInt("episode_number"), e.optString("name"), e.optString("still_path").let { sp -> if (sp.isEmpty()) "" else "$lampac/tmdb/img/t/p/w300$sp?uid=$lampacUid" }, e.optString("air_date"), e.optString("overview"))
            }
        }.getOrDefault(emptyList())
    }

    /** Параметры карточки в том виде, как их шлёт Lampa (id TMDB, imdb, оригинальное название, год, язык): без них многие источники отвечают 503 или отдают мёртвые потоки. */
    suspend fun cardQuery(title: String, serial: Boolean): String = withContext(Dispatchers.IO) {
        cardCache.getOrPut("$title|$serial") {
            runCatching {
                val kind = if (serial) "tv" else "movie"
                val id = tmdbGet("search/$kind?query=${e(title)}").getJSONArray("results").getJSONObject(0).getInt("id")
                val d = tmdbGet("$kind/$id?append_to_response=external_ids")
                val imdb = d.optString("imdb_id").ifEmpty { d.optJSONObject("external_ids")?.optString("imdb_id") ?: "" }
                val year = (d.optString("release_date").ifEmpty { d.optString("first_air_date") }).take(4)
                val orig = d.optString("original_title").ifEmpty { d.optString("original_name") }.ifEmpty { title }
                "id=$id&imdb_id=$imdb&kinopoisk_id=&title=${e(title)}&original_title=${e(orig)}&serial=${if (serial) 1 else 0}&year=$year&original_language=${d.optString("original_language")}&source=tmdb"
            }.getOrDefault("")
        }
    }

    /** Список источников от сервера для этой карточки (как в Lampa). Пустые навсегда (Kinogo, LeProduction, Kinotochka) не опрашиваем. */
    suspend fun balancers(qs: String = ""): List<Pair<String, String>> = withContext(Dispatchers.IO) {
        runCatching {
            val a = JSONArray(http.newCall(Request.Builder().url("$lampac/lite/events?${if (qs.isEmpty()) "" else "$qs&"}uid=$lampacUid").build()).execute().use { it.body!!.string() })
            val skip = setOf("Kinogo", "LeProduction", "Kinotochka")
            (0 until a.length()).map { a.getJSONObject(it) }.filter { it.getString("name") !in skip }.map { it.getString("name") to it.getString("url").substringAfter("9118").substringAfter("8443") }
        }.getOrDefault(listOf("Filmix" to "/lite/filmix"))
    }

    /** Один шаг навигации по ответу Lampac: заголовки (ссылки) / озвучки / серии / потоки. */
    data class Node(val type: String, val voices: List<Pair<String, String>>, val rows: List<Row>)
    data class Row(val title: String, val link: String?, val play: String?, val quality: Map<String, String>, val img: String?)

    suspend fun online(url: String): Node = withContext(Dispatchers.IO) {
        val j = lampacGet(url)
        val d = j.optJSONArray("data") ?: JSONArray()
        val rows = (0 until d.length()).map { d.getJSONObject(it) }.map {
            val qo = it.optJSONObject("quality")
            val qm = qo?.keys()?.asSequence()?.associateWith { k -> qo.getString(k) } ?: emptyMap()
            val title = it.optString("name").ifEmpty { it.optString("title") }
            val m = it.optString("method")
            // «call» (HDVB, Aladin и др.): url отдаёт ссылку на поток; готовую ссылку на поток берём из «stream», иначе спрашиваем url
            val st = if (m == "call") it.optString("stream").ifEmpty { null } else null
            val rc = if (m == "call" && st == null) runCatching { lampacGet(it.optString("url")) }.getOrNull() else null
            val rq = rc?.optJSONObject("quality")?.let { q -> q.keys().asSequence().associateWith { k -> q.getString(k) } } ?: qm
            val pl = st ?: rc?.optString("url")?.ifEmpty { null } ?: if (m == "play") it.optString("url") else null
            Row(title, if (pl == null && m != "call") it.optString("url") else null, pl, rq, it.optString("img").ifEmpty { null }?.let { i -> if (i.startsWith("/")) lampac + i else i })
        }
        val v = j.optJSONArray("voice")
        val voices = if (v == null) emptyList() else (0 until v.length()).map { v.getJSONObject(it) }.map { it.optString("name") + (if (it.optBoolean("active")) " ●" else "") to it.optString("url") }
        Node(j.optString("type"), voices, rows)
    }

    /** Проверка HLS-потока источника: null — источник отказал (HTTP-ошибка / не плейлист); список высот из мастер-плейлиста (может быть пустым); при сбое самой проверки — пустой список, озвучку не прячем. */
    suspend fun hlsInfo(url: String): List<Int>? = withContext(Dispatchers.IO) {
        try {
            http.newCall(Request.Builder().url(url).build()).execute().use { r ->
                if (!r.isSuccessful) { android.util.Log.w("KL", "hls ${r.code} " + url.take(90)); return@use null }
                val t = r.peekBody(60_000).string()
                if (!t.startsWith("#EXTM3U")) { android.util.Log.w("KL", "hls not m3u8 " + url.take(90)); return@use null }
                Regex("""RESOLUTION=(\d+)x(\d+)""").findAll(t).map { nomH(it.groupValues[1].toInt(), it.groupValues[2].toInt()) }.distinct().sortedDescending().toList()
            }
        } catch (e: Exception) { android.util.Log.w("KL", "hls check failed: ${e.message}"); emptyList() }
    }

    /** Тренды недели (TMDB через прокси Lampac): клик по карточке запускает единый поиск по названию. */
    suspend fun trending(): List<Item> = withContext(Dispatchers.IO) {
        val r = http.newCall(Request.Builder().url("$lampac/tmdb/api/3/trending/all/week?api_key=${Secrets.TMDB}&language=ru-RU&uid=$lampacUid").build()).execute().use { it.body!!.string() }
        val arr = JSONObject(r).getJSONArray("results")
        (0 until arr.length()).map { arr.getJSONObject(it) }.filter { it.optString("poster_path").isNotEmpty() && released(it) }.map {
            val t = it.optString("title").ifEmpty { it.optString("name") }
            Item(it.optString("id"), t, if (it.optString("media_type") == "tv") "Сериал" else "Фильм", "Trend", "", "", null, 0, 0, it.optDouble("vote_average", 0.0), it.optString("overview"),
                null, "$lampac/tmdb/img/t/p/w500${it.optString("poster_path")}?uid=$lampacUid", year = it.optString("release_date").ifEmpty { it.optString("first_air_date") })
        }
    }

    /** Получить uid Lampac заново (нужен пароль Jellyfin); старый остаётся, если не вышло. */
    suspend fun refreshLampac(pw: String) {
        val old = lampacUid; lampacUid = ""
        runCatching { registerLampac(user, pw) }
        if (lampacUid.isEmpty()) { lampacUid = old; throw RuntimeException("сервер не выдал uid (проверьте пароль)") }
    }

    /** Каталог TMDB для вкладки «Онлайн»: жанр/год, популярное. Клик по карточке ищет название в выбранном источнике. */
    suspend fun discover(serial: Boolean, genre: Int, year: Int): List<Item> = withContext(Dispatchers.IO) {
        val kind = if (serial) "tv" else "movie"
        val yp = if (year > 0) (if (serial) "&first_air_date_year=$year" else "&primary_release_year=$year") else ""
        val gp = if (genre > 0) "&with_genres=$genre" else ""
        val r = http.newCall(Request.Builder().url("$lampac/tmdb/api/3/discover/$kind?api_key=${Secrets.TMDB}&language=ru-RU&sort_by=popularity.desc&vote_count.gte=30$gp$yp&uid=$lampacUid").build()).execute().use { it.body!!.string() }
        val arr = JSONObject(r).getJSONArray("results")
        (0 until arr.length()).map { arr.getJSONObject(it) }.filter { it.optString("poster_path").isNotEmpty() }.map {
            Item(it.optString("id"), it.optString("title").ifEmpty { it.optString("name") }, if (serial) "Сериал" else "Фильм", "Trend", "", "", null, 0, 0, it.optDouble("vote_average", 0.0), it.optString("overview"),
                null, "$lampac/tmdb/img/t/p/w500${it.optString("poster_path")}?uid=$lampacUid")
        }
    }

    fun searchUrl(balancer: String, title: String, serial: Boolean, qs: String = "") =
        if (qs.isNotEmpty()) "$balancer?$qs" else "$balancer?title=${e(title)}&original_title=${e(title)}&serial=${if (serial) 1 else 0}"

    // ---- Раздачи: поиск через Prowlarr на сервере Lampac (/prowlarr/search) и запуск в TorrServer ----
    data class Tor(val title: String, val tracker: String, val size: Long, val seeders: Int, val peers: Int, val link: String)

    /** Поиск раздач; ответ — массив {Title, Tracker, Size, Seeders, Peers, MagnetUri, Link}. Лишние и пустые поля игнорируются. */
    suspend fun torrentSearch(q: String): List<Tor> = withContext(Dispatchers.IO) {
        if (lampacUid.isEmpty()) throw RuntimeException("нет uid Lampac: войдите заново или впишите uid в настройках")
        val body = http.newCall(Request.Builder().url("$lampac/prowlarr/search?q=${e(q)}&uid=$lampacUid").build()).execute().use { r ->
            if (!r.isSuccessful) throw RuntimeException("HTTP ${r.code}"); r.body?.string() ?: "[]"
        }
        val arr = runCatching { JSONArray(body) }.getOrElse { throw RuntimeException(runCatching { JSONObject(body).optString("msg") }.getOrNull().orEmpty().ifEmpty { "сервер вернул не список" }) }
        (0 until arr.length()).mapNotNull { i ->
            runCatching {
                val o = arr.getJSONObject(i)
                val link = o.optString("MagnetUri").takeIf { it.startsWith("magnet:") } ?: o.optString("Link").takeIf { it.startsWith("http") } ?: return@runCatching null
                Tor(o.optString("Title"), o.optString("Tracker"), o.optLong("Size"), o.optInt("Seeders"), o.optInt("Peers"), link)
            }.getOrNull()
        }.sortedByDescending { it.seeders }
    }

    data class TorStat(val peers: Int, val total: Int, val seeders: Int, val speed: Double, val pre: Long, val preSize: Long, val text: String)

    /** Состояние раздачи в TorrServer (пиры, скорость, предзагрузка) для экрана ожидания. */
    suspend fun torrentStat(hash: String): TorStat = withContext(Dispatchers.IO) {
        val t = JSONObject(call("POST", "$ts/torrents", JSONObject().put("action", "get").put("hash", hash).toString(), false))
        TorStat(t.optInt("active_peers"), t.optInt("total_peers"), t.optInt("connected_seeders"), t.optDouble("download_speed", 0.0),
            t.optLong("preloaded_bytes"), t.optLong("preload_size"), t.optString("stat_string"))
    }

    /** Добавляет раздачу в TorrServer, ждёт список файлов и возвращает видеофайлы как элементы с готовой ссылкой на поток. */
    suspend fun torrentFiles(link: String, title: String): List<Item> = withContext(Dispatchers.IO) {
        val add = JSONObject(call("POST", "$ts/torrents", JSONObject().put("action", "add").put("link", link).put("title", title).put("save_to_db", false).toString(), false))
        val hash = add.optString("hash").ifEmpty { throw RuntimeException("TorrServer не вернул hash") }
        val vid = Regex(".*\\.(mkv|mp4|avi|m4v|mov|ts|m2ts|webm)$", RegexOption.IGNORE_CASE)
        val head = cleanTitle(title)
        val poster = add.optString("poster").ifEmpty { null } ?: tmdbPoster(head.name)
        repeat(40) {
            val t = JSONObject(call("POST", "$ts/torrents", JSONObject().put("action", "get").put("hash", hash).toString(), false))
            val fs = t.optJSONArray("file_stats")
            if (fs != null && fs.length() > 0) {
                val files = (0 until fs.length()).map { fs.getJSONObject(it) }.filter { vid.matches(it.optString("path")) }.sortedBy { it.optString("path") }
                if (files.isEmpty()) throw RuntimeException("в раздаче нет видеофайлов")
                return@withContext files.map { f ->
                    val fc = cleanTitle(f.optString("path"))
                    val season = fc.season ?: head.season
                    val lbl = if (files.size > 1) Clean("", null, season, fc.episode ?: (files.indexOf(f) + 1)).label() else head.label()
                    // overview несёт размер файла (для списка серий); sub - «2 сезон · 5 серия» для карточки «Продолжить»
                    Item("$hash:${f.optInt("id")}", head.name, lbl, "Torrent", "", "", null, 0, 0, 0.0, "%.1f ГБ".format(f.optLong("length") / 1e9),
                        hash, poster, url = "$ts/stream?link=$hash&index=${f.optInt("id")}&play")
                }
            }
            Thread.sleep(1500)
        }
        throw RuntimeException("TorrServer не получил список файлов за 60 с (нет пиров)")
    }
}
