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
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.statusBarsPadding
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
import androidx.compose.foundation.gestures.detectDragGestures
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Replay30
import androidx.compose.material.icons.filled.Replay10
import androidx.compose.material.icons.filled.Forward10
import androidx.compose.material.icons.filled.Forward30
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.PlaylistPlay
import androidx.compose.material.icons.filled.RecordVoiceOver
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material.icons.filled.Subtitles
import androidx.compose.material.icons.filled.HighQuality
import androidx.compose.material.icons.filled.AspectRatio
import androidx.compose.material.icons.filled.BrightnessMedium
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.BookmarkBorder
import androidx.compose.animation.togetherWith
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.layout.offset
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.graphicsLayer
import androidx.media3.ui.PlayerView
import androidx.tv.foundation.lazy.grid.TvGridCells
import androidx.tv.foundation.lazy.grid.TvLazyVerticalGrid
import androidx.tv.foundation.lazy.grid.items
import androidx.tv.foundation.lazy.list.TvLazyColumn
import androidx.tv.foundation.lazy.list.TvLazyRow
import androidx.tv.foundation.lazy.list.items
import coil.compose.AsyncImage
import androidx.compose.foundation.shape.CircleShape
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
    Item(u, p.title, "", "Online", "", "", null, 0, 0, 0.0, "", null, null, u, p.quality)
}

sealed class Screen {
    object Login : Screen()
    data class Home(val tab: Int = 0, val seed: String? = null) : Screen()
    data class Series(val item: Item) : Screen()
    data class Play(val req: PlayReq) : Screen()
    data class Detail(val item: Item) : Screen()
    data class Torrents(val item: Item) : Screen()
    data class Feed(val def: FeedDef) : Screen()
}

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        runCatching { cleanTitleSelfCheck(); android.util.Log.i("KL", "cleanTitle OK") }.onFailure { android.util.Log.e("KL", "cleanTitle FAIL: ${it.message}") }
        val api = Api(this)
        setContent { App(api) }
    }
}

/** Экранная заставка: смена кадров выбранной темы с плавным переходом, часы; любое нажатие закрывает. */
@Composable
fun ScreenSaver(api: Api, dismiss: () -> Unit) {
    var imgs by remember { mutableStateOf<List<String>>(emptyList()) }
    var i by remember { mutableIntStateOf(0) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) { imgs = api.screensaverImages(api.ssTheme) }
    LaunchedEffect(imgs.size) { while (imgs.size > 1) { delay(9000); i = (i + 1) % imgs.size } }
    LaunchedEffect(Unit) { while (true) { now = System.currentTimeMillis(); delay(15_000) } }
    Box(Modifier.fillMaxSize().background(Color.Black).pointerInput(Unit) { detectTapGestures { dismiss() } }) {
        imgs.getOrNull(i)?.let { u -> androidx.compose.animation.Crossfade(u, animationSpec = androidx.compose.animation.core.tween(1800), label = "saver") { url ->
            AsyncImage(url, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        } }
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Transparent, Color(0xAA000000)))))
        val cal = java.util.Calendar.getInstance().apply { timeInMillis = now }
        Column(Modifier.align(Alignment.BottomStart).padding(40.dp)) {
            Text("%02d:%02d".format(cal.get(java.util.Calendar.HOUR_OF_DAY), cal.get(java.util.Calendar.MINUTE)), color = Color.White, fontSize = 64.sp, fontWeight = FontWeight.Light)
            Text("${DAYS_RU[cal.get(java.util.Calendar.DAY_OF_WEEK) - 1]}, ${cal.get(java.util.Calendar.DAY_OF_MONTH)} ${MONTHS_RU[cal.get(java.util.Calendar.MONTH)]}", color = Color(0xFFDDDDDD), fontSize = 20.sp)
        }
    }
}

