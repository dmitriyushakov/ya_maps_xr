extends RefCounted
## Ленивая подгрузка тайлов панорамы секторами с LOD.
##
## Сфера режется на сетку секторов (≈ тайлы самого грубого тира LOD) в
## equirect-координатах. Каждый сектор — отдельный MeshInstance3D со своей
## текстурой, собранной только из его диапазона тайлов. Пока сектор не загружен,
## виден фон (большая сфера с базовым уровнем целиком, scripts/main.gd).
##
## Целевой уровень сектора выбирается по углу к направлению взгляда: в центре
## обзора — самый крупный уровень, на периферии — уровень ниже, дальше — фон.
## Число резидентных текстур ограничено (LRU по углу к взгляду).
##
## Сетка секторов выводится из тайлов самого грубого тира LOD и не привязана к
## остальным уровням: уровни Яндекса не кратны друг другу (напр. 512/1792/3584 px
## при высотах 196/687/1375), но патч всё равно сэмплит текстуру точно —
## пересчётом UV в пиксели уровня (shaders/pano_patch.gdshader). Диапазон тайлов
## сектора берётся с перекрытием (floor/ceil), поэтому соседние сектора в общем
## крае сэмплят одни и те же пиксели и швов нет. Перекрытие — максимум по тайлу
## на край, на грубом тире его нет (сектор = тайл).

const Cfg = preload("res://scripts/config.gd")
const Pano = preload("res://scripts/panorama.gd")

## Насколько «за спину» может уехать сектор, чтобы его ещё рисовать (градусы от
## полного оборота после приближения). Запас на полу-FOV и на интерполяцию.
const SHOW_BEHIND_MARGIN_DEG := 60.0


class Patch:
	extends RefCounted

	var mesh: MeshInstance3D
	var mat: ShaderMaterial
	var col := 0
	var row := 0
	## Границы сектора в глобальных equirect-координатах.
	var u0 := 0.0
	var u1 := 1.0
	var v0 := 0.0
	var v1 := 1.0
	var center := Vector3.ZERO
	## Угловой радиус сектора (радианы): от центра до самого дальнего угла.
	var extent := 0.0
	var loaded_tier := -1
	var target_tier := -1
	var pending := false


var host: Node3D
var root: Node3D
var _patches: Array = []
## Уровни-тиры LOD (по возрастанию).
var _tiers: Array = []
## Сетка секторов (выводится из тайлов самого грубого тира).
var _sx := 1
var _sy := 1
var _yaw := 0.0
var _lat_top := PI / 2.0
var _lat_span := PI
var _radius := 1.0
var _token := 0
var _inflight := 0
var _last_pump := -1000000
var _reported := -1
var _last_fwd := Vector3(0, 0, -1)
var _eager := false
var _fade := 1.0
var _priority := 0
var _zoom := 1.0
var _zoom_uv := Vector2(0.0, 0.5)


## Выбор фонового уровня и тиров LOD из списка уровней панорамы (по возрастанию).
## Тиры — до `max_tiers` самых крупных уровней; фон — уровень прямо под нижним
## тиром (если он есть), иначе самый мелкий. Фон грузится целиком, тиры лениво.
static func plan(levels: Array, max_tiers: int) -> Dictionary:
	if levels.is_empty():
		return {"backdrop": {}, "tiers": []}
	var n := levels.size()
	var start := maxi(0, n - max_tiers)
	var tiers: Array = levels.slice(start)
	var backdrop: Dictionary = levels[start - 1] if start > 0 else levels[0]
	# Нижний тир, совпавший с фоном, как тир не нужен.
	while not tiers.is_empty() and int(tiers[0]["width"]) <= int(backdrop["width"]):
		tiers = tiers.slice(1)
	return {"backdrop": backdrop, "tiers": tiers}


