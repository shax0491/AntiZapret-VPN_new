package com.kinolink.tv

import android.net.Uri
import android.os.Bundle
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.activity.enableEdgeToEdge
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.*
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import androidx.tv.foundation.lazy.grid.TvGridCells
import androidx.tv.foundation.lazy.grid.TvLazyVerticalGrid
import androidx.tv.foundation.lazy.grid.items
import androidx.tv.foundation.lazy.list.TvLazyColumn
import androidx.tv.foundation.lazy.list.TvLazyRow
import androidx.tv.foundation.lazy.list.items
import coil.compose.AsyncImage
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeoutOrNull
import androidx.compose.ui.graphics.graphicsLayer
import kotlinx.coroutines.launch
import kotlinx.coroutines.async

val Bg = Color(0xFF0B0C10)
val Bg2 = Color(0xFF12141D)
val Cyan = Color(0xFF66FCF1)
val Yellow = Color(0xFFFFD54F)

val LocalPad = compositionLocalOf { 48.dp }
val LocalCompact = compositionLocalOf { false }

@Composable
fun KField(value: String, onValueChange: (String) -> Unit, label: @Composable () -> Unit, singleLine: Boolean = true, modifier: Modifier = Modifier, visualTransformation: androidx.compose.ui.text.input.VisualTransformation = androidx.compose.ui.text.input.VisualTransformation.None, onGo: (() -> Unit)? = null) {
    OutlinedTextField(value, onValueChange, label = label, singleLine = singleLine, modifier = modifier, visualTransformation = visualTransformation,
        keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(imeAction = androidx.compose.ui.text.input.ImeAction.Search),
        keyboardActions = androidx.compose.foundation.text.KeyboardActions(onSearch = { onGo?.invoke() }),
        textStyle = androidx.compose.ui.text.TextStyle(color = Color.White, fontSize = 17.sp),
        colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
            focusedTextColor = Color.White, unfocusedTextColor = Color.White, cursorColor = Cyan,
            focusedBorderColor = Cyan, unfocusedBorderColor = Color(0xFF4A5060),
            focusedLabelColor = Cyan, unfocusedLabelColor = Color(0xFFB0B6C4), focusedContainerColor = Color(0x2212141D), unfocusedContainerColor = Color(0x2212141D)))
}

class PlayReq(val list: List<Item>, val start: Int, val voices: List<Pair<String, String>> = emptyList(), val movieVoices: Boolean = false)

fun toItems(n: Api.Node): List<Item> = n.rows.filter { it.play != null }.map { p ->
    val u = p.quality.entries.maxByOrNull { it.key.filter(Char::isDigit).toIntOrNull() ?: 0 }?.value ?: p.play!!
    Item(u, p.title, "", "Online", "", "", null, 0, 0, 0.0, "", null, null, u)
}

sealed class Screen {
    object Login : Screen()
    data class Home(val tab: Int = 0, val seed: String? = null) : Screen()
    data class Series(val item: Item) : Screen()
    data class Play(val req: PlayReq) : Screen()
    data class Detail(val item: Item) : Screen()
    data class Torrents(val item: Item) : Screen()
}

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val api = Api(this)
        setContent { App(api) }
    }
}

@Composable
fun App(api: Api) {
    var screen by remember { mutableStateOf<Screen>(if (api.loggedIn) Screen.Home() else Screen.Login) }
    var lastTab by remember { mutableIntStateOf(0) }
    var reload by remember { mutableIntStateOf(0) } // после просмотра обновляем «Продолжить»
    var splash by remember { mutableStateOf(true) }
    val cfg = androidx.compose.ui.platform.LocalConfiguration.current
    val compact = cfg.screenWidthDp < 600
    CompositionLocalProvider(LocalPad provides (if (compact) 16.dp else 48.dp), LocalCompact provides compact) {
    // вырезы камеры и системные панели (S25 Ultra, Fold): отступы везде, кроме полноэкранного плеера
    val insets = if (screen is Screen.Play) Modifier else Modifier.windowInsetsPadding(WindowInsets.systemBars.union(WindowInsets.displayCutout))
    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Bg, Bg2))).then(insets)) {
        if (splash) { SplashScreen(api) { splash = false }; return@Box }
        when (val s = screen) {
            is Screen.Login -> LoginScreen(api) { screen = Screen.Home() }
            is Screen.Home -> {
                lastTab = s.tab
                HomeScreen(api, s.tab, s.seed, reload, { t, sd -> screen = Screen.Home(t, sd) }, { screen = Screen.Login }, { open(api, it) { s2 -> screen = s2 } }, { screen = Screen.Play(it) })
            }
            is Screen.Series -> {
                BackHandler { screen = Screen.Home(lastTab) }
                SeriesScreen(api, s.item) { screen = it }
            }
            is Screen.Detail -> DetailScreen(api, s.item, { screen = it }) { screen = Screen.Home(lastTab) }
            is Screen.Torrents -> TorrentsScreen(api, s.item, { screen = it }) { screen = Screen.Detail(s.item) }
            is Screen.Play -> {
                if (api.externalPlayer) ExternalLaunch(api, s.req) { reload++; screen = Screen.Home(lastTab) }
                else PlayerScreen(api, s.req) { reload++; screen = Screen.Home(lastTab) }
            }
        }
    }
    }
}

/** Фильм/эпизод/торрент играем сразу, сериал открывает список серий. */
fun open(api: Api, it: Item, go: (Screen) -> Unit) {
    when (it.type) {
        "Series", "Movie", "Trend" -> go(Screen.Detail(it))
        else -> go(Screen.Play(PlayReq(listOf(it), 0)))
    }
}

// ---------------- UI-кирпичи ----------------

@Composable
fun Focusable(modifier: Modifier = Modifier, shape: Int = 12, onFocus: () -> Unit = {}, onClick: () -> Unit, content: @Composable BoxScope.(Boolean) -> Unit) {
    var f by remember { mutableStateOf(false) }
    val sc by animateFloatAsState(if (f) 1.07f else 1f, label = "s")
    Box(
        modifier.scale(sc).clip(RoundedCornerShape(shape.dp))
            .border(if (f) 3.dp else 0.dp, if (f) Brush.linearGradient(listOf(Cyan, Color(0xFF7C83FF))) else Brush.linearGradient(listOf(Color.Transparent, Color.Transparent)), RoundedCornerShape(shape.dp))
            .onFocusChanged { f = it.isFocused; if (it.isFocused) onFocus() }
            .clickable(onClick = onClick)
    ) { content(f) }
}

@Composable
fun Chip(text: String, selected: Boolean = false, onClick: () -> Unit) {
    Focusable(Modifier.height(if (LocalCompact.current) 44.dp else 40.dp), 20, onClick = onClick) { f ->
        Box(
            Modifier.background(if (f) Cyan else if (selected) Color(0xFF15414A) else Bg2).padding(horizontal = 18.dp).fillMaxHeight(),
            contentAlignment = Alignment.Center
        ) { Text(text, color = if (f) Bg else if (selected) Cyan else Color.White, fontSize = 15.sp, fontWeight = FontWeight.Medium) }
    }
}

