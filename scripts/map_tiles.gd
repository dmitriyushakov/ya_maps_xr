extends RefCounted
## Тайловый движок планшета: пирамида базовой карты (core-renderer-tiles) и
## оверлей панорам (core-stv-renderer, слои stv/sta).
##
## База и оверлей — одна тайловая сетка (EPSG:3395, 256 px), поэтому индексы
## x/y/z у них общие и оверлей ложится на карту без подгонки смещений. Кэш —
## общий LRU по Vector3i.
##
## Движок отдаёт текстуру ЦЕЛОГО уровня z0 = floor(zoom); дробную часть zoom
## применяет материал планшета (UV-скейл, см. scripts/map_tablet.gd). Так дробный
## зум не требует пересборки/пере-семплинга: меняется только UV.

const Cfg = preload("res://scripts/config.gd")
const Geo = preload("res://scripts/geo.gd")
const Net = preload("res://scripts/net.gd")

const TILE := 256


class Waiter:
	extends RefCounted

	signal done()

	var remaining := 0

	func finish() -> void:
		remaining -= 1
		if remaining <= 0:
			done.emit()


var view_px := Vector2i(Cfg.MAP_VIEW_W, Cfg.MAP_VIEW_H)
var overlay := false

## Vector3i(x, y, z) -> {"base": Image, "stv": Image|null, "sta": Image|null}
var _tiles: Dictionary = {}
## LRU: ключи по возрастанию давности (последний — самый свежий).
var _order: Array = []
## Ключ -> ticks, до которых не перезапрашивать тайл с неудачным фоном.
var _retry: Dictionary = {}
## Ключи, которые сейчас качаются (чтобы prefetch и сборка не дублировали запросы).
var _fetching: Dictionary = {}

## Оверлейные слои последней собранной картинки — для сэмпла альфы под тапом.
var _view_stv: Variant = null
var _view_sta: Variant = null


func setup(view: Vector2i) -> void:
	view_px = view


## Размер собранного окна (показываемое окно + запас на сдвиг с обеих сторон).
func window_px() -> Vector2i:
	return view_px + Vector2i(2 * Cfg.MAP_MARGIN, 2 * Cfg.MAP_MARGIN)


func set_overlay(value: bool) -> void:
	overlay = value


## Собирает текстуру окна вокруг center (lon,lat) на уровне z0 = floor(zoom).
## Окно больше показываемого на `MAP_MARGIN` с каждой стороны — чтобы сдвиг можно
## было рисовать смещением готовой текстуры, не дожидаясь пересборки.
func build(center: Vector2, zoom: float) -> ImageTexture:
	var z0 := floori(zoom)
	var center_z := Geo.yandex_world_px(center.x, center.y, z0)
	var win := window_px()
	var origin := center_z - Vector2(win) * 0.5

	var tx0 := floori(origin.x / float(TILE))
	var ty0 := floori(origin.y / float(TILE))
	var tx1 := floori((origin.x + win.x - 1.0) / float(TILE))
	var ty1 := floori((origin.y + win.y - 1.0) / float(TILE))

	var keys: Array = []
	for ty in range(ty0, ty1 + 1):
		for tx in range(tx0, tx1 + 1):
			keys.append(Vector3i(tx, ty, z0))

	await _ensure(keys, z0)

	var img := Image.create(win.x, win.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.06, 0.08, 0.1, 1.0))

	var need_ov := overlay and z0 >= Cfg.OVERLAY_MIN_ZOOM
	var ov_stv: Variant = null
	var ov_sta: Variant = null
	if need_ov:
		ov_stv = Image.create(win.x, win.y, false, Image.FORMAT_RGBA8)
		ov_sta = Image.create(win.x, win.y, false, Image.FORMAT_RGBA8)
		(ov_stv as Image).fill(Color(0, 0, 0, 0))
		(ov_sta as Image).fill(Color(0, 0, 0, 0))

	var ox := int(origin.x)
	var oy := int(origin.y)
	for key in keys:
		var e: Dictionary = _tiles.get(key, {})
		if e.is_empty():
			continue
		var dst := Vector2i(int(key.x) * TILE - ox, int(key.y) * TILE - oy)
		var base: Variant = e.get("base")
		if base != null:
			_blit(img, base, dst)
		if need_ov:
			var sstv: Variant = e.get("stv")
			if sstv != null:
				_blit(ov_stv, sstv, dst)
			var ssta: Variant = e.get("sta")
			if ssta != null:
				_blit(ov_sta, ssta, dst)

	if need_ov:
		img.blend_rect(ov_stv, Rect2i(Vector2i.ZERO, win), Vector2i.ZERO)
		img.blend_rect(ov_sta, Rect2i(Vector2i.ZERO, win), Vector2i.ZERO)
	_view_stv = ov_stv
	_view_sta = ov_sta

	# Мипмапы не генерируем: на мобильном CPU это заметный хитч, а планшет смотрим
	# почти под прямым углом — фильтра LINEAR достаточно.
	return ImageTexture.create_from_image(img)


## Ключи тайлов, покрывающих окно вокруг center на уровне z.
func _window_keys(center: Vector2, z: int) -> Array:
	var center_z := Geo.yandex_world_px(center.x, center.y, z)
	var win := window_px()
	var origin := center_z - Vector2(win) * 0.5
	var tx0 := floori(origin.x / float(TILE))
	var ty0 := floori(origin.y / float(TILE))
	var tx1 := floori((origin.x + win.x - 1.0) / float(TILE))
	var ty1 := floori((origin.y + win.y - 1.0) / float(TILE))
	var keys: Array = []
	for ty in range(ty0, ty1 + 1):
		for tx in range(tx0, tx1 + 1):
			keys.append(Vector3i(tx, ty, z))
	return keys


