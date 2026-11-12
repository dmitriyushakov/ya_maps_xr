extends RefCounted
## Панорама Яндекса: метаданные, нормализация JSON, сборка equirect-текстуры.
##
## Схема сервиса panoramas/1.x (проверена живым ключом в веб-версии):
##   data.Data.Images.{imageId, Zooms[{level,width,height}], Tiles{width,height}}
##   data.Data.Point.coordinates = [lon, lat, 0]
##   data.Annotation.Thoroughfares[{Direction:[deg,deg], Connection:{href:"...oid=..."}}]
##   Тайлы: https://pano.maps.yandex.net/{imageId}/{level}.{x}.{y}

const Cfg = preload("res://scripts/config.gd")
const Net = preload("res://scripts/net.gd")

const TILE_HOST := "https://pano.maps.yandex.net"
const SERVICE_URL := "https://api-maps.yandex.ru/services/panoramas/1.x/"

## Параллельных загрузок тайлов.
const WORKERS := 6
## Повторы для тайла (просыпание гарнитуры / кратковременный обрыв сети).
const TILE_RETRIES := 3
const RETRY_DELAY := 0.4


class TileWaiter:
	extends RefCounted

	signal done()

	var remaining := 0

	func finish() -> void:
		remaining -= 1
		if remaining <= 0:
			done.emit()


static func _dict(v: Variant) -> Dictionary:
	return v if v is Dictionary else {}


static func _arr(v: Variant) -> Array:
	return v if v is Array else []


static func _num(v: Variant) -> float:
	return float(v) if (v is int or v is float) else 0.0


## Сервис панорам `apikey` не проверяет: ответ одинаков с пустым ключом, без него
## и с заведомо неверным. Шлём ключ, только если он задан — на случай, если Яндекс
## включит проверку (плюс этого требует ToS).
static func _apikey_param() -> String:
	if Cfg.YANDEX_API_KEY == "":
		return ""
	return "&apikey=" + Cfg.YANDEX_API_KEY.uri_encode()


static func fetch_by_ll(lon: float, lat: float, layer := "stv") -> Variant:
	## `layer`: "stv" — уличные панорамы (радиус поиска ~400 м), "sta" — воздушные
	## (~80 м). `provider` сервис фактически игнорирует, но он должен быть непустым.
	var provider := "air" if layer == "sta" else "streetview"
	var url := "%s?l=%s&lang=ru_RU&origin=userAction&provider=%s%s&ll=%.6f,%.6f" % [
		SERVICE_URL, layer, provider, _apikey_param(), lon, lat,
	]
	return await _fetch(url)


static func fetch_by_id(id: String) -> Variant:
	var url := "%s?l=stv&lang=ru_RU&origin=userAction%s&oid=%s&provider=streetview" % [
		SERVICE_URL, _apikey_param(), id.uri_encode(),
	]
	return await _fetch(url)


static func _fetch(url: String) -> Variant:
	var r: Array = await Net.get_text(url, Net.default_headers())
	if not r[0]:
		push_error("panorama: HTTP failed (%s)" % url)
		return null
	var payload: Variant = JSON.parse_string(r[1])
	if payload == null:
		push_error("panorama: bad JSON")
		return null
	var info: Variant = from_payload(payload)
	# Пустой/ошибочный ответ (нет панорамы в этой точке) — это не сбой, а норма:
	# молча отдаём null, чтобы вызывающий мог попробовать другой слой.
	return info