@Composable
fun PosterCard(api: Api, item: Item, onFocus: (Item) -> Unit, onClick: (Item) -> Unit) {
    Focusable(Modifier.width(if (LocalCompact.current) 118.dp else 150.dp).height(if (LocalCompact.current) 177.dp else 225.dp), onFocus = { onFocus(item) }, onClick = { onClick(item) }) {
        val model = item.torrentPoster ?: api.img(item.imgId)
        Box(Modifier.fillMaxSize().background(Bg2)) {
            AsyncImage(model, item.title, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().background(Brush.verticalGradient(listOf(Color.Transparent, Color(0xEE000000)))).padding(8.dp)) {
                Text(item.title, color = Color.White, fontSize = 13.sp, maxLines = 2)
            }
            if (item.posTicks > 0 && item.runTicks > 0)
                Box(Modifier.align(Alignment.BottomStart).fillMaxWidth(item.posTicks.toFloat() / item.runTicks).height(4.dp).background(Cyan))
            if (item.rating > 0)
                Text("★ %.1f".format(item.rating), color = Yellow, fontSize = 12.sp, fontWeight = FontWeight.Bold,
                    modifier = Modifier.align(Alignment.TopEnd).background(Color(0x99000000)).padding(4.dp))
        }
    }
}

@Composable
fun Row(title: String, api: Api, items: List<Item>, onFocus: (Item) -> Unit, onClick: (Item) -> Unit) {
    if (items.isEmpty()) return
    Column(Modifier.padding(vertical = 8.dp)) {
        Text(title, color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(start = LocalPad.current, bottom = 8.dp))
        TvLazyRow(contentPadding = PaddingValues(horizontal = LocalPad.current), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            items(items) { PosterCard(api, it, onFocus, onClick) }
        }
    }
}

// ---------------- Экраны ----------------

@Composable
fun LoginScreen(api: Api, done: () -> Unit) {
    var user by remember { mutableStateOf("") }
    var pw by remember { mutableStateOf("") }
    var err by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val go = {
        if (!busy) scope.launch { busy = true; err = try { api.login(user.trim(), pw); done(); "" } catch (e: Exception) { "Не удалось войти: ${e.message}" }; busy = false }
    }
    Box(Modifier.fillMaxSize().imePadding(), contentAlignment = Alignment.Center) {
        Column(
            Modifier.widthIn(max = 460.dp).fillMaxWidth(0.92f).verticalScroll(rememberScrollState()).clip(RoundedCornerShape(24.dp)).background(Color(0xCC12141D)).border(1.dp, Color(0x3366FCF1), RoundedCornerShape(24.dp)).padding(36.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp), horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text("KINOLINK", color = Cyan, fontSize = 34.sp, fontWeight = FontWeight.Black, letterSpacing = 6.sp)
            Text("Войдите в свой аккаунт", color = Color(0xFF9AA0AE), fontSize = 15.sp)
            KField(user, { user = it }, label = { Text("Логин") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            KField(pw, { pw = it }, label = { Text("Пароль") }, singleLine = true, visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth(), onGo = { go() })
            Chip(if (busy) "Входим…" else "Войти", true) { go() }
            if (err.isNotEmpty()) Text(err, color = Color(0xFFFF6B6B), fontSize = 13.sp)
        }
    }
}

/** Заставка: логотип + бегущая лента новинок из Jellyfin (если уже вошли), плавное появление и растворение. */
@Composable
fun SplashScreen(api: Api, done: () -> Unit) {
    var posters by remember { mutableStateOf<List<Item>>(emptyList()) }
    val a = remember { androidx.compose.animation.core.Animatable(0f) }
    val shift = remember { androidx.compose.animation.core.Animatable(0f) }
    LaunchedEffect(Unit) {
        launch { shift.animateTo(1f, androidx.compose.animation.core.tween(3200, easing = androidx.compose.animation.core.LinearEasing)) }
        launch { a.animateTo(1f, androidx.compose.animation.core.tween(700)) }
        if (api.loggedIn) posters = withTimeoutOrNull(4500) { runCatching { api.catalog("Movie,Series", "DateCreated", 14) }.getOrNull() } ?: emptyList()
        delay(2600)
        a.animateTo(0f, androidx.compose.animation.core.tween(400))
        done()
    }
    Box(Modifier.fillMaxSize().background(Bg), contentAlignment = Alignment.Center) {
        if (posters.isNotEmpty()) {
            Row(Modifier.fillMaxWidth().wrapContentWidth(Alignment.Start, unbounded = true).graphicsLayer { translationX = -shift.value * 520f; alpha = 0.55f * a.value }, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                posters.forEach { AsyncImage(api.img(it.imgId), null, Modifier.width(170.dp).height(255.dp).clip(RoundedCornerShape(14.dp)), contentScale = ContentScale.Crop) }
            }
        }
        Box(Modifier.fillMaxSize().background(Brush.radialGradient(listOf(Color(0x00000000), Bg))))
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.graphicsLayer { alpha = a.value; scaleX = 0.9f + 0.1f * a.value; scaleY = 0.9f + 0.1f * a.value }) {
            Text("KINOLINK", color = Cyan, fontSize = 52.sp, fontWeight = FontWeight.Black, letterSpacing = 10.sp)
            Text("новинки кино — каждый день", color = Color(0xFFB8BECC), fontSize = 16.sp)
        }
    }
}

@Composable
fun HomeScreen(api: Api, tab: Int, seed: String?, reload: Int, setTab: (Int, String?) -> Unit, logout: () -> Unit, onOpen: (Item) -> Unit, onPlay: (PlayReq) -> Unit = {}) {
    val tabs = listOf("Главная", "Поиск", "Фильмы", "Сериалы", "Онлайн", "Торренты", "Избранное", "Настройки")
    Column(Modifier.fillMaxSize()) {
        val tabState = androidx.tv.foundation.lazy.list.rememberTvLazyListState()
        LaunchedEffect(tab) { tabState.animateScrollToItem(tab) }
        TvLazyRow(Modifier.fillMaxWidth().height(56.dp), state = tabState, contentPadding = PaddingValues(horizontal = LocalPad.current, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            items(tabs.indices.toList()) { Chip(tabs[it], it == tab) { setTab(it, null) } }
        }
        Box(Modifier.weight(1f).fillMaxWidth()) {
        when (tab) {
            0 -> HomeTab(api, reload, onOpen) { q -> setTab(1, q) }
            1 -> SearchTab(api, seed ?: "", onOpen) { url -> setTab(4, url) }
            2 -> CatalogTab(api, "Movie", onOpen)
            3 -> CatalogTab(api, "Series", onOpen)
            4 -> OnlineTab(api, seed, onPlay)
            5 -> TorrentTab(api, onOpen)
            6 -> FavoritesTab(api, onOpen)
            else -> SettingsTab(api, logout)
        }
        }
    }
}

@Composable
fun HomeTab(api: Api, reload: Int, onOpen: (Item) -> Unit, onSearch: (String) -> Unit) {
    var resume by remember { mutableStateOf<List<Item>>(emptyList()) }
    var fresh by remember { mutableStateOf<List<Item>>(emptyList()) }
    var tor by remember { mutableStateOf<List<Item>>(emptyList()) }
    var trends by remember { mutableStateOf<List<Item>>(emptyList()) }
    var movies by remember { mutableStateOf<List<Item>>(emptyList()) }
    var shows by remember { mutableStateOf<List<Item>>(emptyList()) }
    var hero by remember { mutableStateOf<Item?>(null) }
    var err by remember { mutableStateOf("") }
    LaunchedEffect(reload) {
        err = ""
        try { resume = api.resume(); fresh = api.catalog("Movie,Series", "DateCreated", 30); movies = api.catalog("Movie", "PremiereDate", 30); shows = api.catalog("Series", "PremiereDate", 30) } catch (e: Exception) { err = "Jellyfin: ${e.message}" }
        tor = runCatching { api.torrents() }.getOrDefault(emptyList()).reversed()   // последние добавленные первыми
        trends = runCatching { api.trending() }.getOrDefault(emptyList())
        hero = hero ?: fresh.firstOrNull() ?: resume.firstOrNull() ?: trends.firstOrNull()
    }
    var q by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    TvLazyColumn(Modifier.fillMaxSize()) {
        item {
            Row(Modifier.fillMaxWidth().padding(horizontal = LocalPad.current, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                KField(q, { q = it }, { Text("Искать везде: Jellyfin, Filmix, торренты") }, modifier = Modifier.weight(1f), onGo = { if (q.isNotBlank()) onSearch(q.trim()) })
                Chip("Найти") { if (q.isNotBlank()) onSearch(q.trim()) }
            }
        }
        item {
            val h = hero
            Box(Modifier.fillMaxWidth().height(if (LocalCompact.current) 210.dp else 260.dp)) {
                if (h != null) {
                    AsyncImage(h.torrentPoster ?: api.img(h.backdropId, "Backdrop", 1280), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop, alpha = 0.55f)
                    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Transparent, Bg))))
                    Column(Modifier.align(Alignment.BottomStart).padding(start = LocalPad.current, end = LocalPad.current, bottom = 16.dp).widthIn(max = 620.dp)) {
                        Text(h.title, color = Color.White, fontSize = 30.sp, fontWeight = FontWeight.Bold, maxLines = 1)
                        Text(h.sub + if (h.rating > 0) "   ★ %.1f".format(h.rating) else "", color = Yellow, fontSize = 15.sp)
                        Text(h.overview, color = Color(0xFFCCCCCC), fontSize = 13.sp, maxLines = 3)
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            Chip("Смотреть", true) { onOpen(h) }
                            if (h.type == "Movie" || h.type == "Series") {
                                var fav by remember(h.id) { mutableStateOf(false) }
                                LaunchedEffect(h.id) { fav = api.isFavorite(h.id) }
                                Chip(if (fav) "★ В избранном" else "☆ В избранное") { scope.launch { runCatching { api.setFavorite(h.id, !fav); fav = !fav } } }
                            }
                        }
                    }
                }
                if (err.isNotEmpty()) Text(err, color = Color(0xFFFF6B6B), modifier = Modifier.padding(LocalPad.current))
            }
        }
        item { Row("Продолжить просмотр", api, resume, { hero = it }, onOpen) }
        item { Row("Jellyfin: Новинки", api, fresh, { hero = it }, onOpen) }
        item { Row("Фильмы: свежие релизы", api, movies, { hero = it }, onOpen) }
        item { Row("Сериалы: свежие релизы", api, shows, { hero = it }, onOpen) }
        item { Row("Торренты (TorrServer): активные и последние", api, tor, { hero = it }, onOpen) }
        item { Row("Онлайн: тренды недели (Filmix и источники)", api, trends, { hero = it }, onOpen) }
    }
}