## Освобождает все патчи (смена панорамы).
func clear() -> void:
	if root != null and is_instance_valid(root):
		root.queue_free()
	root = null
	_patches.clear()
	_tiers.clear()
	_sx = 1
	_sy = 1
	_inflight = 0
	_last_pump = -1000000
	_reported = -1


func setup(host_node: Node3D, pano: Dictionary, plan_dict: Dictionary, token: int, radius: float) -> void:
	clear()
	host = host_node
	_token = token
	_yaw = deg_to_rad(float(pano.get("yaw_origin", 0.0)) + Cfg.YAW_FIX_DEG)
	# Вертикальная геометрия развёртки — та же, что у фоновой сферы (pano_view).
	_lat_top = float(pano.get("lat_top", PI / 2.0))
	_lat_span = float(pano.get("lat_span", PI))
	_radius = radius
	root = Node3D.new()
	root.name = "PanoPatches"
	host.add_child(root)

	_tiers = plan_dict.get("tiers", [])
	if _tiers.is_empty():
		return

	# Сектор ≈ тайл самого грубого тира, но целимся в SECTOR_COLS x ROWS секторов.
	var cols := Pano.level_cols(_tiers[0])
	var rows := Pano.level_rows(_tiers[0])
	_sx = clampi(Cfg.SECTOR_COLS, 1, cols)
	_sy = clampi(Cfg.SECTOR_ROWS, 1, rows)

	# Отбрасываем тиры, чья секторная текстура вышла бы за разумный размер.
	# Самый грубый тир (по его тайлам строится сетка) остаётся всегда.
	var safe: Array = []
	for t in _tiers:
		if _tier_fits(t):
			safe.append(t)
	_tiers = safe
	if _tiers.is_empty():
		return

	for r in _sy:
		for c in _sx:
			_add_patch(c, r)


func _tier_fits(t: Dictionary) -> bool:
	var cols := Pano.level_cols(t)
	var rows := Pano.level_rows(t)
	var tw := int(t["tile_w"])
	var th := int(t["tile_h"])
	# Худший случай: сектор + один тайл перекрытия на край.
	var tx := int(ceil(float(cols) / float(_sx))) + 1
	var ty := int(ceil(float(rows) / float(_sy))) + 1
	return maxi(tx * tw, ty * th) <= Cfg.SECTOR_MAX_TEX


func set_eager(value: bool) -> void:
	## Режим дампа/скриншота: грузим все сектора на верхнем тире, без LOD.
	_eager = value


## Общая прозрачность секторов (для кроссфейда перехода).
func set_fade(value: float) -> void:
	_fade = value
	for p in _patches:
		p.mat.set_shader_parameter("fade", value)


## Базовый приоритет отрисовки: у входящей панорамы выше, чем у исходящей,
## чтобы её сектора ложились поверх по мере загрузки.
func set_priority(base: int) -> void:
	_priority = base
	for p in _patches:
		p.mat.render_priority = base


## Приближение: точка взгляда (equirect) и коэффициент. Сектора и фон должны
## использовать одно и то же, иначе картинки разъедутся.
func set_zoom(uv: Vector2, zoom: float) -> void:
	if _zoom_uv.is_equal_approx(uv) and is_equal_approx(zoom, _zoom):
		return
	_zoom = zoom
	_zoom_uv = uv
	var sharp := _sharpen_amount()
	for p in _patches:
		p.mat.set_shader_parameter("zoom", zoom)
		p.mat.set_shader_parameter("zoom_uv", uv)
		p.mat.set_shader_parameter("sharpen", sharp)
	# Приближение меняет видимую область панорамы — цели по LOD надо пересчитать
	# сразу, а не ждать следующего тика (STREAM_INTERVAL_MS).
	_last_pump = -1000000


## Сила шарпена на приближении: цифровое растяжение уровня даёт мыло, высокие
## частоты подтягиваем тем сильнее, чем больше зум.
func _sharpen_amount() -> float:
	return clampf((_zoom - 1.0) * Cfg.ZOOM_SHARPEN_RATE, 0.0, Cfg.ZOOM_SHARPEN_MAX)