## Фоновая подкачка уровня (без сборки): при подходе к целой границе зума соседний
## уровень уже прогрет, и подмена текстуры не даёт хитча на декоде тайлов.
func prefetch(center: Vector2, z: int) -> void:
	if z < 0 or z > 23:
		return
	var missing: Array = []
	for k in _window_keys(center, z):
		if not _tiles.has(k) and not _fetching.has(k):
			missing.append(k)
			_fetching[k] = true
	if missing.is_empty():
		return
	var waiter := Waiter.new()
	waiter.remaining = mini(Cfg.MAP_TILE_WORKERS, missing.size())
	for i in waiter.remaining:
		_worker(waiter, missing, z)


## Какая иконка оверлея под пикселем: -1 — нет, 0 — stv (улицы), 1 — sta (воздух).
## Сэмплим окрестность, чтобы попадание было некритично к промаху в пару пикселей.
func sample_overlay(px: Vector2i) -> int:
	if _view_stv == null:
		return -1
	var stv := _view_stv as Image
	var sta := _view_sta as Image
	var a_stv := 0.0
	var a_sta := 0.0
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			var p := px + Vector2i(dx, dy)
			if _contains(stv, p):
				a_stv = maxf(a_stv, stv.get_pixelv(p).a)
			if sta != null and _contains(sta, p):
				a_sta = maxf(a_sta, sta.get_pixelv(p).a)
	if a_sta > 0.02 and a_sta >= a_stv:
		return 1
	if a_stv > 0.02:
		return 0
	return -1


func has_overlay() -> bool:
	return _view_stv != null


# --- Загрузка ---------------------------------------------------------------


func _ensure(keys: Array, z: int) -> void:
	var now := Time.get_ticks_msec()
	var missing: Array = []
	for k in keys:
		var cached := _tiles.has(k)
		if cached:
			_touch(k)
		var base_ok := cached and _tiles[k].get("base") != null
		var retry_ready := now >= int(_retry.get(k, 0))
		if not cached or (not base_ok and retry_ready):
			missing.append(k)
	if missing.is_empty():
		return

	var queue := missing
	var waiter := Waiter.new()
	var n := mini(Cfg.MAP_TILE_WORKERS, queue.size())
	waiter.remaining = n
	for k in queue:
		_fetching[k] = true
	for i in n:
		_worker(waiter, queue, z)
	await waiter.done


func _worker(waiter: Waiter, queue: Array, z: int) -> void:
	while not queue.is_empty():
		var k: Vector3i = queue.pop_front()
		var e := await _fetch(k, z)
		_fetching.erase(k)
		_tiles[k] = e
		_touch(k)
		_evict()
	waiter.finish()


func _fetch(k: Vector3i, z: int) -> Dictionary:
	var e := {"base": null, "stv": null, "sta": null}

	var r: Array = await Net.get_bytes(_base_url(k))
	if r[0] and not (r[2] as PackedByteArray).is_empty():
		e["base"] = _decode_png(r[2])
	if e["base"] == null:
		# Не кэшируем «дыру» навсегда: даём шанс перезапросить через паузу.
		_retry[k] = Time.get_ticks_msec() + 3000

	if overlay and z >= Cfg.OVERLAY_MIN_ZOOM:
		e["stv"] = await _fetch_overlay(k, "stv")
		e["sta"] = await _fetch_overlay(k, "sta")
	return e


func _fetch_overlay(k: Vector3i, layer: String) -> Variant:
	var r: Array = await Net.get_bytes(_overlay_url(k, layer))
	if not r[0] or (r[2] as PackedByteArray).is_empty():
		return null # 204 — в тайле нет покрытия этого слоя (норма)
	return _decode_png(r[2])


func _decode_png(bytes: PackedByteArray) -> Variant:
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK:
		return null
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	return img


func _base_url(k: Vector3i) -> String:
	return "%s?l=map&x=%d&y=%d&z=%d&format=png" % [Cfg.MAP_TILE_URL, k.x, k.y, k.z]


func _overlay_url(k: Vector3i, layer: String) -> String:
	var hosts: Array = Cfg.MAP_OVERLAY_HOSTS
	var host: String = hosts[posmod(k.x + k.y, hosts.size())]
	return "%s?l=%s&x=%d&y=%d&z=%d&scale=1&lang=ru_RU&format=png&v=1" % [
		Cfg.MAP_OVERLAY_URL % host, layer, k.x, k.y, k.z,
	]


# --- Кэш --------------------------------------------------------------------


func _touch(k: Vector3i) -> void:
	var i := _order.find(k)
	if i >= 0:
		_order.remove_at(i)
	_order.append(k)


func _evict() -> void:
	while _order.size() > Cfg.MAP_TILE_CACHE:
		var oldest: Vector3i = _order.pop_front()
		_tiles.erase(oldest)
		_retry.erase(oldest)


# --- Утилиты ----------------------------------------------------------------


func _blit(dst: Image, src: Image, at: Vector2i) -> void:
	var s := src.get_size()
	var x0 := maxi(at.x, 0)
	var y0 := maxi(at.y, 0)
	var x1 := mini(at.x + s.x, dst.get_width())
	var y1 := mini(at.y + s.y, dst.get_height())
	if x1 <= x0 or y1 <= y0:
		return
	var dst_r := Rect2i(Vector2i(x0, y0), Vector2i(x1 - x0, y1 - y0))
	var src_r := Rect2i(Vector2i(x0 - at.x, y0 - at.y), dst_r.size)
	dst.blit_rect(src, src_r, dst_r.position)


func _contains(img: Image, p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < img.get_width() and p.y < img.get_height()