static func from_payload(payload: Variant) -> Variant:
	var root: Dictionary = _dict(payload)
	var wrapper: Dictionary = _dict(root.get("data"))
	var data: Dictionary = _dict(wrapper.get("Data"))
	var images: Dictionary = _dict(data.get("Images"))
	if images.is_empty():
		return null

	var image_id := str(images.get("imageId", ""))
	if image_id == "":
		return null

	var tiles: Dictionary = _dict(images.get("Tiles"))
	var tile_w := int(_num(tiles.get("width"))) if tiles.has("width") else 256
	var tile_h := int(_num(tiles.get("height"))) if tiles.has("height") else 256
	if tile_w <= 0:
		tile_w = 256
	if tile_h <= 0:
		tile_h = 256

	var levels: Array = []
	for z in _arr(images.get("Zooms")):
		var lvl: Dictionary = _dict(z)
		var level := int(_num(lvl.get("level")))
		var w := int(_num(lvl.get("width")))
		var h := int(_num(lvl.get("height")))
		if w <= 0 or h <= 0:
			continue
		levels.append({
			"level": level,
			"width": w,
			"height": h,
			"tile_w": tile_w,
			"tile_h": tile_h,
			"image_id": image_id,
		})
	levels.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["width"]) < int(b["width"])
	)

	var annotation: Dictionary = _dict(wrapper.get("Annotation"))
	var links: Array = []
	for t in _arr(annotation.get("Thoroughfares")):
		var td: Dictionary = _dict(t)
		var direction := _arr(td.get("Direction"))
		if direction.size() < 2:
			continue
		var link := {
			"yaw": deg_to_rad(_num(direction[0])),
			"pitch": deg_to_rad(_num(direction[1])),
			"id": "",
			"lon": NAN,
			"lat": NAN,
		}
		var conn: Dictionary = _dict(td.get("Connection"))
		var oid := _oid_from_href(str(conn.get("href", "")))
		if oid != "":
			link["id"] = oid
		links.append(link)

	var point: Dictionary = _dict(data.get("Point"))
	var coords := _arr(point.get("coordinates"))

	# Соседи воздушных панорам лежат в Annotation.Connections (у уличных —
	# Thoroughfares): {name, Point.coordinates:[lon,lat,alt], href, style}. У
	# воздушных direction не задан — считаем сами из координат (см. main.gd).
	var connections: Array = []
	for c in _arr(annotation.get("Connections")):
		var cd: Dictionary = _dict(c)
		var cp: Dictionary = _dict(cd.get("Point"))
		var cc := _arr(cp.get("coordinates"))
		var cid := _oid_from_href(str(cd.get("href", "")))
		if cid == "":
			continue
		connections.append({
			"id": cid,
			"name": str(cd.get("name", "")),
			"lon": _num(cc[0]) if cc.size() >= 2 else NAN,
			"lat": _num(cc[1]) if cc.size() >= 2 else NAN,
			"alt": _num(cc[2]) if cc.size() >= 3 else 0.0,
			"air": str(cd.get("style", "")).ends_with("#airshipStyle"),
		})

	var projection: Dictionary = _dict(data.get("EquirectangularProjection"))
	var origin := _arr(projection.get("Origin"))
	var yaw_origin := _num(origin[0]) if origin.size() >= 2 else 0.0
	var horizon_tilt := _num(origin[1]) if origin.size() >= 2 else 0.0

	# Вертикальная геометрия развёртки. Origin = [azimuth, horizonTilt]: первый —
	# азимут шва, второй — ШИРОТА СЕРЕДИНЫ картинки (не верхняя граница и не наклон
	# сферы поворотом). Верхний край плеер Яндекса привязывает к зениту по САМОМУ
	# МЕЛКОМУ уровню (порог π/100 ≈ 1.8° лечит округление размеров), а вертикальный
	# охват = 2π·H/W уровня, т.е. НЕ всегда π: полный шар — только при H/W = 0.5.
	# У новых автомобильных панорам (H/W ≈ 0.31..0.38) снято не всё небо/надир, и без
	# этого «жёсткого» предположения о полной сфере такая развёртка растягивалась бы
	# до полюсов (горизонт уезжал вниз, неба не видно). Формулы — как в плеере
	# Яндекса: см. docs/panorama-projection.md.
	var lat_top := PI / 2.0
	var lat_span := PI
	if not levels.is_empty():
		var lowest: Dictionary = levels[0]
		var highest: Dictionary = levels[levels.size() - 1]
		var colat := (
			PI / 2.0
			- PI * float(lowest["height"]) / float(lowest["width"])
			- deg_to_rad(horizon_tilt)
		)
		if colat < PI / 100.0:
			colat = 0.0
		lat_top = PI / 2.0 - colat
		# Канонический охват — по самому крупному уровню (точнее всего задаёт H/W).
		lat_span = 2.0 * PI * float(highest["height"]) / float(highest["width"])

	return {
		"name": str(point.get("name", "")),
		"lon": _num(coords[0]) if coords.size() >= 2 else NAN,
		"lat": _num(coords[1]) if coords.size() >= 2 else NAN,
		"alt": _num(coords[2]) if coords.size() >= 3 else 0.0,
		"yaw_origin": yaw_origin,
		"horizon_tilt": horizon_tilt,
		"lat_top": lat_top,
		"lat_span": lat_span,
		"levels": levels,
		"links": links,
		"connections": connections,
		"raw": payload,
	}


static func _oid_from_href(href: String) -> String:
	var re := RegEx.new()
	re.compile("[?&]oid=([^&]+)")
	var m := re.search(href)
	return m.get_string(1).uri_decode() if m != null else ""