@Composable
fun App(api: Api) {
    var screen by remember { mutableStateOf<Screen>(if (api.loggedIn) Screen.Home() else Screen.Login) }
    var lastTab by remember { mutableIntStateOf(0) }
    var reload by remember { mutableIntStateOf(0) } // после просмотра обновляем «Продолжить»
    var splash by remember { mutableStateOf(true) }
    var lastInput by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var saver by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { while (true) { delay(3000); saver = api.ssOn && !splash && screen !is Screen.Play && screen !is Screen.Login && System.currentTimeMillis() - lastInput > api.ssMin * 60_000L } }
    LaunchedEffect(reload) { api.probeTs() }   // дома или снаружи: от этого зависит адрес TorrServer
    LaunchedEffect(Unit) { api.ensureUser() }
    val cfg = androidx.compose.ui.platform.LocalConfiguration.current
    val compact = cfg.screenWidthDp < 600
    CompositionLocalProvider(LocalPad provides (if (compact) 16.dp else 48.dp), LocalCompact provides compact) {
    // вырезы камеры и системные панели (S25 Ultra, Fold): отступы везде, кроме полноэкранного плеера
    val insets = if (screen is Screen.Play) Modifier else Modifier.windowInsetsPadding(WindowInsets.systemBars.union(WindowInsets.displayCutout))
    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Bg, Bg2))).then(insets)
        .pointerInput(Unit) { awaitPointerEventScope { while (true) { awaitPointerEvent(androidx.compose.ui.input.pointer.PointerEventPass.Initial); lastInput = System.currentTimeMillis() } } }
        .onPreviewKeyEvent { lastInput = System.currentTimeMillis(); if (saver) { saver = false; true } else false }) {
        if (saver) { ScreenSaver(api) { saver = false; lastInput = System.currentTimeMillis() }; return@Box }
        if (splash) { SplashScreen(api) { splash = false }; return@Box }
        androidx.compose.animation.AnimatedContent(screen, contentKey = { it::class },
            transitionSpec = { (androidx.compose.animation.fadeIn(androidx.compose.animation.core.tween(300)) + androidx.compose.animation.slideInVertically(androidx.compose.animation.core.tween(300)) { it / 24 }) togetherWith androidx.compose.animation.fadeOut(androidx.compose.animation.core.tween(160)) },
            label = "screen") { s ->
        when (s) {
            is Screen.Login -> LoginScreen(api) { screen = Screen.Home() }
            is Screen.Home -> {
                lastTab = s.tab
                HomeScreen(api, s.tab, s.seed, reload, { t, sd -> screen = Screen.Home(t, sd) }, { screen = Screen.Login }, { open(api, it) { s2 -> screen = s2 } }, { screen = Screen.Play(it) }, { screen = Screen.Feed(it) })
            }
            is Screen.Series -> {
                BackHandler { screen = Screen.Home(lastTab) }
                SeriesScreen(api, s.item) { screen = it }
            }
            is Screen.Detail -> DetailScreen(api, s.item, { screen = it }) { screen = Screen.Home(lastTab) }
            is Screen.Feed -> FeedScreen(api, s.def, { open(api, it) { s2 -> screen = s2 } }) { screen = Screen.Home(lastTab) }
            is Screen.Torrents -> TorrentsScreen(api, s.item, { screen = it }) { screen = Screen.Detail(s.item) }
            is Screen.Play -> {
                if (api.externalPlayer) ExternalLaunch(api, s.req) { reload++; screen = Screen.Home(lastTab) }
                else PlayerScreen(api, s.req) { reload++; screen = Screen.Home(lastTab) }
            }
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

/** Кнопка панели плеера: значок + (необязательно) подпись. */
@Composable
fun CtrlBtn(glyph: String, label: String = "", big: Boolean = false, onClick: () -> Unit) {
    Focusable(Modifier.height(44.dp), 22, onClick = onClick) { f ->
        Row(Modifier.background(if (f) Cyan else Color(0x99000000)).border(1.dp, Color(0x33FFFFFF), RoundedCornerShape(22.dp)).padding(horizontal = 18.dp).fillMaxHeight(),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (glyph.isNotEmpty()) Text(glyph, color = if (f) Bg else Color.White, fontSize = 26.sp, fontWeight = FontWeight.Bold)
            if (label.isNotEmpty()) Text(label, color = if (f) Bg else Color.White, fontSize = 15.sp, fontWeight = FontWeight.Medium)
        }
    }
}

/** Круглая кнопка-значок панели плеера; подпись появляется при фокусе (пульт) как подсказка. */
@Composable
fun IconBtn(icon: androidx.compose.ui.graphics.vector.ImageVector, desc: String, hint: (String) -> Unit = {}, size: Int = 52, onClick: () -> Unit) {
    Focusable(Modifier.size(size.dp), size / 2, onFocus = { hint(desc) }, onClick = onClick) { f ->
        Box(Modifier.fillMaxSize().background(if (f) Cyan else Color(0x99000000)).border(1.dp, Color(0x33FFFFFF), CircleShape), contentAlignment = Alignment.Center) {
            androidx.compose.material3.Icon(icon, desc, tint = if (f) Bg else Color.White, modifier = Modifier.size((size * 0.54f).dp))
        }
    }
}

/** Кнопка со значком и словом (карточка фильма). */
@Composable
fun LabelBtn(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, primary: Boolean = false, onClick: () -> Unit) {
    Focusable(Modifier.height(52.dp), 26, onClick = onClick) { f ->
        Row(Modifier.background(if (f) Cyan else if (primary) Color(0xFF15414A) else Color(0x99000000)).border(1.dp, Color(0x33FFFFFF), RoundedCornerShape(26.dp)).padding(horizontal = 20.dp).fillMaxHeight(),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            androidx.compose.material3.Icon(icon, label, tint = if (f) Bg else if (primary) Cyan else Color.White, modifier = Modifier.size(26.dp))
            Text(label, color = if (f) Bg else if (primary) Cyan else Color.White, fontSize = 16.sp, fontWeight = FontWeight.Medium)
        }
    }
}

/** Большая круглая кнопка Play/Pause: фигуры рисуются, без шрифтовых значков. */
@Composable
fun PlayBtn(playing: Boolean, onClick: () -> Unit) {
    Focusable(Modifier.size(72.dp), 36, onClick = onClick) { f ->
        Box(Modifier.fillMaxSize().background(if (f) Cyan else Color.White), contentAlignment = Alignment.Center) {
            androidx.compose.foundation.Canvas(Modifier.size(30.dp)) {
                val c = Bg
                if (playing) {
                    drawRect(c, topLeft = androidx.compose.ui.geometry.Offset(size.width * 0.12f, 0f), size = androidx.compose.ui.geometry.Size(size.width * 0.27f, size.height))
                    drawRect(c, topLeft = androidx.compose.ui.geometry.Offset(size.width * 0.61f, 0f), size = androidx.compose.ui.geometry.Size(size.width * 0.27f, size.height))
                } else {
                    val path = androidx.compose.ui.graphics.Path().apply { moveTo(size.width * 0.18f, 0f); lineTo(size.width, size.height / 2); lineTo(size.width * 0.18f, size.height); close() }
                    drawPath(path, c)
                }
            }
        }
    }
}

@Composable
fun PosterCard(api: Api, item: Item, onFocus: (Item) -> Unit, onClick: (Item) -> Unit) {
    val w = if (LocalCompact.current) 118.dp else 150.dp
    // постер сверху, название и сезон/серия — под ним (не поверх картинки)
    Column(Modifier.width(w)) {
        Focusable(Modifier.fillMaxWidth().height(w * 1.5f), onFocus = { onFocus(item) }, onClick = { onClick(item) }) {
            val model = item.torrentPoster ?: api.img(item.imgId)
            Box(Modifier.fillMaxSize().background(Bg2)) {
                AsyncImage(model, item.title, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                if (item.posTicks > 0 && item.runTicks > 0)
                    Box(Modifier.align(Alignment.BottomStart).fillMaxWidth(item.posTicks.toFloat() / item.runTicks).height(4.dp).background(Cyan))
                if (item.rating > 0)
                    Text("★ %.1f".format(item.rating), color = Yellow, fontSize = 12.sp, fontWeight = FontWeight.Bold,
                        modifier = Modifier.align(Alignment.TopEnd).background(Color(0x99000000)).padding(4.dp))
            }
        }
        Text(item.title, color = Color.White, fontSize = 13.sp, maxLines = 2, minLines = 2, lineHeight = 16.sp, modifier = Modifier.padding(top = 8.dp, start = 2.dp, end = 2.dp))
        val sub = if (item.type == "Episode") item.sub.substringAfter(" · ", item.sub) else item.sub
        Text(sub, color = if (item.type == "Torrent" || item.type == "Episode") Cyan else Color(0xFF9AA0AE), fontSize = 11.sp, maxLines = 1, modifier = Modifier.padding(start = 2.dp, end = 2.dp, bottom = 2.dp))
    }
}

/** «Продолжить просмотр»: горизонтальная карточка 16:9 - кадр, сериал, сезон/серия, таймкод, остаток и полоса прогресса. */
@Composable
fun ContinueCard(api: Api, c: Item, onClick: (Item) -> Unit) {
    val w = if (LocalCompact.current) 250.dp else 320.dp
    val ep = Regex("S(\\d+)E(\\d+)").find(c.sub)
    val series = if (c.type == "Episode") c.sub.substringBefore(" · ").ifBlank { c.title } else c.title
    val label = when { ep != null -> "${ep.groupValues[1]} сезон · ${ep.groupValues[2]} серия"; c.type == "Torrent" -> c.sub; else -> "" }
    val posMs = c.posTicks / 10_000; val durMs = c.runTicks / 10_000
    val frac = if (durMs > 0) (posMs.toFloat() / durMs).coerceIn(0f, 1f) else 0f
    val left = if (durMs > posMs) "осталось ${(durMs - posMs) / 60_000 + 1} мин" else ""
    Column(Modifier.width(w)) {
        Focusable(Modifier.fillMaxWidth().height(w * 9 / 16), onClick = { onClick(c) }) {
            Box(Modifier.fillMaxSize().background(Bg2)) {
                val model = when (c.type) {
                    "Torrent" -> c.torrentPoster
                    "Episode" -> api.img(c.imgId, "Primary", 640)
                    else -> api.img(c.backdropId.ifEmpty { c.imgId }, "Backdrop", 640)
                }
                AsyncImage(model, series, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(56.dp).background(Brush.verticalGradient(listOf(Color.Transparent, Color(0xDD000000)))))
                Text("▶", color = Color.White, fontSize = 28.sp, modifier = Modifier.align(Alignment.Center).background(Color(0x66000000), CircleShape).padding(horizontal = 14.dp, vertical = 6.dp))
                if (durMs > 0) Text("${fmtTime(posMs)} / ${fmtTime(durMs)}", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Medium, modifier = Modifier.align(Alignment.BottomEnd).padding(end = 8.dp, bottom = 9.dp))
                Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(5.dp).background(Color(0x66FFFFFF)))
                Box(Modifier.align(Alignment.BottomStart).fillMaxWidth(frac).height(5.dp).background(Cyan))
            }
        }
        Text(series, color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.Bold, maxLines = 1, modifier = Modifier.padding(top = 8.dp, start = 2.dp))
        if (label.isNotEmpty()) Text(label, color = Cyan, fontSize = 13.sp, maxLines = 1, modifier = Modifier.padding(start = 2.dp))
        val extra = listOf(if (c.type == "Episode") c.title else "", left).filter { x -> x.isNotEmpty() }.joinToString(" · ")
        if (extra.isNotEmpty()) Text(extra, color = Color(0xFF9AA0AE), fontSize = 12.sp, maxLines = 1, modifier = Modifier.padding(start = 2.dp, bottom = 2.dp))
    }
}

@Composable
fun ContinueRow(api: Api, items: List<Item>, onClick: (Item) -> Unit) {
    if (items.isEmpty()) {
        // Jellyfin убирает из «Продолжить» просмотренное больше 90 %, поэтому пустой ряд оставляем видимым с подсказкой
        Column(Modifier.padding(vertical = 8.dp)) {
            Text("Продолжить просмотр", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(start = LocalPad.current, bottom = 6.dp))
            Text("Начатых просмотров пока нет — здесь появится то, что вы не досмотрели", color = Color(0xFF9AA0AE), fontSize = 14.sp, modifier = Modifier.padding(start = LocalPad.current, bottom = 8.dp))
        }
        return
    }
    Column(Modifier.padding(vertical = 8.dp)) {
        Text("Продолжить просмотр", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(start = LocalPad.current, bottom = 8.dp))
        TvLazyRow(contentPadding = PaddingValues(horizontal = LocalPad.current), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            items(items) { ContinueCard(api, it, onClick) }
        }
    }
}

@Composable
fun Row(title: String, api: Api, items: List<Item>, onFocus: (Item) -> Unit, onClick: (Item) -> Unit, onMore: (() -> Unit)? = null) {
    if (items.isEmpty()) return
    var vis by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { vis = true }
    val al by animateFloatAsState(if (vis) 1f else 0f, androidx.compose.animation.core.tween(550), label = "ra")
    val off by animateDpAsState(if (vis) 0.dp else 28.dp, androidx.compose.animation.core.tween(550), label = "ro")
    Column(Modifier.padding(vertical = 8.dp).offset(y = off).alpha(al)) {
        Row(Modifier.padding(start = LocalPad.current, bottom = 8.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(title, color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold)
            if (onMore != null) Chip("Ещё ›") { onMore() }   // полный экран ленты: сетка + сортировка
        }
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

private val CAT_MOVIES = FeedDef("Фильмы", false, "", "pop", 0)
private val CAT_SERIES = FeedDef("Сериалы", true, "", "pop", 0)
private val CAT_CARTOONS = FeedDef("Мультфильмы", false, "with_genres=16", "pop", 0)
private val CAT_ANIME = FeedDef("Аниме", true, "with_genres=16&with_original_language=ja", "pop", 0)

private val MONTHS_RU = listOf("Января", "Февраля", "Марта", "Апреля", "Мая", "Июня", "Июля", "Августа", "Сентября", "Октября", "Ноября", "Декабря")
private val DAYS_RU = listOf("Воскресенье", "Понедельник", "Вторник", "Среда", "Четверг", "Пятница", "Суббота")

/** Логотип: настоящий значок приложения (тот же, что на рабочем столе). */
@Composable
fun LogoMark(size: Int = 40) {
    val ctx = LocalContext.current
    AndroidView({ c -> android.widget.ImageView(c).apply { setImageDrawable(ctx.packageManager.getApplicationIcon(ctx.packageName)) } }, Modifier.size(size.dp).clip(RoundedCornerShape((size / 4).dp)))
}

/** Верхняя строка как в Lampa: логотип слева; поиск, уведомления, профиль Jellyfin, время и дата справа. */
@Composable
fun TopBar(api: Api, onSearch: () -> Unit, logout: () -> Unit) {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) { while (true) { now = System.currentTimeMillis(); delay(15_000) } }
    var profile by remember { mutableStateOf(false) }
    var notif by remember { mutableStateOf(false) }
    var uname by remember { mutableStateOf(api.user) }
    LaunchedEffect(Unit) { runCatching { api.ensureUser(); uname = api.user } }
    val cal = remember(now) { java.util.Calendar.getInstance().apply { timeInMillis = now } }
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        LogoMark()
        Spacer(Modifier.weight(1f))
        IconBtn(Icons.Filled.Search, "Поиск", size = 44) { onSearch() }
        Box {
            IconBtn(Icons.Filled.Notifications, "Уведомления", size = 44) { notif = true }
            androidx.compose.material3.DropdownMenu(notif, { notif = false }) {
                androidx.compose.material3.DropdownMenuItem(text = { Text("Новых уведомлений нет") }, onClick = { notif = false })
            }
        }
        Box {
            Focusable(Modifier.size(44.dp), 22, onClick = { profile = true }) {
                Box(Modifier.fillMaxSize().background(Color(0xFF2A3A4A)), contentAlignment = Alignment.Center) {
                    Text(uname.take(1).uppercase(), color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                    if (api.uid.isNotEmpty()) AsyncImage("${api.base}/Users/${api.uid}/Images/Primary?maxWidth=96&api_key=${api.token}", null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                }
            }
            androidx.compose.material3.DropdownMenu(profile, { profile = false }) {
                androidx.compose.material3.DropdownMenuItem(text = { Text(uname.ifEmpty { "Профиль" }) }, onClick = { profile = false })
                androidx.compose.material3.DropdownMenuItem(text = { Text("Сменить пользователя") }, onClick = { profile = false; logout() })
                androidx.compose.material3.DropdownMenuItem(text = { Text("Выход") }, onClick = { profile = false; logout() })
            }
        }
        Text("%02d:%02d".format(cal.get(java.util.Calendar.HOUR_OF_DAY), cal.get(java.util.Calendar.MINUTE)), color = Color.White, fontSize = 26.sp, fontWeight = FontWeight.Medium)
        Column {
            Text("${cal.get(java.util.Calendar.DAY_OF_MONTH)} ${MONTHS_RU[cal.get(java.util.Calendar.MONTH)]} ${cal.get(java.util.Calendar.YEAR)}", color = Color(0xFFB8BECC), fontSize = 11.sp, maxLines = 1)
            Text(DAYS_RU[cal.get(java.util.Calendar.DAY_OF_WEEK) - 1], color = Color(0xFFB8BECC), fontSize = 11.sp, maxLines = 1)
        }
    }
}

/** История: недосмотренное в Jellyfin и свои торренты пользователя. */
@Composable
fun HistoryTab(api: Api, onOpen: (Item) -> Unit) {
    var list by remember { mutableStateOf<List<Item>>(emptyList()) }
    var done by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { list = api.history() + runCatching { api.resume() }.getOrDefault(emptyList()); done = true }
    Column(Modifier.fillMaxSize().padding(horizontal = LocalPad.current)) {
        if (done && list.isEmpty()) Text("История пуста: здесь появится то, что вы начали смотреть", color = Yellow, modifier = Modifier.padding(vertical = 10.dp))
        TvLazyVerticalGrid(TvGridCells.Adaptive(if (LocalCompact.current) 118.dp else 150.dp), modifier = Modifier.weight(1f).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            items(list) { PosterCard(api, it, {}, onOpen) }
        }
    }
}

@Composable
fun HomeScreen(api: Api, tab: Int, seed: String?, reload: Int, setTab: (Int, String?) -> Unit, logout: () -> Unit, onOpen: (Item) -> Unit, onPlay: (PlayReq) -> Unit = {}, onFeed: (FeedDef) -> Unit = {}) {
    // меню: Главная, Фильмы, Сериалы, Мультфильмы, Аниме, Избранное, История, Торренты, Настройки; поиск, онлайн-источники и карточки открываются отдельно
    val menu = listOf("Главная" to 0, "Фильмы" to 2, "Сериалы" to 3, "Мультфильмы" to 8, "Аниме" to 9, "Избранное" to 6, "История" to 10, "Торренты" to 5, "Настройки" to 7)
    Column(Modifier.fillMaxSize()) {
        TopBar(api, { setTab(1, null) }) { api.token = ""; api.uid = ""; logout() }
        val tabState = androidx.tv.foundation.lazy.list.rememberTvLazyListState()
        LaunchedEffect(tab) { tabState.animateScrollToItem(menu.indexOfFirst { it.second == tab }.coerceAtLeast(0)) }
        TvLazyRow(Modifier.fillMaxWidth().height(56.dp), state = tabState, contentPadding = PaddingValues(horizontal = 16.dp, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            items(menu) { (name, target) -> Chip(name, target == tab) { setTab(target, null) } }
        }
        Box(Modifier.weight(1f).fillMaxWidth()) {
            androidx.compose.animation.Crossfade(tab, animationSpec = androidx.compose.animation.core.tween(240), label = "tab") { tb ->
            when (tb) {
                0 -> HomeTab(api, reload, onOpen, onFeed) { q -> setTab(1, q) }
                1 -> SearchTab(api, seed ?: "", onOpen) { url -> setTab(4, url) }
                2 -> FeedScreen(api, CAT_MOVIES, onOpen) { setTab(0, null) }
                3 -> FeedScreen(api, CAT_SERIES, onOpen) { setTab(0, null) }
                4 -> OnlineTab(api, seed, onPlay)
                5 -> TorrentTab(api, onOpen)
                6 -> FavoritesTab(api, onOpen)
                8 -> FeedScreen(api, CAT_CARTOONS, onOpen) { setTab(0, null) }
                9 -> FeedScreen(api, CAT_ANIME, onOpen) { setTab(0, null) }
                10 -> HistoryTab(api, onOpen)
                else -> SettingsTab(api, logout)
            }
            }
        }
    }
}

private val TODAY: String get() = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).format(java.util.Date())

/** Лента TMDB: sort = pop (популярные) / date (новинки) / top (лучшие); filter - доп. условие discover (дорамы: язык ko). */
data class FeedDef(val name: String, val serial: Boolean, val filter: String, val sort: String, val minVotes: Int)

/** Ленты главной (как в Lampa). Порядок = порядок на экране. */
private val WEEK_AGO: String get() = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).format(java.util.Date(System.currentTimeMillis() - 7 * 86_400_000L))
private val WEEK_AHEAD: String get() = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).format(java.util.Date(System.currentTimeMillis() + 7 * 86_400_000L))
private val HOME_FEEDS: List<FeedDef> get() = listOf(
    FeedDef("Дорамы Кореи", true, "with_original_language=ko", "pop", 0),
    FeedDef("Выходы эпизодов", true, "air_date.gte=$WEEK_AGO&air_date.lte=$WEEK_AHEAD", "pop", 0),
    FeedDef("Фильмы: новинки", false, "", "date", 15), FeedDef("Фильмы: популярное", false, "", "pop", 0),
    FeedDef("Сериалы: новинки", true, "", "date", 5), FeedDef("Сериалы: популярное", true, "", "pop", 0),
)

fun feedQuery(f: FeedDef, sort: String): String {
    val date = if (f.serial) "first_air_date" else "primary_release_date"
    val by = when (sort) { "date" -> "$date.desc&$date.lte=$TODAY"; "top" -> "vote_average.desc"; else -> "popularity.desc" }
    val votes = when (sort) { "top" -> maxOf(f.minVotes, 300); "date" -> f.minVotes; else -> 0 }
    return "discover/${if (f.serial) "tv" else "movie"}?sort_by=$by&vote_count.gte=$votes" + if (f.filter.isNotEmpty()) "&${f.filter}" else ""
}

/** Полный экран ленты: сетка с сортировкой и подгрузкой страниц («Ещё»). */
@Composable
fun FeedScreen(api: Api, def: FeedDef, onOpen: (Item) -> Unit, back: () -> Unit) {
    var sort by remember { mutableStateOf(def.sort) }       // pop | top | date | az
    var items by remember { mutableStateOf<List<Item>>(emptyList()) }
    var page by remember { mutableIntStateOf(1) }
    var busy by remember { mutableStateOf(false) }
    var more by remember { mutableStateOf(true) }
    val scope = rememberCoroutineScope()
    fun loadPage(reset: Boolean) {
        if (busy) return
        scope.launch {
            busy = true
            val p = if (reset) 1 else page + 1
            val l = runCatching { api.tmdbList(feedQuery(def, if (sort == "az") "pop" else sort), def.serial, p) }.getOrDefault(emptyList())
            items = if (reset) l else (items + l).distinctBy { it.id }
            page = p; more = l.size >= 15; busy = false
        }
    }
    LaunchedEffect(sort) { busy = false; loadPage(true) }
    BackHandler { back() }
    val shown = if (sort == "az") items.sortedBy { it.title.lowercase() } else items
    Column(Modifier.fillMaxSize().padding(horizontal = LocalPad.current), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
            Chip("← Назад") { back() }
            Text(def.name, color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.Bold)
        }
        TvLazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            items(listOf("pop" to "Популярные", "top" to "По рейтингу", "date" to "Новые", "az" to "А–Я")) { (k, n) -> Chip(n, sort == k) { sort = k } }
        }
        TvLazyVerticalGrid(TvGridCells.Adaptive(if (LocalCompact.current) 118.dp else 150.dp), modifier = Modifier.weight(1f).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            items(shown) { PosterCard(api, it, {}, onOpen) }
            if (more && shown.isNotEmpty()) item { Chip(if (busy) "Загрузка…" else "Показать ещё") { loadPage(false) } }
        }
        if (busy && shown.isEmpty()) Text("Загрузка…", color = Yellow)
    }
}

@Composable
fun HomeTab(api: Api, reload: Int, onOpen: (Item) -> Unit, onFeed: (FeedDef) -> Unit, onSearch: (String) -> Unit) {
    var resume by remember { mutableStateOf<List<Item>>(emptyList()) }
    var libMovies by remember { mutableStateOf<List<Item>>(emptyList()) }
    var libSeries by remember { mutableStateOf<List<Item>>(emptyList()) }
    var trends by remember { mutableStateOf<List<Item>>(emptyList()) }
    var feed by remember { mutableStateOf<Map<String, List<Item>>>(emptyMap()) }   // ленты TMDB как в Lampa
    var hero by remember { mutableStateOf<Item?>(null) }
    var err by remember { mutableStateOf("") }
    LaunchedEffect(reload) {
        err = ""
        // «Продолжить»: свои торренты пользователя (с названием, постером, серией) сразу, Jellyfin подтянется следом
        val hist = api.history()
        resume = hist
        // ленты грузятся параллельно и появляются по мере готовности
        kotlinx.coroutines.coroutineScope {
            launch { try { resume = hist + api.resume() } catch (e: Exception) { err = "Jellyfin: ${e.message}" } }
            launch { runCatching { libMovies = api.catalog("Movie", "DateCreated", 30); hero = hero ?: libMovies.firstOrNull() } }
            launch { runCatching { libSeries = api.catalog("Series", "DateCreated", 30) } }
            launch { trends = runCatching { api.trending() }.getOrDefault(emptyList()); hero = hero ?: trends.firstOrNull() }
            HOME_FEEDS.forEach { f -> launch { val l = runCatching { api.tmdbList(feedQuery(f, f.sort), f.serial) }.getOrDefault(emptyList()); feed = feed + (f.name to l) } }
        }
        hero = hero ?: resume.firstOrNull()
    }
    var q by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    TvLazyColumn(Modifier.fillMaxSize()) {
        item {
            // верх: сменяемые баннеры новинок (библиотека Jellyfin + новые фильмы и сериалы TMDB), каждые 6 с
            val banners = remember(libMovies, libSeries, feed) {
                val a1 = libMovies.take(2) + libSeries.take(1); val b1 = (feed["Фильмы: новинки"] ?: emptyList()).take(3); val c1 = (feed["Сериалы: новинки"] ?: emptyList()).take(3)
                (0 until 3).flatMap { i -> listOfNotNull(a1.getOrNull(i), b1.getOrNull(i), c1.getOrNull(i)) }.filter { it.backdropId.isNotEmpty() }
            }
            var bi by remember { mutableIntStateOf(0) }
            LaunchedEffect(banners.size) { while (banners.size > 1) { delay(6000); bi = (bi + 1) % banners.size } }
            val h = banners.getOrNull(bi) ?: hero
            // clipToBounds: иначе наезд камеры (scale) выходит за баннер и виден полоской под ним
            Box(Modifier.fillMaxWidth().aspectRatio(16f / 9f).heightIn(max = 460.dp).clipToBounds()) {
                if (h != null) {
                    androidx.compose.animation.Crossfade(h, animationSpec = androidx.compose.animation.core.tween(700), label = "banner") { b ->
                        Box(Modifier.fillMaxSize()) {
                            val zoom by androidx.compose.animation.core.rememberInfiniteTransition(label = "kb").animateFloat(1f, 1.09f,
                                androidx.compose.animation.core.infiniteRepeatable(androidx.compose.animation.core.tween(9000, easing = androidx.compose.animation.core.LinearEasing), androidx.compose.animation.core.RepeatMode.Reverse), label = "kbz")
                            AsyncImage(if (b.backdropId.startsWith("http")) b.backdropId else api.img(b.backdropId, "Backdrop", 1280), null, Modifier.fillMaxSize().graphicsLayer { scaleX = zoom; scaleY = zoom }, contentScale = ContentScale.Crop, alignment = Alignment.TopCenter, alpha = 0.75f)
                            Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Transparent, Bg))))
                            Column(Modifier.align(Alignment.BottomStart).padding(start = LocalPad.current, end = LocalPad.current, bottom = 22.dp).widthIn(max = 620.dp)) {
                                Text(b.title, color = Color.White, fontSize = 30.sp, fontWeight = FontWeight.Bold, maxLines = 1)
                                Text(b.sub + if (b.rating > 0) "   ★ %.1f".format(b.rating) else "", color = Yellow, fontSize = 15.sp)
                                Text(b.overview, color = Color(0xFFCCCCCC), fontSize = 13.sp, maxLines = 2)
                                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                    Chip("Смотреть", true) { onOpen(b) }
                                    if (b.type == "Movie" || b.type == "Series") {
                                        var fav by remember(b.id) { mutableStateOf(false) }
                                        LaunchedEffect(b.id) { fav = api.isFavorite(b.id) }
                                        Chip(if (fav) "★ В избранном" else "☆ В избранное") { scope.launch { runCatching { api.setFavorite(b.id, !fav); fav = !fav } } }
                                    }
                                }
                            }
                        }
                    }
                    if (banners.size > 1) Row(Modifier.align(Alignment.BottomEnd).padding(end = LocalPad.current, bottom = 8.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        banners.indices.forEach { i -> Box(Modifier.size(if (i == bi) 9.dp else 6.dp).clip(CircleShape).background(if (i == bi) Cyan else Color(0x66FFFFFF))) }
                    }
                }
                if (err.isNotEmpty()) Text(err, color = Color(0xFFFF6B6B), modifier = Modifier.padding(LocalPad.current))
            }
        }
        item { ContinueRow(api, resume, onOpen) }
        item { Row("Тренды", api, trends, { hero = it }, onOpen) }
        item { Row("Новые фильмы в медиатеке", api, libMovies, { hero = it }, onOpen) }
        item { Row("Новые сериалы в медиатеке", api, libSeries, { hero = it }, onOpen) }
        HOME_FEEDS.forEach { f -> item { Row(f.name, api, feed[f.name] ?: emptyList(), { hero = it }, onOpen) { onFeed(f) } } }
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