@Composable
fun CatalogTab(api: Api, types: String, onOpen: (Item) -> Unit) {
    val sorts = listOf("По дате релиза" to "PremiereDate", "По дате добавления" to "DateCreated", "По рейтингу" to "CommunityRating")
    var sort by remember { mutableIntStateOf(1) }
    var list by remember { mutableStateOf<List<Item>>(emptyList()) }
    LaunchedEffect(sort, types) { list = runCatching { api.catalog(types, sorts[sort].second, 120) }.getOrDefault(emptyList()) }
    Column(Modifier.fillMaxSize()) {
        TvLazyRow(contentPadding = PaddingValues(horizontal = LocalPad.current, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            items(sorts.indices.toList()) { Chip(sorts[it].first, it == sort) { sort = it } }
        }
        TvLazyVerticalGrid(TvGridCells.Adaptive(if (LocalCompact.current) 118.dp else 150.dp), modifier = Modifier.weight(1f).fillMaxWidth(), contentPadding = PaddingValues(LocalPad.current, 12.dp), horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            items(list) { PosterCard(api, it, {}, onOpen) }
        }
    }
}

fun qualityTags(t: String): List<String> {
    val l = t.lowercase(); val r = mutableListOf<String>()
    r += when { "2160" in l || "4k" in l || "uhd" in l -> "4K"; "1080" in l -> "1080p"; "720" in l -> "720p"; else -> "SD" }
    if ("hdr" in l) r += "HDR"
    if ("dolby vision" in l || Regex("\\bdv\\b").containsMatchIn(l)) r += "DV"
    if ("remux" in l) r += "Remux"
    return r
}

/** Карточка: «Смотреть» (Jellyfin), «Смотреть онлайн» (балансеры Lampac: Filmix, HDRezka, Collaps...), «Торренты» (выбор раздачи). */
@Composable
fun DetailScreen(api: Api, item: Item, go: (Screen) -> Unit, back: () -> Unit) {
    val jf = item.type == "Movie" || item.type == "Series"
    val serial = item.type == "Series" || item.sub == "Сериал"
    var balancers by remember { mutableStateOf(listOf("Filmix" to "/lite/filmix")) }
    LaunchedEffect(Unit) { balancers = api.balancers() }
    BackHandler { back() }
    Box(Modifier.fillMaxSize()) {
        AsyncImage(item.torrentPoster ?: api.img(item.backdropId, "Backdrop", 1280), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop, alpha = 0.3f)
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(LocalPad.current, 24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(item.title, color = Color.White, fontSize = 32.sp, fontWeight = FontWeight.Bold)
            Text(item.sub + if (item.rating > 0) "   ★ %.1f".format(item.rating) else "", color = Yellow, fontSize = 15.sp)
            Text(item.overview, color = Color(0xFFCCCCCC), fontSize = 14.sp, maxLines = 6)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (jf) Chip("▶ Смотреть (Jellyfin)", true) { if (item.type == "Series") go(Screen.Series(item)) else go(Screen.Play(PlayReq(listOf(item), 0))) }
                Chip("Торренты") { go(Screen.Torrents(item)) }
                Chip("← Назад") { back() }
            }
            Text("Смотреть онлайн:", color = Cyan, fontSize = 16.sp, fontWeight = FontWeight.Bold)
            TvLazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                items(balancers) { b -> Chip(b.first) { go(Screen.Home(4, api.searchUrl(b.second, item.title, serial))) } }
            }
        }
    }
}