func loaded_count() -> int:
	var n := 0
	for p in _patches:
		if p.loaded_tier >= 0:
			n += 1
	return n


func total_count() -> int:
	return _patches.size()


## Вызывать каждый кадр из _process. `cam_fwd` — мировой вектор взгляда; переводим
## его в локальную систему сферы (её можно разворачивать стиком).
func pump(cam_pos: Vector3, cam_fwd: Vector3) -> void:
	if root == null or not is_instance_valid(root):
		return
	_pump_local((root.global_transform.basis.inverse() * cam_fwd).normalized())


func _pump_local(cam_fwd: Vector3) -> void:
	if root == null or _tiers.is_empty() or _patches.is_empty():
		return
	var now := Time.get_ticks_msec()
	if not _eager and now - _last_pump < Cfg.STREAM_INTERVAL_MS:
		return
	_last_pump = now
	_last_fwd = cam_fwd

	# Здесь выбирается только ДЕМАНД: что тянуть из сети. Показ от него не зависит —
	# каждый сектор всегда рисует ту текстуру, что у него уже загружена (самый
	# крупный из приехавших тайлов), а сектор вообще без текстуры просто не виден, и
	# сквозь него видно фон. Вытесняем загруженное только по лимиту резидентных
	# (LRU по направлению взгляда), не по «ненужности»: уехавший из виду сектор
	# остаётся в памяти и мгновенно готов, когда на него вернёшься.
	var top_tier := _tiers.size() - 1
	var wanted: Array = []
	for p in _patches:
		# ang — угол до центра сектора (по нему выбираем уровень),
		# eff — угол до ближайшего края (по нему решаем, стоит ли качать).
		var ang := rad_to_deg(acos(clampf(cam_fwd.dot(p.center), -1.0, 1.0)))
		var ext := rad_to_deg(p.extent)
		var eff := maxf(ang - ext, 0.0)
		if _eager:
			p.target_tier = top_tier
		else:
			p.target_tier = _demand_tier(ang, eff, p.loaded_tier)
		# Показ: сектор уезжает от взгляда в zoom раз, и если он уехал дальше
		# «за спину» с запасом, его контент вернулся бы на экран чужим местом
		# (k·θ прошло полный оборот). Не показываем такой сектор, даже если он
		# в памяти: на экране он всё равно не нужен, а дубль испортил бы кадр.
		var far_deg := _zoom * (ang + ext)
		p.mesh.visible = p.loaded_tier >= 0 and far_deg <= 360.0 - SHOW_BEHIND_MARGIN_DEG
		if p.target_tier > p.loaded_tier and not p.pending:
			wanted.append({"ang": ang, "p": p})

	wanted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["ang"]) < float(b["ang"])
	)

	if not _eager:
		_evict_over_cap()

	for item in wanted:
		if _inflight >= Cfg.MAX_INFLIGHT:
			break
		var p: Patch = item["p"]
		_start_job(p, p.target_tier)

	if OS.is_debug_build() and loaded_count() != _reported:
		_reported = loaded_count()
		var per := PackedInt32Array()
		per.resize(_tiers.size())
		for p in _patches:
			if p.loaded_tier >= 0:
				per[p.loaded_tier] += 1
		var parts := PackedStringArray()
		for i in _tiers.size():
			parts.append("%dpx:%d" % [int(_tiers[i]["width"]), per[i]])
		print("[pano] секторов %d/%d [%s]" % [_reported, _patches.size(), ", ".join(parts)])


## Ждёт, пока все нужные сектора догрузятся (для дампа/скриншота).
func wait_idle(max_frames := 6000) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var frames := 0
	while frames < max_frames:
		# Сначала выставляем цели/задания: до первого pump они ещё не заданы.
		_pump_local(_last_fwd)
		if _inflight == 0 and not _has_wanted():
			return
		await tree.process_frame
		frames += 1


