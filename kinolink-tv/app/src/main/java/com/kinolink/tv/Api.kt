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
)

data class Stream(val index: Int, val type: String, val title: String, val codec: String, val lang: String)
data class Info(val msId: String, val psId: String, val streams: List<Stream>)

/** Лестница качества как в Lampa/Jellyfin: «Авто» = Direct Play, дальше битрейты от большего к меньшему. */
enum class Quality(val label: String, val kbps: Int, val h: Int) {
    AUTO("Авто", 0, 0),
    M100("100 Mbps", 100_000, 2160), M80("80 Mbps", 80_000, 2160), M60("60 Mbps", 60_000, 2160), M40("40 Mbps", 40_000, 2160),
    M20("20 Mbps", 20_000, 1080), M15("15 Mbps", 15_000, 1080), M10("10 Mbps", 10_000, 1080), M8("8 Mbps", 8_000, 1080), M6("6 Mbps", 6_000, 1080),
    M4("4 Mbps", 4_000, 720), M3("3 Mbps", 3_000, 720), M15b("1.5 Mbps", 1_500, 480), K720("720 kbps", 720, 360), K420("420 kbps", 420, 240)
}

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
    /** TorrServer на CT112 напрямую (порт 9085, basic-auth); через Lampac /ts его авторизация не проходит. Старый адрес :9118/ts подменяем. */
    var ts: String get() = sp.getString("ts", null)?.takeIf { !it.contains(":9118") } ?: "http://192.168.1.115:9085"; set(v) = sp.edit().putString("ts", v.trimEnd('/')).apply()
    var tsAuth: String get() = sp.getString("tsAuth", Secrets.TS_AUTH)!!; set(v) = sp.edit().putString("tsAuth", v).apply()
    fun tsHeader() = "Basic " + android.util.Base64.encodeToString(tsAuth.toByteArray(), android.util.Base64.NO_WRAP)
    var user: String get() = sp.getString("user", "")!!; set(v) = sp.edit().putString("user", v).apply()
    val loggedIn get() = token.isNotEmpty() && uid.isNotEmpty()

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
            Item(it.optString("hash"), it.optString("title", it.optString("name")), "Торрент", "Torrent", "", "", null, 0, 0, 0.0, "",
                it.optString("hash"), it.optString("poster").ifEmpty { null })
        }
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

    suspend fun balancers(): List<Pair<String, String>> = withContext(Dispatchers.IO) {
        runCatching {
            val a = JSONArray(http.newCall(Request.Builder().url("$lampac/lite/events?uid=$lampacUid").build()).execute().use { it.body!!.string() })
            (0 until a.length()).map { a.getJSONObject(it) }.map { it.getString("name") to it.getString("url").substringAfter("9118").substringAfter("8443") }
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
            val isPlay = it.optString("method") == "play"
            Row(title, if (!isPlay) it.optString("url") else null, if (isPlay) it.optString("url") else null, qm, it.optString("img").ifEmpty { null }?.let { i -> if (i.startsWith("/")) lampac + i else i })
        }
        val v = j.optJSONArray("voice")
        val voices = if (v == null) emptyList() else (0 until v.length()).map { v.getJSONObject(it) }.map { it.optString("name") + (if (it.optBoolean("active")) " ●" else "") to it.optString("url") }
        Node(j.optString("type"), voices, rows)
    }

    /** Тренды недели (TMDB через прокси Lampac): клик по карточке запускает единый поиск по названию. */
    suspend fun trending(): List<Item> = withContext(Dispatchers.IO) {
        val r = http.newCall(Request.Builder().url("$lampac/tmdb/api/3/trending/all/week?api_key=${Secrets.TMDB}&language=ru-RU&uid=$lampacUid").build()).execute().use { it.body!!.string() }
        val arr = JSONObject(r).getJSONArray("results")
        (0 until arr.length()).map { arr.getJSONObject(it) }.filter { it.optString("poster_path").isNotEmpty() }.map {
            val t = it.optString("title").ifEmpty { it.optString("name") }
            Item(it.optString("id"), t, if (it.optString("media_type") == "tv") "Сериал" else "Фильм", "Trend", "", "", null, 0, 0, it.optDouble("vote_average", 0.0), it.optString("overview"),
                null, "$lampac/tmdb/img/t/p/w500${it.optString("poster_path")}?uid=$lampacUid")
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

    fun searchUrl(balancer: String, title: String, serial: Boolean) =
        "$balancer?title=${e(title)}&original_title=${e(title)}&serial=${if (serial) 1 else 0}"

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

    /** Добавляет раздачу в TorrServer, ждёт список файлов и возвращает видеофайлы как элементы с готовой ссылкой на поток. */
    suspend fun torrentFiles(link: String, title: String): List<Item> = withContext(Dispatchers.IO) {
        val add = JSONObject(call("POST", "$ts/torrents", JSONObject().put("action", "add").put("link", link).put("title", title).put("save_to_db", false).toString(), false))
        val hash = add.optString("hash").ifEmpty { throw RuntimeException("TorrServer не вернул hash") }
        val vid = Regex(".*\\.(mkv|mp4|avi|m4v|mov|ts|m2ts|webm)$", RegexOption.IGNORE_CASE)
        repeat(40) {
            val t = JSONObject(call("POST", "$ts/torrents", JSONObject().put("action", "get").put("hash", hash).toString(), false))
            val fs = t.optJSONArray("file_stats")
            if (fs != null && fs.length() > 0) {
                val files = (0 until fs.length()).map { fs.getJSONObject(it) }.filter { vid.matches(it.optString("path")) }.sortedBy { it.optString("path") }
                if (files.isEmpty()) throw RuntimeException("в раздаче нет видеофайлов")
                return@withContext files.map { f ->
                    val name = f.optString("path").substringAfterLast('/')
                    Item("$hash:${f.optInt("id")}", name.substringBeforeLast('.'), "%.1f ГБ".format(f.optLong("length") / 1e9), "Torrent", "", "", null, 0, 0, 0.0, "",
                        url = "$ts/stream?link=$hash&index=${f.optInt("id")}&play")
                }
            }
            Thread.sleep(1500)
        }
        throw RuntimeException("TorrServer не получил список файлов за 60 с (нет пиров)")
    }
}