/** Выбор раздачи: качество, размер, сиды; выбранная уходит в TorrServer и играет во встроенном плеере. */
@Composable
fun TorrentsScreen(api: Api, item: Item, go: (Screen) -> Unit, back: () -> Unit) {
    var all by remember { mutableStateOf<List<Api.Tor>>(emptyList()) }
    var msg by remember { mutableStateOf("Поиск раздач…") }
    var filter by remember { mutableIntStateOf(0) }
    var files by remember { mutableStateOf<List<Item>?>(null) }
    val scope = rememberCoroutineScope()
    val filters = listOf("Все", "4K", "1080p", "720p")
    LaunchedEffect(item.id) {
        all = runCatching { api.torrentSearch(item.title) }.getOrElse { msg = "Ошибка поиска: ${it.message}"; emptyList() }
        if (all.isNotEmpty()) msg = "" else if (msg == "Поиск раздач…") msg = "Раздач не найдено."
    }
    BackHandler { if (files != null) files = null else back() }
    val fl = files
    Column(Modifier.fillMaxSize().padding(horizontal = LocalPad.current, vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Торренты: ${item.title}", color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.Bold)
        if (fl == null) TvLazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) { items(filters.indices.toList()) { Chip(filters[it], it == filter) { filter = it } } }
        if (msg.isNotEmpty()) Text(msg, color = Yellow)
        if (fl != null) {
            Text("Выберите файл или серию:", color = Cyan)
            TvLazyColumn(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                items(fl.indices.toList()) { i ->
                    Focusable(Modifier.fillMaxWidth(), onClick = { go(Screen.Play(PlayReq(fl, i))) }) { f ->
                        Row(Modifier.background(if (f) Color(0xFF1F2833) else Bg2).padding(12.dp).fillMaxWidth()) {
                            Text(fl[i].title, color = Color.White, fontSize = 15.sp, maxLines = 2, modifier = Modifier.weight(1f)); Text(fl[i].sub, color = Cyan)
                        }
                    }
                }
            }
        } else TvLazyColumn(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            items(all.filter { filter == 0 || filters[filter] in qualityTags(it.title) }) { t ->
                Focusable(Modifier.fillMaxWidth(), onClick = {
                    msg = "Добавляю в TorrServer (ждём пиров)…"
                    scope.launch {
                        msg = try {
                            val f = api.torrentFiles(t.link, t.title)
                            if (f.size == 1) go(Screen.Play(PlayReq(f, 0))) else files = f
                            ""
                        } catch (e: Exception) { "Ошибка TorrServer: ${e.message}" }
                    }
                }) { f ->
                    Column(Modifier.background(if (f) Color(0xFF1F2833) else Bg2).padding(12.dp).fillMaxWidth()) {
                        Text(t.title, color = Color.White, fontSize = 15.sp, maxLines = 2)
                        Text(qualityTags(t.title).joinToString(" · ") + "   %.1f ГБ   ▲%d ▼%d   %s".format(t.size / 1e9, t.seeders, t.peers, t.tracker), color = if (t.seeders > 0) Cyan else Color(0xFFFF6B6B), fontSize = 13.sp)
                    }
                }
            }
        }
    }
}

@Composable
fun FavoritesTab(api: Api, onOpen: (Item) -> Unit) {
    var list by remember { mutableStateOf<List<Item>>(emptyList()) }
    var msg by remember { mutableStateOf("Загрузка…") }
    LaunchedEffect(Unit) { list = runCatching { api.favorites() }.getOrElse { msg = "Jellyfin: ${it.message}"; emptyList() }; if (list.isNotEmpty()) msg = "" else if (msg == "Загрузка…") msg = "Избранное пусто: нажмите «☆ В избранное» на главной или сердечко в Jellyfin." }
    Column(Modifier.fillMaxSize().padding(horizontal = LocalPad.current)) {
        if (msg.isNotEmpty()) Text(msg, color = Yellow, modifier = Modifier.padding(vertical = 10.dp))
        TvLazyVerticalGrid(TvGridCells.Adaptive(if (LocalCompact.current) 118.dp else 150.dp), modifier = Modifier.weight(1f).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            items(list) { PosterCard(api, it, {}, onOpen) }
        }
    }
}

/** Внешний плеер (VLC, MX Player...): отдаём прямую ссылку через ACTION_VIEW и сразу возвращаемся. */
@Composable
fun ExternalLaunch(api: Api, req: PlayReq, exit: () -> Unit) {
    val ctx = LocalContext.current
    var err by remember { mutableStateOf("") }
    LaunchedEffect(Unit) {
        try {
            val it = req.list[req.start]
            val url = when {
                it.url != null -> it.url
                it.torrentHash != null -> api.torrentUrl(it.torrentHash).replaceFirst("://", "://" + api.tsAuth + "@")
                else -> api.info(it.id).let { inf -> api.url(it.id, inf, Quality.AUTO, null).first }
            }
            ctx.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW).setDataAndType(Uri.parse(url), "video/*").putExtra("title", it.title))
            exit()
        } catch (e: Exception) { err = "Внешний плеер: ${e.message}. Включите встроенный в настройках." }
    }
    BackHandler { exit() }
    Box(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) { Text(err.ifEmpty { "Запуск внешнего плеера…" }, color = Color.White) }
}

@Composable
fun TorrentTab(api: Api, onOpen: (Item) -> Unit) {
    var list by remember { mutableStateOf<List<Item>>(emptyList()) }
    var magnet by remember { mutableStateOf("") }
    var msg by remember { mutableStateOf("") }
    var n by remember { mutableIntStateOf(0) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(n) { list = runCatching { api.torrents() }.getOrElse { msg = "TorrServer: ${it.message}"; emptyList() } }
    Column(Modifier.fillMaxSize().padding(horizontal = LocalPad.current), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            KField(magnet, { magnet = it }, label = { Text("magnet:?xt=...") }, singleLine = true, modifier = Modifier.widthIn(max = 560.dp).weight(1f))
            Chip("Добавить") { scope.launch { msg = try { api.addMagnet(magnet); magnet = ""; n++; "Добавлено" } catch (e: Exception) { "Ошибка: ${e.message}" } } }
        }
        if (msg.isNotEmpty()) Text(msg, color = Yellow)
        if (list.isEmpty() && msg.isEmpty()) Text("Раздач пока нет — вставьте magnet-ссылку и нажмите «Добавить». Нажатие на раздачу запускает поток.", color = Color(0xFF9AA0AE))
        TvLazyVerticalGrid(TvGridCells.Adaptive(if (LocalCompact.current) 118.dp else 150.dp), modifier = Modifier.weight(1f).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            items(list) { PosterCard(api, it, {}, onOpen) }
        }
    }
}