func _has_wanted() -> bool:
	for p in _patches:
		if p.pending or p.target_tier > p.loaded_tier:
			return true
	return false


## Уровень, который имеет смысл тянуть из сети для этого сектора (по направлению
## взгляда), или -1 — «качать нечего». Это только деманд: показать сектор всё равно
## покажет то, что уже загружено, а -1 означает лишь «не ходить в сеть».
func _demand_tier(ang: float, eff: float, current: int) -> int:
	var n := _tiers.size()
	if n == 0:
		return -1
	var hyst := Cfg.PATCH_LOD_HYST_DEG
	# Топовый тир — у сектора под центром экрана (по БЛИЖАЙШЕЙ точке, eff≈0, т.е.
	# направление взгляда внутри сектора) И у секторов, чья ближняя кромка в конусе
	# hot. Так тайл под центром экрана всегда максимального разрешения, даже если
	# центр сектора далеко (сетка 8x4 грубая). Периферия — на тир ниже.
	# ang/eff — «контентные» углы (геометрия меша — до приближения). Приближение
	# разворачивает сектор от взгляда в zoom раз (и вершинами, и фоном — одинаково),
	# поэтому пороги делим на zoom: картина уровней на экране остаётся той же — до
	# ~30° топовый тир, дальше на тир ниже, а «нужен/не нужен» — по краю окна
	# панорамы (FOV/zoom). Иначе на зуме 3 пол-экрана занимал бы фон.
	var z := maxf(_zoom, 1.0)
	var hot := (Cfg.PATCH_LOD_HOT_DEG + (hyst if current >= n - 1 else 0.0)) / z
	var warm := (Cfg.PATCH_LOD_WARM_DEG + (hyst if current >= maxi(n - 2, 0) else 0.0)) / z
	if ang <= hot or eff <= 0.5 / z:
		return n - 1
	if n >= 2 and eff <= warm:
		return n - 2
	return -1


func _evict_over_cap() -> void:
	var cap := Cfg.MAX_RESIDENT_PATCHES
	var resident: Array = []
	for p in _patches:
		if p.loaded_tier >= 0 and not p.pending:
			resident.append(p)
	if resident.size() <= cap:
		return
	resident.sort_custom(func(a: Patch, b: Patch) -> bool:
		return a.center.dot(_last_fwd) < b.center.dot(_last_fwd)
	)
	var excess := resident.size() - cap
	for i in resident.size():
		if excess <= 0:
			break
		_release(resident[i])
		excess -= 1


func _release(p: Patch) -> void:
	p.mat.set_shader_parameter("tex", null)
	p.mesh.visible = false
	p.loaded_tier = -1
	p.target_tier = -1


func _start_job(p: Patch, tier: int) -> void:
	var token := _token
	var lvl: Dictionary = _tiers[tier]
	var w := float(lvl["width"])
	var h := float(lvl["height"])
	var tw := float(lvl["tile_w"])
	var th := float(lvl["tile_h"])
	var cols := Pano.level_cols(lvl)
	var rows := Pano.level_rows(lvl)

	# Диапазон тайлов с перекрытием: текстура покрывает пиксели сектора с запасом.
	var x0 := int(floor(p.u0 * w / tw))
	var x1 := int(ceil(p.u1 * w / tw))
	var y0 := int(floor(p.v0 * h / th))
	var y1 := int(ceil(p.v1 * h / th))
	x0 = clampi(x0, 0, cols - 1)
	x1 = clampi(x1, x0 + 1, cols)
	y0 = clampi(y0, 0, rows - 1)
	y1 = clampi(y1, y0 + 1, rows)

	_inflight += 1
	p.pending = true
	var tex: ImageTexture = await Pano.build_range(lvl, x0, x1, y0, y1)

	# Если стример переинициализирован (смена панорамы), _inflight уже сброшен.
	if token != _token:
		return
	p.pending = false
	_inflight -= 1
	if tex == null:
		return
	# Размер текстуры обрезан по реальным размерам уровня (см. Pano.build_range).
	var px0 := x0 * tw
	var py0 := y0 * th
	var px1 := minf(x1 * tw, w)
	var py1 := minf(y1 * th, h)
	p.mat.set_shader_parameter("tex", tex)
	p.mat.set_shader_parameter("pano_px", Vector2(w, h))
	p.mat.set_shader_parameter("tile_px", Vector2(px0, py0))
	p.mat.set_shader_parameter("tex_px", Vector2(px1 - px0, py1 - py0))
	p.mesh.visible = true
	p.loaded_tier = tier