/** Карточка как в Lampa: постер слева, год и страна, название, слоган, плашки, кнопки; ниже «Подробно», люди с фото, рекомендации и похожие. */
@Composable
fun DetailScreen(api: Api, item: Item, go: (Screen) -> Unit, back: () -> Unit) {
    val jf = item.type == "Movie" || item.type == "Series"
    val serial = item.type == "Series" || item.sub == "Сериал"
    var tm by remember(item.id) { mutableStateOf<Api.Tmdb?>(null) }
    var full by remember(item.id) { mutableStateOf<Api.TmdbFull?>(null) }
    LaunchedEffect(item.id) { tm = api.tmdbInfo(item.title, serial); full = api.tmdbFull(item, serial) }
    var balancers by remember { mutableStateOf(listOf("Filmix" to "/lite/filmix")) }
    LaunchedEffect(Unit) { balancers = api.balancers() }
    var panel by remember { mutableStateOf<String?>(null) }     // null | src | online
    var fav by remember(item.id) { mutableStateOf(false) }
    LaunchedEffect(item.id) { fav = if (jf) api.isFavorite(item.id) else api.isLocalFav(item.id) }
    var vis by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { vis = true }
    val cal by animateFloatAsState(if (vis) 1f else 0f, androidx.compose.animation.core.tween(500), label = "ca")
    val coff by animateDpAsState(if (vis) 0.dp else 30.dp, androidx.compose.animation.core.tween(500), label = "co")
    val scope = rememberCoroutineScope()
    val ctx = LocalContext.current
    BackHandler { if (panel == "online") panel = "src" else if (panel != null) panel = null else back() }
    Box(Modifier.fillMaxSize()) {
        AsyncImage(item.backdropId.takeIf { it.isNotEmpty() }?.let { if (it.startsWith("http")) it else api.img(it, "Backdrop", 1280) } ?: item.torrentPoster ?: api.img(item.imgId, "Primary", 800), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop, alpha = 0.45f)
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0x66000000), Bg))))
        Column(Modifier.fillMaxSize().offset(y = coff).alpha(cal).verticalScroll(rememberScrollState()).padding(LocalPad.current, 20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            val t = tm; val f = full
            val rating = t?.rating?.takeIf { it > 0 } ?: item.rating
            Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                AsyncImage(item.torrentPoster ?: api.img(item.imgId, "Primary", 500), null, Modifier.width(if (LocalCompact.current) 120.dp else 190.dp).aspectRatio(2f / 3f).clip(RoundedCornerShape(14.dp)).background(Bg2), contentScale = ContentScale.Crop)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(listOfNotNull(t?.year?.takeIf { it.isNotEmpty() } ?: item.sub.takeIf { it.isNotBlank() }, f?.country?.takeIf { it.isNotEmpty() }).joinToString(", "), color = Color(0xFFB8BECC), fontSize = 14.sp)
                    Text(item.title, color = Color.White, fontSize = if (LocalCompact.current) 26.sp else 38.sp, fontWeight = FontWeight.Black)
                    if (!t?.tagline.isNullOrBlank()) Text(t!!.tagline, color = Color.White, fontSize = 17.sp)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        if (rating > 0) Text("%.1f  TMDB".format(rating), color = Color(0xFFD08CFF), fontSize = 14.sp, fontWeight = FontWeight.Bold, modifier = Modifier.border(1.dp, Color(0xFF9B5CCB), RoundedCornerShape(6.dp)).padding(horizontal = 8.dp, vertical = 3.dp))
                        if (f != null && f.status.isNotEmpty()) Text(f.status, color = Color.White, fontSize = 13.sp, modifier = Modifier.border(1.dp, Color(0x99FFFFFF), RoundedCornerShape(6.dp)).padding(horizontal = 8.dp, vertical = 3.dp))
                    }
                    val rt = t?.runtime?.takeIf { it > 0 }?.let { "%02d:%02d".format(it / 60, it % 60) }
                    Text(listOfNotNull(rt, t?.genres?.take(3)?.joinToString(" | ")?.takeIf { it.isNotEmpty() }).joinToString("  •  "), color = Color(0xFFDDDDDD), fontSize = 14.sp)
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        LabelBtn(Icons.Filled.PlayArrow, "Смотреть", true) { panel = "src" }
                        LabelBtn(if (fav) Icons.Filled.Bookmark else Icons.Filled.BookmarkBorder, if (fav) "В избранном" else "В избранное") {
                            if (jf) scope.launch { runCatching { api.setFavorite(item.id, !fav); fav = !fav } } else fav = api.toggleLocalFav(item)
                        }
                        IconBtn(Icons.Filled.ArrowBack, "Назад") { back() }
                    }
                }
            }
            Text("Подробно", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
            Text(item.overview.ifBlank { t?.overview ?: "" }, color = Color(0xFFCCCCCC), fontSize = 15.sp)
            if (f != null) Row(horizontalArrangement = Arrangement.spacedBy(36.dp)) {
                if (f.release.isNotEmpty()) Column { Text("Дата релиза", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.Bold); Text(f.release, color = Color(0xFF9AA0AE), fontSize = 15.sp) }
                if (f.country.isNotEmpty()) Column { Text("Страны", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.Bold); Text(f.country, color = Color(0xFF9AA0AE), fontSize = 15.sp) }
            }
            @Composable fun People(title: String, list: List<Api.Person>) {
                if (list.isEmpty()) return
                Text(title, color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
                TvLazyRow(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                    items(list) { pr ->
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.size(64.dp).clip(RoundedCornerShape(12.dp)).background(Bg2), contentAlignment = Alignment.Center) {
                                Text(pr.name.take(1), color = Color.Gray, fontSize = 22.sp)
                                if (pr.photo.isNotEmpty()) AsyncImage(pr.photo, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                            }
                            Column(Modifier.widthIn(max = 180.dp)) { Text(pr.name, color = Color.White, fontSize = 15.sp, maxLines = 2); Text(pr.role, color = Color(0xFF9AA0AE), fontSize = 13.sp, maxLines = 1) }
                        }
                    }
                }
            }
            People("Режиссёр", f?.directors ?: emptyList())
            People("Актёры", f?.actors ?: emptyList())
            CompositionLocalProvider(LocalPad provides 0.dp) {
                if (f != null && f.recs.isNotEmpty()) Row("Рекомендации", api, f.recs, {}, { go(Screen.Detail(it)) })
                if (f != null && f.similar.isNotEmpty()) Row("Похожие", api, f.similar, {}, { go(Screen.Detail(it)) })
            }
        }
        // правая панель источников: Jellyfin / Торренты / Онлайн / Трейлеры
        if (panel != null) Box(Modifier.fillMaxSize().background(Color(0x66000000)), contentAlignment = Alignment.CenterEnd) {
            val fr = remember { FocusRequester() }
            LaunchedEffect(panel) { delay(100); runCatching { fr.requestFocus() } }
            Column(Modifier.width(340.dp).padding(end = 24.dp).clip(RoundedCornerShape(16.dp)).background(Bg2).padding(20.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                val opts: List<Pair<String, () -> Unit>> = if (panel == "online") balancers.map { b -> b.first to { go(Screen.Home(4, api.searchUrl(b.second, item.title, serial))) } }
                else buildList {
                    if (jf) add("Jellyfin (моя медиатека)" to { if (item.type == "Series") go(Screen.Series(item)) else go(Screen.Play(PlayReq(listOf(item), 0))) })
                    add("Торренты" to { go(Screen.Torrents(item)) })
                    add("Онлайн ›" to { panel = "online" })
                    add("Трейлеры" to { runCatching { ctx.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, Uri.parse("https://www.youtube.com/results?search_query=" + Uri.encode(item.title + " трейлер"))).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)) } })
                }
                Text(if (panel == "online") "Онлайн-источники" else "Где смотреть", color = Cyan, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                opts.forEachIndexed { i, (label, act) ->
                    Focusable(Modifier.fillMaxWidth().let { if (i == 0) it.focusRequester(fr) else it }, onClick = act) { fo ->
                        Text(label, color = if (fo) Bg else Color.White, fontSize = 16.sp, modifier = Modifier.fillMaxWidth().background(if (fo) Cyan else Color(0xFF1A1D29)).padding(14.dp))
                    }
                }
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
                            Text(fl[i].title + if (fl[i].sub.isNotBlank()) "  ·  " + fl[i].sub else "", color = Color.White, fontSize = 15.sp, maxLines = 2, modifier = Modifier.weight(1f)); Text(fl[i].overview, color = Cyan)
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
    LaunchedEffect(Unit) { list = api.localFavs() + runCatching { api.favorites() }.getOrElse { msg = "Jellyfin: ${it.message}"; emptyList() }; if (list.isNotEmpty()) msg = "" else if (msg == "Загрузка…") msg = "Избранное пусто: нажмите «☆ В избранное» на главной или сердечко в Jellyfin." }
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
        var uname by remember { mutableStateOf(api.user) }
        LaunchedEffect(Unit) { api.ensureUser(); uname = api.user }
        Text("Jellyfin: ${uname.ifEmpty { "—" }}", color = Color.White, fontSize = 16.sp)
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
        H("Заставка")
        var ssOn by remember { mutableStateOf(api.ssOn) }
        var ssMin by remember { mutableIntStateOf(api.ssMin) }
        var ssTheme by remember { mutableStateOf(api.ssTheme) }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Chip("Включена", ssOn) { api.ssOn = true; ssOn = true }
            Chip("Выключена", !ssOn) { api.ssOn = false; ssOn = false }
        }
        Text("Запускать после бездействия:", color = Color(0xFFCCCCCC), fontSize = 14.sp)
        TvLazyRow(Modifier.fillMaxWidth().height(52.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            items(listOf(1, 2, 5, 10, 15, 30)) { m -> Chip("$m мин", ssMin == m) { api.ssMin = m; ssMin = m } }
        }
        Text("Тема заставки:", color = Color(0xFFCCCCCC), fontSize = 14.sp)
        TvLazyRow(Modifier.fillMaxWidth().height(52.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            items(listOf("new" to "Новинки кино", "trend" to "Тренды недели", "library" to "Моя медиатека", "cartoon" to "Мультфильмы", "anime" to "Аниме", "nature" to "Природа и документальное")) { (k, n) ->
                Chip(n, ssTheme == k) { api.ssTheme = k; ssTheme = k }
            }
        }
        KField(lu, { lu = it; api.lampacUid = it }, label = { Text("Lampac uid (Filmix и онлайн)") }, singleLine = true, modifier = Modifier.widthIn(max = 520.dp).fillMaxWidth())
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            KField(pw, { pw = it }, label = { Text("Пароль Jellyfin для обновления uid") }, singleLine = true, modifier = Modifier.widthIn(max = 380.dp).weight(1f), visualTransformation = PasswordVisualTransformation())
            Chip("Получить uid заново") { scope.launch { msg = try { api.refreshLampac(pw); lu = api.lampacUid; pw = ""; "uid обновлён" } catch (e: Exception) { "Ошибка: ${e.message}" } } }
        }
        var tsm by remember { mutableIntStateOf(api.tsMode) }
        Text("TorrServer: ${api.tsWhere()}", color = Color(0xFFCCCCCC), fontSize = 14.sp)
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            listOf("Авто", "Только внешний", "Только дома").forEachIndexed { i, n -> Chip(n, tsm == i) { api.tsMode = i; tsm = i; ts = api.ts; tsa = api.tsAuth } }
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
        // таймауты 8 с по умолчанию рвут холодный старт торрента (поиск пиров ~10-15 с) и медленную мобильную сеть
        val http = androidx.media3.datasource.DefaultHttpDataSource.Factory().setConnectTimeoutMs(20_000).setReadTimeoutMs(45_000).setAllowCrossProtocolRedirects(true)
        val ds = androidx.media3.datasource.ResolvingDataSource.Factory(http) { spec ->
            if (spec.uri.toString().startsWith(api.ts)) spec.withAdditionalHeaders(mapOf("Authorization" to api.tsHeader()))
            else if (spec.uri.toString().startsWith(api.base)) spec.withAdditionalHeaders(mapOf("Authorization" to api.jfHeader())) else spec
        }
        // буфер побольше: мобильный интернет и внешний канал качаются рывками
        val lc = androidx.media3.exoplayer.DefaultLoadControl.Builder().setBufferDurationsMs(30_000, 120_000, 2_500, 5_000).build()
        ExoPlayer.Builder(ctx).setLoadControl(lc).setMediaSourceFactory(androidx.media3.exoplayer.source.DefaultMediaSourceFactory(ds)).build()
    }
    val act = remember { var c = ctx; while (c is android.content.ContextWrapper && c !is android.app.Activity) c = c.baseContext; c as? android.app.Activity }
    val am = remember { ctx.getSystemService(android.content.Context.AUDIO_SERVICE) as android.media.AudioManager }
    var hud by remember { mutableStateOf("") }
    var hudUntil by remember { mutableStateOf(0L) }
    fun hudShow(t: String) { hud = t; hudUntil = System.currentTimeMillis() + 900 }
    var sleepAt by remember { mutableStateOf(0L) }            // 0 = таймер выключен
    var sleepEnd by remember { mutableStateOf(false) }        // «до конца серии»
    var vsz by remember { mutableIntStateOf(0) }               // высота кадра: при смене разрешения пересоздаём поверхность видео
    var onlineQ by remember { mutableStateOf<String?>(null) }   // выбранное качество онлайн-потока
    var bright by remember { mutableFloatStateOf(-1f) }       // яркость плеера: -1 = авто (системная)
    fun setBright(b: Float) { bright = b; act?.window?.let { w -> val lp = w.attributes; lp.screenBrightness = b; w.attributes = lp } }
    var fit by remember { mutableIntStateOf(0) }              // масштаб: 0 по размеру, 1 заполнить с обрезкой, 2 растянуть
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
            // адрес торрента пересобираем: дома/снаружи он разный, а в истории мог сохраниться старый
            val u = if (item.type == "Torrent" && item.torrentHash != null) "${api.ts}/stream?link=${item.torrentHash}&index=${item.id.substringAfter(':', "1")}&play" else (onlineQ?.let { item.qualities[it] } ?: item.url)
            player.setMediaItem(MediaItem.fromUri(u), startMs)
        } else if (item.type == "Torrent") {
            player.setMediaItem(MediaItem.fromUri(api.torrentUrl(item.torrentHash!!)), startMs)
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
                    if (cur.type == "Torrent") api.saveHistory(cur, player.duration, player.duration)   // досмотрено: убрать из «Продолжить»
                    if (sleepEnd) { act?.finish(); return@launch }
                    if (!req.movieVoices && idx + 1 < list.size) { idx++; info = null; audioIdx = null; load(0) } else exit()
                }
            }
            override fun onVideoSizeChanged(v: androidx.media3.common.VideoSize) { vsz = v.height }
            override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
                val c = error.cause
                err = if (c is androidx.media3.datasource.HttpDataSource.InvalidResponseCodeException)
                    "Ошибка сервера ${c.responseCode}: ${String(c.responseBody).take(160).ifBlank { "нет доступа" }}"
                else "Ошибка воспроизведения: ${error.errorCodeName}"
                android.util.Log.e("KL", "player error: $err uri=${(c as? androidx.media3.datasource.HttpDataSource.HttpDataSourceException)?.dataSpec?.uri?.toString()?.replace(Regex("api_key=[0-9a-f]+"), "api_key=*")}", error)
            }
        }
        player.addListener(l)
        scope.launch { runCatching { load(if (cur.posTicks > 0 && (cur.runTicks == 0L || cur.runTicks - cur.posTicks > 600_000_000L)) cur.posTicks / 10_000 else 0) }.onFailure { err = "Ошибка: ${it.message}" } }
        val brightness0 = act?.window?.attributes?.screenBrightness
        act?.requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR   // поворот по датчику, плеер не перезапускается
        onDispose {
            act?.requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
            player.removeListener(l)
            act?.window?.let { w -> val lp = w.attributes; lp.screenBrightness = brightness0 ?: -1f; w.attributes = lp }
            val i = info; val p = ps; val pos = player.currentPosition
            list[idx].let { c -> if (c.type == "Torrent") api.saveHistory(c, pos, player.duration.coerceAtLeast(0)) }
            player.release()
            // отчёт о прогрессе и остановка ffmpeg после выхода, вне UI-скоупа
            kotlinx.coroutines.GlobalScope.launch {
                if (i != null && p.isNotEmpty()) { api.reportStop(list[idx].id, i, p, pos); api.stopEncoding(p) }
            }
        }
    }
    LaunchedEffect(Unit) {
        while (true) {
            delay(500); tick++
            if (tick % 20 == 0) {
                info?.let { api.reportProgress(cur.id, it, ps, player.currentPosition) }
                if (cur.type == "Torrent") api.saveHistory(cur, player.currentPosition, player.duration.coerceAtLeast(0))   // «Продолжить» не теряется при обрыве
            }
            if (sleepAt > 0 && System.currentTimeMillis() >= sleepAt) { sleepAt = 0; player.pause(); act?.finish() }   // слип-таймер
        }
    }
    // запуск из «Продолжить»: в списке одна серия, дотягиваем остальные серии сериала для кнопки «Серии» и следующей серии
    LaunchedEffect(Unit) {
        val c0 = list.getOrNull(idx)
        if (list.size == 1 && c0 != null && c0.type == "Episode" && c0.seriesId != null && !req.movieVoices) runCatching {
            val eps = api.episodes(c0.seriesId).toMutableList()
            val k = eps.indexOfFirst { it.id == c0.id }
            if (k >= 0) { eps[k] = c0; list = eps; idx = k }
        }
    }
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
            // жесты: вертикально слева — яркость, справа — громкость; горизонтально — перемотка (применяется при отпускании)
            .pointerInput(Unit) {
                var mode = 0; var sx = 0f; var dx = 0f; var dy = 0f; var start = 0L; var target = 0L; var v0 = 0; var b0 = 0.5f
                detectDragGestures(
                    onDragStart = { o -> sx = o.x; dx = 0f; dy = 0f; mode = 0; start = player.currentPosition; target = start },
                    onDragEnd = { if (mode == 3) player.seekTo(target); mode = 0 },
                    onDragCancel = { mode = 0 },
                ) { _, d ->
                    if (menu != null) return@detectDragGestures
                    dx += d.x; dy += d.y
                    if (mode == 0 && (kotlin.math.abs(dx) > 30 || kotlin.math.abs(dy) > 30)) {
                        mode = if (kotlin.math.abs(dx) > kotlin.math.abs(dy)) 3 else if (sx < size.width / 2) 1 else 2
                        v0 = am.getStreamVolume(android.media.AudioManager.STREAM_MUSIC)
                        b0 = bright.takeIf { it >= 0 } ?: (android.provider.Settings.System.getInt(ctx.contentResolver, android.provider.Settings.System.SCREEN_BRIGHTNESS, 128) / 255f)
                    }
                    when (mode) {
                        1 -> { val b = (b0 - dy / size.height * 1.4f).coerceIn(0.02f, 1f)
                            setBright(b); hudShow("Яркость ${(b * 100).toInt()}%") }
                        2 -> { val mx = am.getStreamMaxVolume(android.media.AudioManager.STREAM_MUSIC)
                            val v = (v0 - dy / size.height * 1.4f * mx).let { Math.round(it) }.coerceIn(0, mx)
                            am.setStreamVolume(android.media.AudioManager.STREAM_MUSIC, v, 0); hudShow("Громкость ${v * 100 / mx}%") }
                        3 -> { val dur0 = player.duration.takeIf { it > 0 } ?: Long.MAX_VALUE
                            target = (start + dx / size.width * 120_000).toLong().coerceIn(0, dur0); hudShow((if (target >= start) "▶▶ " else "◀◀ ") + fmtTime(target)) }
                    }
                }
            }
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
        key(vsz) { AndroidView({ (android.view.LayoutInflater.from(it).inflate(R.layout.kl_player_view, null) as PlayerView).apply { this.player = player; keepScreenOn = true } }, Modifier.fillMaxSize(),
            update = { it.resizeMode = when (fit) { 1 -> androidx.media3.ui.AspectRatioFrameLayout.RESIZE_MODE_ZOOM; 2 -> androidx.media3.ui.AspectRatioFrameLayout.RESIZE_MODE_FILL; else -> androidx.media3.ui.AspectRatioFrameLayout.RESIZE_MODE_FIT } }) }
        val dur = player.duration.takeIf { it > 0 } ?: 1L
        key(tick) {
            if (System.currentTimeMillis() < hudUntil) Text(hud, color = Color.White, fontSize = 26.sp, fontWeight = FontWeight.Bold,
                modifier = Modifier.align(Alignment.Center).background(Color(0x99000000), RoundedCornerShape(12.dp)).padding(horizontal = 22.dp, vertical = 12.dp))
            val pos = player.currentPosition
            val shown = menu == null && (!player.isPlaying || System.currentTimeMillis() < uiUntil)
            if (!shown) Box(Modifier.align(Alignment.BottomStart).fillMaxWidth((pos.toFloat() / dur).coerceIn(0f, 1f)).height(3.dp).background(Cyan))
            if (shown) {
                // шапка: назад, название и серия, серии и настройки
                Row(Modifier.align(Alignment.TopStart).fillMaxWidth().background(Brush.verticalGradient(listOf(Color(0xCC000000), Color.Transparent))).statusBarsPadding().padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    IconBtn(Icons.Filled.ArrowBack, "Назад", ::hudShow) { exit() }
                    Column(Modifier.weight(1f)) {
                        Text(cur.title, color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold, maxLines = 1)
                        val epi = cur.sub.ifEmpty { "" } + (if (list.size > 1 && !req.movieVoices) "   (${idx + 1} из ${list.size})" else "") + "   [${q.label}]"
                        Text(epi.trim(), color = Color(0xFFB8BECC), fontSize = 13.sp, maxLines = 1)
                    }
                }
                // низ: таймлайн и кнопки
                Column(Modifier.align(Alignment.BottomStart).fillMaxWidth().background(Brush.verticalGradient(listOf(Color.Transparent, Color(0xDD000000)))).navigationBarsPadding().padding(horizontal = 24.dp, vertical = 14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
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
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(28.dp, Alignment.CenterHorizontally), verticalAlignment = Alignment.CenterVertically) {
                        IconBtn(Icons.Filled.Replay30, "Назад 30 с", ::hudShow) { seek(-30_000) }
                        IconBtn(Icons.Filled.Replay10, "Назад 10 с", ::hudShow) { seek(-10_000) }
                        PlayBtn(player.isPlaying) { player.playWhenReady = !player.playWhenReady; poke() }
                        IconBtn(Icons.Filled.Forward10, "Вперёд 10 с", ::hudShow) { seek(10_000) }
                        IconBtn(Icons.Filled.Forward30, "Вперёд 30 с", ::hudShow) { seek(30_000) }
                        if (hasNext) IconBtn(Icons.Filled.SkipNext, "Следующая серия", ::hudShow) { next() }
                    }
                    Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), horizontalArrangement = Arrangement.SpaceEvenly, verticalAlignment = Alignment.CenterVertically) {
                        if (!req.movieVoices && list.size > 1) IconBtn(Icons.Filled.PlaylistPlay, "Серии", ::hudShow) { menu = "episodes" }
                        if (cur.url != null && voices.isNotEmpty() || req.movieVoices) IconBtn(Icons.Filled.RecordVoiceOver, "Озвучка", ::hudShow) { menu = "voice" }
                        IconBtn(Icons.Filled.VolumeUp, "Звуковые дорожки", ::hudShow) { menu = "audio" }
                        IconBtn(Icons.Filled.Subtitles, "Субтитры", ::hudShow) { menu = "subs" }
                        if (cur.url == null || cur.qualities.size > 1) IconBtn(Icons.Filled.HighQuality, "Качество", ::hudShow) { menu = "quality" }
                        IconBtn(Icons.Filled.AspectRatio, "Масштаб", ::hudShow) { menu = "scale" }
                        IconBtn(Icons.Filled.BrightnessMedium, "Яркость", ::hudShow) { menu = "bright" }
                        IconBtn(Icons.Filled.Bedtime, "Таймер сна", ::hudShow) { menu = "sleep" }
                    }
                }
            }
        }
        if (err.isNotEmpty()) Text(err, color = Color(0xFFFF6B6B), fontSize = 18.sp, modifier = Modifier.align(Alignment.Center))
        menu?.let { m -> PlayerMenu(m, player, q, info, cur.url != null, voiceEntries, { menu = it }, { nq -> q = nq; menu = null; scope.launch { load(player.currentPosition, true) } },
            { a -> audioIdx = a; menu = null; scope.launch { load(player.currentPosition, true) } },
            listOf("По размеру", "Заполнить", "Растянуть")[fit], { f -> fit = f; menu = null; hudShow("Масштаб: " + listOf("по размеру", "заполнить", "растянуть")[f]) },
            if (bright < 0) "Авто" else "${(bright * 100).toInt()}%", { b -> menu = null; setBright(b); hudShow(if (b < 0) "Яркость: авто" else "Яркость ${(b * 100).toInt()}%") },
            if (sleepEnd) "до конца серии" else if (sleepAt > 0) "ещё ${((sleepAt - System.currentTimeMillis()) / 60_000 + 1)} мин" else "выкл",
            { m -> menu = null; sleepEnd = m == -1; sleepAt = if (m > 0) System.currentTimeMillis() + m * 60_000L else 0L
                hudShow(if (m == 0) "Таймер сна выключен" else if (m == -1) "Сон: после этой серии" else "Сон через $m мин") },
            cur.qualities.keys.sortedByDescending { k -> k.filter(Char::isDigit).toIntOrNull() ?: 0 },
            onlineQ?.takeIf { k -> k in cur.qualities } ?: cur.qualities.entries.firstOrNull { e -> e.value == cur.url }?.key ?: "",
            { l -> menu = null; onlineQ = l; hudShow("Качество: $l"); scope.launch { load(player.currentPosition, true) } },
            list.mapIndexed { i, e -> ((if (i == idx) "● " else "") + listOf(e.sub, e.title).filter { x -> x.isNotBlank() }.distinct().joinToString(" · ")) to { menu = null
                scope.launch { info?.let { inf -> api.reportStop(cur.id, inf, ps, player.currentPosition) }; idx = i; info = null; audioIdx = null; load(0) }; Unit } }) }
    }
}