@Composable
fun SettingsTab(api: Api, logout: () -> Unit) {
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val scope = rememberCoroutineScope()
    var ts by remember { mutableStateOf(api.ts) }
    var tsa by remember { mutableStateOf(api.tsAuth) }
    var lu by remember { mutableStateOf(api.lampacUid) }
    var pw by remember { mutableStateOf("") }
    var msg by remember { mutableStateOf("") }
    val ver = remember { runCatching { ctx.packageManager.getPackageInfo(ctx.packageName, 0).let { "${it.versionName} (build ${it.longVersionCode})" } }.getOrDefault("?") }
    @Composable fun H(t: String) = Text(t, color = Cyan, fontSize = 18.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 8.dp))
    Column(Modifier.fillMaxSize().imePadding().verticalScroll(rememberScrollState()).padding(LocalPad.current), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        H("Аккаунт")
        Text("Jellyfin: ${api.user.ifEmpty { "—" }}", color = Color.White, fontSize = 16.sp)
        Chip("Выйти из аккаунта") { api.token = ""; api.uid = ""; logout() }
        H("Серверы и бэкенды")
        Text("Jellyfin: ${api.base}", color = Color(0xFFCCCCCC), fontSize = 14.sp)
        var srv by remember { mutableStateOf(api.base) }
        var ext by remember { mutableStateOf(api.externalPlayer) }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) { api.servers.forEach { s -> Chip(if ("192.168" in s) "Дома: $s" else "Внешний: ${s.substringAfter("//")}", srv == s) { api.base = s; srv = s; msg = "Сервер сменён. Выйдите и войдите заново." } } }
        KField(srv, { srv = it; api.base = it }, label = { Text("Адрес Jellyfin (свой сервер)") }, singleLine = true, modifier = Modifier.widthIn(max = 520.dp).fillMaxWidth())
        H("Плеер")
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Chip("Встроенный (ExoPlayer)", !ext) { api.externalPlayer = false; ext = false }
            Chip("Внешний (VLC, MX Player)", ext) { api.externalPlayer = true; ext = true }
        }
        KField(lu, { lu = it; api.lampacUid = it }, label = { Text("Lampac uid (Filmix и онлайн)") }, singleLine = true, modifier = Modifier.widthIn(max = 520.dp).fillMaxWidth())
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            KField(pw, { pw = it }, label = { Text("Пароль Jellyfin для обновления uid") }, singleLine = true, modifier = Modifier.widthIn(max = 380.dp).weight(1f), visualTransformation = PasswordVisualTransformation())
            Chip("Получить uid заново") { scope.launch { msg = try { api.refreshLampac(pw); lu = api.lampacUid; pw = ""; "uid обновлён" } catch (e: Exception) { "Ошибка: ${e.message}" } } }
        }
        KField(ts, { ts = it; api.ts = it }, label = { Text("Адрес TorrServer") }, singleLine = true, modifier = Modifier.widthIn(max = 520.dp).fillMaxWidth())
        KField(tsa, { tsa = it; api.tsAuth = it }, label = { Text("TorrServer логин:пароль") }, singleLine = true, modifier = Modifier.widthIn(max = 520.dp).fillMaxWidth())
        H("Система")
        Chip("Очистить кэш") { runCatching { coil.Coil.imageLoader(ctx).memoryCache?.clear(); coil.Coil.imageLoader(ctx).diskCache?.clear(); ctx.cacheDir.deleteRecursively() }; msg = "Кэш очищен" }
        Text("Версия приложения: $ver", color = Color(0xFFCCCCCC), fontSize = 14.sp)
        if (msg.isNotEmpty()) Text(msg, color = Yellow)
    }
}

@Composable
fun SeriesScreen(api: Api, series: Item, go: (Screen) -> Unit) {
    var eps by remember { mutableStateOf<List<Item>>(emptyList()) }
    LaunchedEffect(series.id) { eps = runCatching { api.episodes(series.id) }.getOrDefault(emptyList()) }
    Column(Modifier.fillMaxSize().padding(horizontal = LocalPad.current, vertical = 24.dp)) {
        Text(series.title, color = Color.White, fontSize = 30.sp, fontWeight = FontWeight.Bold)
        Text(series.overview, color = Color(0xFFCCCCCC), fontSize = 14.sp, maxLines = 3, modifier = Modifier.padding(bottom = 12.dp))
        TvLazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(eps.indices.toList()) { i ->
                val e = eps[i]
                val season = e.sub.substringAfter("· ", "").substringBefore("E")
                if (i == 0 || season != eps[i - 1].sub.substringAfter("· ", "").substringBefore("E"))
                    Text(if (season.startsWith("S")) "Сезон ${season.drop(1)}" else "Серии", color = Cyan, fontSize = 18.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 8.dp))
                Focusable(Modifier.fillMaxWidth(), onClick = { go(Screen.Play(PlayReq(eps, i))) }) { f ->
                    Row(Modifier.background(if (f) Color(0xFF1F2833) else Bg2).padding(14.dp).fillMaxWidth()) {
                        Text("${e.sub.substringAfter("· ")}  ${e.title}", color = Color.White, fontSize = 16.sp, modifier = Modifier.weight(1f))
                        if (e.posTicks > 0 && e.runTicks > 0) Text("${(100 * e.posTicks / e.runTicks)}%", color = Cyan)
                    }
                }
            }
        }
    }
}

// ---------------- Плеер ----------------