func _add_patch(c: int, r: int) -> void:
	var p := Patch.new()
	p.col = c
	p.row = r
	p.u0 = float(c) / float(_sx)
	p.u1 = float(c + 1) / float(_sx)
	p.v0 = float(r) / float(_sy)
	p.v1 = float(r + 1) / float(_sy)
	p.center = _dir_from_uv((p.u0 + p.u1) * 0.5, (p.v0 + p.v1) * 0.5, 1.0)
	p.extent = _angular_extent(p)
	p.mesh = _make_patch_mesh(p)
	p.mat = ShaderMaterial.new()
	p.mat.shader = load("res://shaders/pano_patch.gdshader")
	p.mat.set_shader_parameter("fade", _fade)
	p.mat.set_shader_parameter("zoom", _zoom)
	p.mat.set_shader_parameter("zoom_uv", _zoom_uv)
	p.mat.set_shader_parameter("sharpen", _sharpen_amount())
	p.mat.set_shader_parameter("radius", _radius)
	p.mat.set_shader_parameter("yaw_rad", _yaw)
	p.mat.set_shader_parameter("lat_top_rad", _lat_top)
	p.mat.set_shader_parameter("lat_span_rad", _lat_span)
	p.mat.render_priority = _priority
	p.mesh.material_override = p.mat
	p.mesh.visible = false
	root.add_child(p.mesh)
	_patches.append(p)


func _make_patch_mesh(p: Patch) -> MeshInstance3D:
	var n := maxi(Cfg.SECTOR_SUBDIV, 1)
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	for iy in n + 1:
		for ix in n + 1:
			var lu := float(ix) / float(n)
			var lv := float(iy) / float(n)
			var gu := lerpf(p.u0, p.u1, lu)
			var gv := lerpf(p.v0, p.v1, lv)
			verts.append(_dir_from_uv(gu, gv, _radius))
			uvs.append(Vector2(gu, gv))

	var idx := PackedInt32Array()
	for iy in n:
		for ix in n:
			var a := iy * (n + 1) + ix
			var b := a + 1
			var cc := a + n + 1
			var d := cc + 1
			idx.append(a)
			idx.append(cc)
			idx.append(b)
			idx.append(b)
			idx.append(cc)
			idx.append(d)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mi := MeshInstance3D.new()
	mi.name = "Patch_%d_%d" % [p.col, p.row]
	mi.mesh = mesh
	return mi


func _angular_extent(p: Patch) -> float:
	var m := 0.0
	for u in [p.u0, p.u1]:
		for v in [p.v0, p.v1]:
			var d := _dir_from_uv(u, v, 1.0)
			m = maxf(m, acos(clampf(p.center.dot(d), -1.0, 1.0)))
	return m


## Точка на сфере по глобальным equirect-координатам (u — долгота 0..1,
## v — вертикальная координата 0..1, v=0 — верхний край развёртки). Согласовано с
## shaders/panorama.gdshader: lat = lat_top - v·lat_span.
func _dir_from_uv(u: float, v: float, radius: float) -> Vector3:
	var az := u * TAU + _yaw
	var lat := _lat_top - v * _lat_span
	var cl := cos(lat)
	return Vector3(sin(az) * cl, sin(lat), -cos(az) * cl) * radius