private var infoFor: String = ""

@Composable
fun PlayerMenu(menu: String, player: ExoPlayer, q: Quality, info: Info?, online: Boolean, voiceNames: List<Pair<String, () -> Unit>>, setMenu: (String?) -> Unit, pickQuality: (Quality) -> Unit, pickAudio: (Int) -> Unit,
               scaleLabel: String, pickScale: (Int) -> Unit, brightLabel: String, pickBright: (Float) -> Unit, sleepLabel: String, pickSleep: (Int) -> Unit,
               onlineQs: List<String>, onlineQLabel: String, pickOnlineQ: (String) -> Unit,
               episodes: List<Pair<String, () -> Unit>>) {
    val fr = remember { FocusRequester() }
    LaunchedEffect(menu) { delay(100); runCatching { fr.requestFocus() } }
    val entries = mutableListOf<Pair<String, () -> Unit>>()
    var title = ""
    when (menu) {
        "main" -> {
            title = "Настройки воспроизведения"
            if (episodes.size > 1) entries += "Серии" to { setMenu("episodes") }
            if (online && voiceNames.isNotEmpty()) entries += "Озвучка / перевод" to { setMenu("voice") }
            entries += "Аудиодорожки" to { setMenu("audio") }
            entries += "Субтитры" to { setMenu("subs") }
            if (!online) entries += "Качество: ${q.label}" to { setMenu("quality") }
            else if (onlineQs.size > 1) entries += "Качество: $onlineQLabel" to { setMenu("quality") }
            entries += "Масштаб: $scaleLabel" to { setMenu("scale") }
            entries += "Яркость: $brightLabel" to { setMenu("bright") }
            entries += "Таймер сна: $sleepLabel" to { setMenu("sleep") }
        }
        "scale" -> { title = "Масштаб видео"; listOf("По размеру", "Заполнить", "Растянуть").forEachIndexed { i, n -> entries += (if (n == scaleLabel) "● " else "") + n to { pickScale(i) } } }
        "bright" -> {
            title = "Яркость"
            entries += (if (brightLabel == "Авто") "● " else "") + "Авто" to { pickBright(-1f) }
            listOf(20, 40, 60, 80, 100).forEach { p -> entries += (if (brightLabel == "$p%") "● " else "") + "$p%" to { pickBright(p / 100f) } }
        }
        "sleep" -> {
            title = "Таймер сна"
            entries += "Выключить" to { pickSleep(0) }
            listOf(1, 15, 30, 45, 60, 90).forEach { m -> entries += "Через $m мин" to { pickSleep(m) } }
            entries += "После этой серии" to { pickSleep(-1) }
        }
        "episodes" -> { title = "Серии"; entries += episodes }
        "voice" -> { title = "Озвучка / перевод"; voiceNames.forEach { entries += it } }
        "quality" -> {
            title = "Качество"
            if (online) onlineQs.forEach { l -> entries += (if (l == onlineQLabel) "● " else "") + l to { pickOnlineQ(l) } }
            else Quality.values().forEach { entries += (if (it == q) "● " else "") + it.label to { pickQuality(it) } }
        }
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
        val maxH = (androidx.compose.ui.platform.LocalConfiguration.current.screenHeightDp * 0.88f).dp
        Column(Modifier.width(520.dp).heightIn(max = maxH).clip(RoundedCornerShape(16.dp)).background(Bg2).padding(24.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
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
