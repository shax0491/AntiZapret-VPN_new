# Статическая проверка вёрстки Compose перед сборкой: ловит конструкции, раздувающие горизонтальные контейнеры на весь экран.
import re, sys
src = open(r'app/src/main/java/com/kinolink/tv/MainActivity.kt', encoding='utf-8').read()
bad = []
# 1. горизонтальные контейнеры без fillMaxHeight/fillMaxSize в своих аргументах
for m in re.finditer(r'(TvLazyRow|LazyRow)\(([^\n{]*)\{', src):
    if re.search(r'fillMaxHeight|fillMaxSize', m.group(2)): bad.append(('горизонтальный ряд с fillMaxHeight/Size', m.group(0)[:100]))
    if 'tabState' in m.group(2) and 'height(56.dp)' not in m.group(2): bad.append(('панель вкладок без фиксированной высоты 56dp', m.group(0)[:100]))
# 2. fillMaxHeight разрешён только внутри Chip при фиксированной высоте родителя
chip = src[src.index('fun Chip('):src.index('fun PosterCard(')]
if 'fillMaxHeight' in chip and not re.search(r'Focusable\(Modifier\.height\(', chip): bad.append(('Chip: fillMaxHeight без фиксированной высоты', ''))
if re.search(r'heightIn\(min[^)]*\)[^\n]*fillMaxHeight|fillMaxHeight[^\n]*heightIn\(min', src): bad.append(('heightIn(min)+fillMaxHeight', ''))
# 3. fillMaxHeight вне Chip запрещён
for n, line in enumerate(src.split('\n'), 1):
    if 'fillMaxHeight' in line and not chip.count(line.strip()): bad.append((f'fillMaxHeight вне Chip (строка {n})', line.strip()[:90]))
# 4. контент под вкладками ограничен weight
if 'Modifier.weight(1f).fillMaxWidth()) {\n        when (tab)' not in src.replace('\r', '') and 'Box(Modifier.weight(1f).fillMaxWidth())' not in src: bad.append(('контент под вкладками без weight', ''))
# 5. контраст полей: белый текст и видимые рамки
for k in ('focusedTextColor = Color.White', 'unfocusedTextColor = Color.White', 'unfocusedBorderColor'):
    if k not in src: bad.append(('поле ввода: нет ' + k, ''))
if 'BorderStroke' not in src and 'Brush.linearGradient(listOf(Cyan' not in src: bad.append(('нет видимой рамки фокуса', ''))
# 6. каждый Focusable-экран с вертикальным списком: TvLazyColumn/Column имеют fillMaxSize/weight
for e in bad: print('ОШИБКА:', *e)
print('lint: ошибок', len(bad)); sys.exit(1 if bad else 0)