static func tile_url(level: Dictionary, x: int, y: int) -> String:
	return "%s/%s/%d.%d.%d" % [
		TILE_HOST, str(level["image_id"]), int(level["level"]), x, y,
	]


## Число тайлов по горизонтали/вертикали уровня.
static func level_cols(level: Dictionary) -> int:
	return int(ceil(float(level["width"]) / float(level["tile_w"])))


static func level_rows(level: Dictionary) -> int:
	return int(ceil(float(level["height"]) / float(level["tile_h"])))


static func build_texture(level: Dictionary, on_progress: Callable = Callable()) -> ImageTexture:
	return await build_range(
		level, 0, level_cols(level), 0, level_rows(level), on_progress
	)


## Склеивает прямоугольный диапазон тайлов [x0,x1) x [y0,y1) в одну текстуру.
## Диапазон может быть подрешёткой уровня: так грузятся сектора сферы
## (см. scripts/pano_stream.gd), а не весь уровень целиком.
## Краевые тайлы уровня приходят обрезанными (напр. 256x128 у нижнего ряда),
## поэтому холст и блит обрезаются по реальным размерам уровня — иначе по краям
## остаются чёрные полосы.
static func build_range(
	level: Dictionary, x0: int, x1: int, y0: int, y1: int,
	on_progress: Callable = Callable()
) -> ImageTexture:
	var tw := int(level["tile_w"])
	var th := int(level["tile_h"])
	var w := maxi(mini(x1 * tw, int(level["width"])) - x0 * tw, 1)
	var h := maxi(mini(y1 * th, int(level["height"])) - y0 * th, 1)

	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	var queue: Array = []
	for y in range(y0, y1):
		for x in range(x0, x1):
			queue.append(Vector2i(x, y))

	var total := queue.size()
	var done_count: Array = [0]
	var failed: Array = [0]

	if total > 0:
		var waiter := TileWaiter.new()
		var worker_count := mini(WORKERS, total)
		waiter.remaining = worker_count
		for i in worker_count:
			_run_worker(waiter, queue, img, level, done_count, total, on_progress, x0, y0, failed)
		await waiter.done

	# Если хоть один тайл не приехал — не отдаём текстуру с чёрными дырами:
	# лучше остаться на предыдущем уровне/фоне, чем показать чёрные квадраты.
	if int(failed[0]) > 0:
		push_warning("range incomplete: %d tile(s) failed" % int(failed[0]))
		return null

	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _run_worker(
	waiter: TileWaiter, queue: Array, img: Image, level: Dictionary,
	done_count: Array, total: int, on_progress: Callable, x0: int, y0: int, failed: Array
) -> void:
	while not queue.is_empty():
		var job: Vector2i = queue.pop_front()
		var url := tile_url(level, job.x, job.y)
		var ok := false
		for attempt in TILE_RETRIES:
			var r: Array = await Net.get_bytes(url)
			if r[0] and _blit_tile(img, level, job, r[2], x0, y0):
				ok = true
				break
			if attempt < TILE_RETRIES - 1:
				await _wait(RETRY_DELAY)
		if not ok:
			failed[0] = int(failed[0]) + 1
			push_warning("tile fetch failed: %s" % url)
		done_count[0] = int(done_count[0]) + 1
		if on_progress.is_valid():
			on_progress.call(int(done_count[0]), total)
	waiter.finish()


static func _wait(sec: float) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		await tree.create_timer(sec).timeout


static func _blit_tile(
	img: Image, level: Dictionary, job: Vector2i, bytes: PackedByteArray,
	x0: int, y0: int
) -> bool:
	var tile := Image.new()
	var err := tile.load_jpg_from_buffer(bytes)
	if err != OK:
		err = tile.load_png_from_buffer(bytes)
	if err != OK:
		push_warning("tile decode failed: %s" % tile_url(level, job.x, job.y))
		return false
	if tile.get_format() != Image.FORMAT_RGB8:
		tile.convert(Image.FORMAT_RGB8)
	var tw := int(level["tile_w"])
	var th := int(level["tile_h"])
	var dst := Vector2i((job.x - x0) * tw, (job.y - y0) * th)
	# Краевой тайл (обрезанный) и выход за холст — обрезаем по холсту.
	var src := Rect2i(
		Vector2i.ZERO,
		Vector2i(
			mini(tile.get_width(), img.get_width() - dst.x),
			mini(tile.get_height(), img.get_height() - dst.y),
		),
	)
	if src.size.x > 0 and src.size.y > 0:
		img.blit_rect(tile, src, dst)
	return true