@Composable
fun PlayerScreen(api: Api, req: PlayReq, exit: () -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val player = remember {
        // TorrServer требует basic-auth и на потоке: добавляем заголовок только для его адреса
        val ds = androidx.media3.datasource.ResolvingDataSource.Factory(androidx.media3.datasource.DefaultHttpDataSource.Factory()) { spec ->
            if (spec.uri.toString().startsWith(api.ts)) spec.withAdditionalHeaders(mapOf("Authorization" to api.tsHeader())) else spec
        }
        ExoPlayer.Builder(ctx).setMediaSourceFactory(androidx.media3.exoplayer.source.DefaultMediaSourceFactory(ds)).build()
    }
    var idx by remember { mutableIntStateOf(req.start) }
    var q by remember { mutableStateOf(Quality.AUTO) }
    var audioIdx by remember { mutableStateOf<Int?>(null) }
    var info by remember { mutableStateOf<Info?>(null) }
    var ps by remember { mutableStateOf("") }
    var menu by remember { mutableStateOf<String?>(null) } // null | main | audio | subs | quality
    var tick by remember { mutableIntStateOf(0) }
    var uiUntil by remember { mutableStateOf(System.currentTimeMillis() + 4000) }   // оверлей прячется через 4 с
    fun poke() { uiUntil = System.currentTimeMillis() + 4000 }
    var err by remember { mutableStateOf("") }
    val root = remember { FocusRequester() }
    var list by remember { mutableStateOf(req.list) }
    var voices by remember { mutableStateOf(req.voices) }
    val cur = list[idx]

    // Загрузка текущей серии (при смене серии/качества/дорожки). Старый транскод гасим сразу.
    suspend fun load(startMs: Long, switchOnly: Boolean = false) {
        val item = list[idx]
        err = ""
        if (ps.isNotEmpty() && !switchOnly) { /* предыдущий PlaySessionId чистится ниже */ }
        val old = ps
        if (item.url != null) {
            player.setMediaItem(MediaItem.fromUri(item.url), 0)
        } else if (item.type == "Torrent") {
            player.setMediaItem(MediaItem.fromUri(api.torrentUrl(item.torrentHash!!)), 0)
        } else {
            val inf = if (info != null && infoFor == item.id) info!! else api.info(item.id).also { info = it; infoFor = item.id }
            val (u, nps) = api.url(item.id, inf, q, audioIdx)
            val subs = if (q == Quality.AUTO) emptyList() else inf.streams.filter { it.type == "Subtitle" }.map {
                MediaItem.SubtitleConfiguration.Builder(Uri.parse(api.subUrl(item.id, inf, it.index))).setMimeType(MimeTypes.TEXT_VTT)
                    .setLanguage(it.lang.ifEmpty { null }).setLabel(it.title).build()
            }
            player.setMediaItem(MediaItem.Builder().setUri(u).setSubtitleConfigurations(subs).build(), startMs)
            ps = nps
            if (!switchOnly) api.reportStart(item.id, inf, nps)
        }
        player.prepare(); player.playWhenReady = true
        if (old.isNotEmpty()) api.stopEncoding(old)
    }

    DisposableEffect(Unit) {
        val l = object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                if (state == Player.STATE_ENDED) scope.launch {
                    info?.let { api.reportStop(cur.id, it, ps, cur.runTicks / 10_000) }
                    if (!req.movieVoices && idx + 1 < list.size) { idx++; info = null; audioIdx = null; load(0) } else exit()
                }
            }
            override fun onPlayerError(error: androidx.media3.common.PlaybackException) { err = "Ошибка воспроизведения: ${error.errorCodeName}" }
        }
        player.addListener(l)
        scope.launch { runCatching { load(if (cur.posTicks > 0 && cur.runTicks - cur.posTicks > 600_000_000L) cur.posTicks / 10_000 else 0) }.onFailure { err = "Ошибка: ${it.message}" } }
        onDispose {
            player.removeListener(l)
            val i = info; val p = ps; val pos = player.currentPosition
            player.release()
            // отчёт о прогрессе и остановка ffmpeg после выхода, вне UI-скоупа
            kotlinx.coroutines.GlobalScope.launch {
                if (i != null && p.isNotEmpty()) { api.reportStop(list[idx].id, i, p, pos); api.stopEncoding(p) }
            }
        }
    }
    LaunchedEffect(Unit) { while (true) { delay(500); tick++; if (tick % 20 == 0) info?.let { api.reportProgress(cur.id, it, ps, player.currentPosition) } } }
    LaunchedEffect(menu) { if (menu == null) runCatching { root.requestFocus() } }
    BackHandler { if (menu != null) menu = null else exit() }

    val voiceEntries: List<Pair<String, () -> Unit>> =
        if (req.movieVoices) list.indices.map { i -> ((if (i == idx) "● " else "") + list[i].title) to { menu = null; val p = player.currentPosition; idx = i; scope.launch { load(p, true) }; Unit } }
        else voices.map { (n, u) -> n to { menu = null; scope.launch {
            runCatching { api.online(u) }.onSuccess { nd ->
                val items = toItems(nd)
                if (items.isNotEmpty()) { val p = player.currentPosition; list = items; idx = idx.coerceAtMost(items.lastIndex); voices = nd.voices; load(p, true) }
            }.onFailure { err = "Не удалось сменить озвучку: ${it.message}" }
        }; Unit } }

    fun seek(d: Long) { player.seekTo((player.currentPosition + d).coerceAtLeast(0)); poke() }
    val hasNext = !req.movieVoices && idx + 1 < list.size
    fun next() { if (hasNext) scope.launch { info?.let { api.reportStop(cur.id, it, ps, player.currentPosition) }; idx++; info = null; audioIdx = null; load(0) } }
    Box(
        Modifier.fillMaxSize().background(Color.Black).focusRequester(root).focusable()
            .pointerInput(Unit) { detectTapGestures { if (menu == null) { if (System.currentTimeMillis() < uiUntil) uiUntil = 0 else poke() } } }
            .onPreviewKeyEvent { ev ->
                if (menu != null || ev.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                poke()
                when (ev.nativeKeyEvent.keyCode) {
                    KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> { player.playWhenReady = !player.playWhenReady; true }
                    KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_MEDIA_REWIND -> { seek(-10_000); true }
                    KeyEvent.KEYCODE_DPAD_RIGHT, KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> { seek(30_000); true }
                    KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_DPAD_DOWN, KeyEvent.KEYCODE_MENU -> { menu = "main"; true }
                    KeyEvent.KEYCODE_MEDIA_NEXT -> { next(); true }
                    else -> false
                }
            }
    ) {
        AndroidView({ PlayerView(it).apply { useController = false; this.player = player; keepScreenOn = true } }, Modifier.fillMaxSize())
        val dur = player.duration.takeIf { it > 0 } ?: 1L
        key(tick) {
            val pos = player.currentPosition
            val shown = menu == null && (!player.isPlaying || System.currentTimeMillis() < uiUntil)
            if (!shown) Box(Modifier.align(Alignment.BottomStart).fillMaxWidth((pos.toFloat() / dur).coerceIn(0f, 1f)).height(3.dp).background(Cyan))
            if (shown) {
                // шапка: название и серия
                Column(Modifier.align(Alignment.TopStart).fillMaxWidth().background(Brush.verticalGradient(listOf(Color(0xCC000000), Color.Transparent))).padding(horizontal = 24.dp, vertical = 16.dp)) {
                    Text(cur.title, color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold, maxLines = 1)
                    val epi = cur.sub.ifEmpty { "" } + (if (list.size > 1 && !req.movieVoices) "   (${idx + 1} из ${list.size})" else "") + "   [${q.label}]"
                    Text(epi.trim(), color = Color(0xFFB8BECC), fontSize = 14.sp, maxLines = 1)
                }
                // низ: таймлайн и кнопки
                Column(Modifier.align(Alignment.BottomStart).fillMaxWidth().background(Brush.verticalGradient(listOf(Color.Transparent, Color(0xDD000000)))).padding(horizontal = 24.dp, vertical = 14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(fmtTime(pos), color = Color.White, fontSize = 14.sp)
                        Box(Modifier.weight(1f).height(32.dp).padding(horizontal = 12.dp)
                            .pointerInput(dur) { detectTapGestures { o -> player.seekTo((o.x / size.width * dur).toLong().coerceIn(0, dur)); poke() } }
                            .pointerInput(dur) { detectHorizontalDragGestures { ch, _ -> player.seekTo((ch.position.x / size.width * dur).toLong().coerceIn(0, dur)); poke() } }) {
                            Box(Modifier.align(Alignment.CenterStart).fillMaxWidth().height(4.dp).background(Color(0x55FFFFFF)))
                            Box(Modifier.align(Alignment.CenterStart).fillMaxWidth((pos.toFloat() / dur).coerceIn(0f, 1f)).height(4.dp).background(Cyan))
                        }
                        Text(fmtTime(if (player.duration > 0) player.duration else 0), color = Color.White, fontSize = 14.sp)
                    }
                    TvLazyRow(Modifier.fillMaxWidth().height(52.dp), horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.CenterHorizontally), verticalAlignment = Alignment.CenterVertically) {
                        item { Chip("−30 с") { seek(-30_000) } }
                        item { Chip("−10 с") { seek(-10_000) } }
                        item { Chip(if (player.isPlaying) "Пауза" else "Играть", true) { player.playWhenReady = !player.playWhenReady; poke() } }
                        item { Chip("+10 с") { seek(10_000) } }
                        item { Chip("+30 с") { seek(30_000) } }
                        if (hasNext) item { Chip("След. серия") { next() } }
                        item { Chip("Озвучка · звук · субтитры") { menu = "main" } }
                    }
                }
            }
        }
        if (err.isNotEmpty()) Text(err, color = Color(0xFFFF6B6B), fontSize = 18.sp, modifier = Modifier.align(Alignment.Center))
        menu?.let { m -> PlayerMenu(m, player, q, info, cur.url != null, voiceEntries, { menu = it }, { nq -> q = nq; menu = null; scope.launch { load(player.currentPosition, true) } },
            { a -> audioIdx = a; menu = null; scope.launch { load(player.currentPosition, true) } }) }
    }
}

private var infoFor: String = ""

@Composable
fun PlayerMenu(menu: String, player: ExoPlayer, q: Quality, info: Info?, online: Boolean, voiceNames: List<Pair<String, () -> Unit>>, setMenu: (String?) -> Unit, pickQuality: (Quality) -> Unit, pickAudio: (Int) -> Unit) {
    val fr = remember { FocusRequester() }
    LaunchedEffect(menu) { delay(100); runCatching { fr.requestFocus() } }
    val entries = mutableListOf<Pair<String, () -> Unit>>()
    var title = ""
    when (menu) {
        "main" -> {
            title = "Настройки воспроизведения"
            if (online && voiceNames.isNotEmpty()) entries += "Озвучка / перевод" to { setMenu("voice") }
            entries += "Аудиодорожки" to { setMenu("audio") }
            entries += "Субтитры" to { setMenu("subs") }
            if (!online) entries += "Качество: ${q.label}" to { setMenu("quality") }
        }
        "voice" -> { title = "Озвучка / перевод"; voiceNames.forEach { entries += it } }
        "quality" -> { title = "Качество"; Quality.values().forEach { entries += (if (it == q) "● " else "") + it.label to { pickQuality(it) } } }
        "audio" -> {
            title = "Аудиодорожки"
            if (q == Quality.AUTO) {
                player.currentTracks.groups.filter { it.type == C.TRACK_TYPE_AUDIO }.forEach { g ->
                    val f = g.mediaTrackGroup.getFormat(0)
                    entries += ((if (g.isSelected) "● " else "") + (f.label ?: f.language ?: "Дорожка") + "  ${f.sampleMimeType?.substringAfter('/') ?: ""} ${if (f.channelCount > 0) f.channelCount.toString() + "ch" else ""}") to {
                        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon().setOverrideForType(TrackSelectionOverride(g.mediaTrackGroup, 0)).build(); setMenu(null)
                    }
                }
            } else info?.streams?.filter { it.type == "Audio" }?.forEach { s -> entries += s.title to { pickAudio(s.index) } }
        }
        "subs" -> {
            title = "Субтитры"
            entries += "Выключить" to { player.trackSelectionParameters = player.trackSelectionParameters.buildUpon().setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true).build(); setMenu(null) }
            player.currentTracks.groups.filter { it.type == C.TRACK_TYPE_TEXT }.forEach { g ->
                val f = g.mediaTrackGroup.getFormat(0)
                entries += ((if (g.isSelected) "● " else "") + (f.label ?: f.language ?: "Субтитры")) to {
                    player.trackSelectionParameters = player.trackSelectionParameters.buildUpon().setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
                        .setOverrideForType(TrackSelectionOverride(g.mediaTrackGroup, 0)).build(); setMenu(null)
                }
            }
        }
    }
    Box(Modifier.fillMaxSize().background(Color(0xAA000000)), contentAlignment = Alignment.Center) {
        Column(Modifier.width(520.dp).clip(RoundedCornerShape(16.dp)).background(Bg2).padding(24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(title, color = Cyan, fontSize = 20.sp, fontWeight = FontWeight.Bold)
            if (entries.isEmpty()) Text("Нет вариантов", color = Color.Gray)
            entries.forEachIndexed { i, (label, act) ->
                Focusable(Modifier.fillMaxWidth().let { if (i == 0) it.focusRequester(fr) else it }, onClick = act) { f ->
                    Text(label, color = if (f) Bg else Color.White, fontSize = 16.sp, modifier = Modifier.fillMaxWidth().background(if (f) Cyan else Color(0xFF1A1D29)).padding(12.dp))
                }
            }
        }
    }
}

// ---------------- Filmix / онлайн через Lampac ----------------

@Composable
fun OnlineTab(api: Api, seed: String?, onPlay: (PlayReq) -> Unit) {
    var balancers by remember { mutableStateOf(listOf("Filmix" to "/lite/filmix")) }
    var bal by remember { mutableIntStateOf(0) }
    var query by remember { mutableStateOf("") }
    var serial by remember { mutableStateOf(false) }
    var stack by remember { mutableStateOf<List<Api.Node>>(emptyList()) }
    var msg by remember { mutableStateOf("") }
    var genre by remember { mutableIntStateOf(0) }
    var year by remember { mutableIntStateOf(0) }
    var cat by remember { mutableStateOf<List<Item>>(emptyList()) }
    var picked by remember { mutableStateOf<Item?>(null) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { balancers = api.balancers() }
    LaunchedEffect(serial, genre, year) { cat = emptyList(); cat = runCatching { api.discover(serial, if (serial) GENRES[genre].third else GENRES[genre].second, YEARS[year]) }.getOrDefault(emptyList()) }
    BackHandler(stack.isNotEmpty()) { stack = stack.dropLast(1) }
    fun go(url: String) = scope.launch { msg = "Загрузка…"; msg = try { stack = stack + api.online(url); "" } catch (e: Exception) { "Ошибка: ${e.message}" } }
    LaunchedEffect(seed) { if (seed != null) { stack = emptyList(); go(seed) } }
    fun best(q: Map<String, String>, fallback: String?) =
        q.entries.maxByOrNull { it.key.filter(Char::isDigit).toIntOrNull() ?: 0 }?.value ?: fallback ?: ""
    Column(Modifier.fillMaxSize().padding(horizontal = LocalPad.current), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        TvLazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) { items(balancers.indices.toList()) { Chip(balancers[it].first, it == bal) { bal = it; stack = emptyList() } } }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            KField(query, { query = it }, label = { Text("Название фильма или сериала") }, singleLine = true, modifier = Modifier.widthIn(max = 460.dp).weight(1f), onGo = { if (query.isNotBlank()) { stack = emptyList(); go(api.searchUrl(balancers[bal].second, query.trim(), serial)) } })
            Chip(if (serial) "Сериал" else "Фильм", true) { serial = !serial }
            Chip("Найти") { if (query.isNotBlank()) { stack = emptyList(); go(api.searchUrl(balancers[bal].second, query.trim(), serial)) } }
        }
        if (msg.isNotEmpty()) Text(msg, color = Yellow)
        val node = stack.lastOrNull()
        if (node != null) {
            picked?.let { p -> if (stack.size == 1) Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                AsyncImage(p.torrentPoster, null, Modifier.width(80.dp).height(120.dp).clip(RoundedCornerShape(8.dp)), contentScale = ContentScale.Crop)
                Column(Modifier.weight(1f)) {
                    Text(p.title + if (p.rating > 0) "   ★ %.1f".format(p.rating) else "", color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                    Text(p.overview, color = Color(0xFFB8BECC), fontSize = 13.sp, maxLines = 4)
                }
            } }
            if (node.voices.isNotEmpty()) TvLazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(node.voices) { (n, u) -> Chip(n, n.endsWith("●")) { go(u) } }
            }
            val playable = node.rows.filter { it.play != null }
            TvLazyColumn(Modifier.weight(1f).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                items(node.rows) { r ->
                    Focusable(Modifier.fillMaxWidth(), onClick = {
                        if (r.play != null) {
                            onPlay(PlayReq(toItems(node), playable.indexOf(r).coerceAtLeast(0), node.voices, node.type == "movie"))
                        } else if (r.link != null) go(r.link)
                    }) { f -> Text(r.title + (r.quality.keys.maxByOrNull { it.filter(Char::isDigit).toIntOrNull() ?: 0 }?.let { "   [$it]" } ?: ""), color = if (f) Bg else Color.White, fontSize = 16.sp, modifier = Modifier.fillMaxWidth().background(if (f) Cyan else Bg2).padding(12.dp)) }
                }
            }
        } else if (msg.isEmpty() || msg.startsWith("Ошибка")) {
            TvLazyRow(Modifier.fillMaxWidth().height(48.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) { items(GENRES.indices.toList()) { Chip(GENRES[it].first, it == genre) { genre = it } } }
            TvLazyRow(Modifier.fillMaxWidth().height(48.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) { items(YEARS.indices.toList()) { Chip(if (YEARS[it] == 0) "Любой год" else YEARS[it].toString(), it == year) { year = it } } }
            if (cat.isEmpty()) Text("Загружаем каталог…", color = Color(0xFF9AA0AE))
            TvLazyVerticalGrid(TvGridCells.Adaptive(if (LocalCompact.current) 118.dp else 150.dp), modifier = Modifier.weight(1f).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                items(cat) { c -> PosterCard(api, c, {}) { picked = c; query = c.title; stack = emptyList(); go(api.searchUrl(balancers[bal].second, c.title, serial)) } }
            }
        }
    }
}

// ---------------- Единый поиск ----------------

@Composable
fun SearchTab(api: Api, initial: String, onOpen: (Item) -> Unit, onOnline: (String) -> Unit) {
    var q by remember { mutableStateOf(initial) }
    var jf by remember { mutableStateOf<List<Item>>(emptyList()) }
    var tor by remember { mutableStateOf<List<Item>>(emptyList()) }
    var web by remember { mutableStateOf<List<Pair<String, String>>>(emptyList()) }
    var busy by remember { mutableStateOf(false) }
    var done by remember { mutableStateOf(false) }
    var run by remember { mutableIntStateOf(if (initial.isNotBlank()) 1 else 0) }
    LaunchedEffect(run) {
        if (q.isBlank()) return@LaunchedEffect
        busy = true; done = false
        val term = q.trim()
        kotlinx.coroutines.coroutineScope {
            // три источника параллельно; сбой одного не ломает остальные
            val a = async { runCatching { api.searchJellyfin(term) }.getOrDefault(emptyList()) }
            val b = async { runCatching { api.torrents().filter { it.title.contains(term, true) } }.getOrDefault(emptyList()) }
            val c = async {
                val path = api.balancers().firstOrNull { it.first.equals("Filmix", true) }?.second ?: "/lite/filmix"
                val out = linkedMapOf<String, String>()
                for (serial in listOf(false, true)) {
                    val url = api.searchUrl(path, term, serial)
                    val n = runCatching { api.online(url) }.getOrNull() ?: continue
                    when (n.type) {
                        "similar" -> n.rows.forEach { r -> r.link?.let { out[r.title] = it } }
                        "movie" -> out["Фильм «$term» — смотреть (${n.rows.size} озвучек)"] = url
                        "season", "episode" -> out["Сериал «$term» — сезоны и серии"] = url
                    }
                }
                out.toList()
            }
            jf = a.await(); tor = b.await(); web = c.await()
        }
        busy = false; done = true
    }
    TvLazyColumn(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        item {
            Row(Modifier.fillMaxWidth().padding(horizontal = LocalPad.current, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                KField(q, { q = it }, { Text("Название фильма или сериала") }, modifier = Modifier.weight(1f), onGo = { if (q.isNotBlank()) run++ })
                Chip("Найти") { if (q.isNotBlank()) run++ }
            }
            if (busy) Text("Ищем в Jellyfin, Filmix и TorrServer…", color = Yellow, modifier = Modifier.padding(horizontal = LocalPad.current))
            if (done && jf.isEmpty() && tor.isEmpty() && web.isEmpty()) Text("Ничего не найдено", color = Color(0xFF9AA0AE), modifier = Modifier.padding(horizontal = LocalPad.current))
        }
        item { Row("Jellyfin", api, jf, {}, onOpen) }
        item { Row("TorrServer: активные раздачи", api, tor, {}, onOpen) }
        if (web.isNotEmpty()) {
            item { Text("Онлайн: Filmix", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(start = LocalPad.current, top = 8.dp)) }
            items(web) { (title, url) ->
                Focusable(Modifier.fillMaxWidth().padding(horizontal = LocalPad.current), onClick = { onOnline(url) }) { f ->
                    Text(title, color = if (f) Bg else Color.White, fontSize = 16.sp, modifier = Modifier.fillMaxWidth().background(if (f) Cyan else Bg2).padding(12.dp))
                }
            }
        }
    }
}

private fun fmtTime(ms: Long): String {
    val s = ms / 1000
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
}

/** Жанры TMDB: название, id для фильмов, id для сериалов. */
private val GENRES = listOf(
    Triple("Все жанры", 0, 0), Triple("Боевик", 28, 10759), Triple("Комедия", 35, 35), Triple("Драма", 18, 18), Triple("Фантастика", 878, 10765),
    Triple("Триллер", 53, 9648), Triple("Мультфильм", 16, 16), Triple("Криминал", 80, 80), Triple("Семейный", 10751, 10751), Triple("Документальный", 99, 99))
private val YEARS = listOf(0, 2026, 2025, 2024, 2023, 2022, 2021, 2020, 2019, 2018)
