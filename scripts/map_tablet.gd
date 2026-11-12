extends Node3D
## Планшет: SubViewport с Control-UI (карта + поиск + клавиатура + тоггл),
## непрерывный (дробный) зум, маркер «вы здесь» и клик по иконкам оверлея.
##
## Тайлы карты и оверлея собирает scripts/map_tiles.gd; дробную часть зума
## применяет материал плоскостями через UV-скейл (z0 = floor(zoom) — уровень
## текстуры), поэтому пересборка нужна только при переходе через целый уровень
## или сдвиге центра.

const Cfg = preload("res://scripts/config.gd")
const Geo = preload("res://scripts/geo.gd")
const MapTiles = preload("res://scripts/map_tiles.gd")
const TabletUI = preload("res://scripts/tablet_ui.gd")
const State = preload("res://scripts/state.gd")

const PLANE_W := 0.65
const PLANE_H := PLANE_W * float(Cfg.MAP_VIEW_H) / float(Cfg.MAP_VIEW_W)

signal place_selected(lon: float, lat: float, is_city: bool)
signal overlay_changed(enabled: bool)

var zoom := 16.0
var center_ll := Vector2.ZERO
var on_status: Callable = Callable()

var plane: MeshInstance3D
var material: StandardMaterial3D
var sub_viewport: SubViewport
var ui: Node
var tiles: MapTiles

var _req_seq := 0
var _applied_seq := 0
var _refresh_pending := false
var _last_refresh_ms := 0
var _last_prefetch_ms := 0
## Готовая текстура карты и её «привязка» (центр и уровень) — для рисования
## смещением и для пересчёта пикселя тапа в пиксель текстуры.
var _tex: ImageTexture = null
var _tex_center_ll := Vector2.ZERO
var _tex_z0 := 16
## Последние отданные в UI текстура и прямоугольник — чтобы не дёргать
## перерисовку каждый кадр, когда ничего не изменилось.
var _last_draw_tex: Texture2D = null
var _last_draw_rect := Rect2()
var _here_lon := NAN
var _here_lat := NAN
var _here_heading := 0.0


func setup(lon: float, lat: float, status_cb: Callable, start_zoom := 16.0) -> void:
	on_status = status_cb
	zoom = clampf(start_zoom, Cfg.MAP_ZOOM_MIN, Cfg.MAP_ZOOM_MAX)
	center_ll = Vector2(lon, lat)

	tiles = MapTiles.new()
	tiles.setup(Vector2i(Cfg.MAP_VIEW_W, Cfg.MAP_VIEW_H))

	sub_viewport = SubViewport.new()
	sub_viewport.name = "TabletUI"
	sub_viewport.size = Vector2i(Cfg.MAP_VIEW_W, Cfg.MAP_VIEW_H)
	sub_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sub_viewport.gui_disable_input = true
	sub_viewport.transparent_bg = false
	add_child(sub_viewport)

	ui = TabletUI.new()
	ui.name = "UI"
	sub_viewport.add_child(ui)
	ui.place_selected.connect(_on_place_selected)
	ui.overlay_toggled.connect(_on_overlay_toggled)

	var mesh := QuadMesh.new()
	mesh.size = Vector2(PLANE_W, PLANE_H)
	plane = MeshInstance3D.new()
	plane.name = "Plane"
	plane.mesh = mesh

	material = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	material.albedo_texture = sub_viewport.get_texture()
	plane.material_override = material
	add_child(plane)

	var frame := MeshInstance3D.new()
	var frame_mesh := QuadMesh.new()
	frame_mesh.size = Vector2(PLANE_W * 1.06, PLANE_H * 1.09)
	frame.mesh = frame_mesh
	var frame_mat := StandardMaterial3D.new()
	frame_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	frame_mat.albedo_color = Color(0.02, 0.03, 0.04)
	frame.material_override = frame_mat
	frame.position = Vector3(0, 0, -0.002)
	add_child(frame)

	_refresh()


# --- Геометрия экрана --------------------------------------------------------


func view_px_at_local(local: Vector3) -> Vector2:
	return Vector2(
		(local.x / PLANE_W + 0.5) * float(Cfg.MAP_VIEW_W),
		(0.5 - local.y / PLANE_H) * float(Cfg.MAP_VIEW_H),
	)


func lon_lat_at_view_px(px: Vector2) -> Vector2:
	var world := _center_world() + (px - Vector2(Cfg.MAP_VIEW_W, Cfg.MAP_VIEW_H) * 0.5)
	return Geo.yandex_world_px_to_lon_lat(world, zoom)


func visual_pixel(lon: float, lat: float) -> Vector2:
	var d := Geo.yandex_world_px(lon, lat, zoom) - _center_world()
	return Vector2(Cfg.MAP_VIEW_W, Cfg.MAP_VIEW_H) * 0.5 + d


func _center_world() -> Vector2:
	return Geo.yandex_world_px(center_ll.x, center_ll.y, zoom)


## Охват видимого окна в градусах — чтобы поиск ранжировал объекты текущего города.
func _span_deg() -> Vector2:
	var s := Geo.world_scale_f(zoom)
	return Vector2(float(Cfg.MAP_VIEW_W) / s * 360.0, float(Cfg.MAP_VIEW_H) / s * 180.0)


func close_keyboard() -> void:
	if is_instance_valid(ui):
		ui.close_keyboard()


## Рисуем карту смещением готовой текстуры: показываемое окно может «уезжать»
## внутри запаса (MAP_MARGIN) без пересборки — сдвиг идёт плавно, на каждый кадр.
func _update_map_draw() -> void:
	if _tex == null or not is_instance_valid(ui):
		return
	var mag := pow(2.0, zoom - float(_tex_z0))
	var win := Vector2(tiles.window_px())
	# Экранное смещение центра текстуры относительно центра вьюпорта.
	var d := (
		Geo.yandex_world_px(_tex_center_ll.x, _tex_center_ll.y, _tex_z0)
		- Geo.yandex_world_px(center_ll.x, center_ll.y, _tex_z0)
	) * mag
	var size := win * mag
	var top_left := Vector2(Cfg.MAP_VIEW_W, Cfg.MAP_VIEW_H) * 0.5 + d - size * 0.5
	var rect := Rect2(top_left, size)
	if _last_draw_tex == _tex and _last_draw_rect == rect:
		return
	_last_draw_tex = _tex
	_last_draw_rect = rect
	ui.set_map_draw(_tex, rect)


# --- Сборка карты ------------------------------------------------------------


func _refresh() -> void:
	_req_seq += 1
	var seq := _req_seq
	var center := center_ll
	var z := zoom
	var tex: ImageTexture = await tiles.build(center, z)
	if not is_instance_valid(ui):
		return
	# Пропускаем только если более новая сборка уже применилась: иначе при
	# подряд идущих _refresh (напр. setup + set_overlay) карта осталась бы пустой,
	# пока медленная сборка с оверлеем не догрузится.
	if seq < _applied_seq:
		return
	_applied_seq = seq
	_tex = tex
	_tex_center_ll = center
	_tex_z0 = floori(z)
	ui.set_map_texture(tex)
	_update_map_draw()
	if is_instance_valid(ui):
		ui.set_search_origin(center_ll, _span_deg())
	_place_here()
	_save_state()

	if OS.get_cmdline_user_args().has("--dump"):
		var img := tex.get_image()
		DirAccess.make_dir_recursive_absolute("user://dump")
		img.save_png("user://dump/map.png")
		print("[dump] %s" % ProjectSettings.globalize_path("user://dump/map.png"))


func _schedule_refresh() -> void:
	var now := Time.get_ticks_msec()
	if now - _last_refresh_ms < Cfg.MAP_REFRESH_MS:
		_refresh_pending = true
		return
	_last_refresh_ms = now
	_refresh()


## Вызывается каждый кадр из main: рисует карту по текущему центру (плавный
## сдвиг) и добивает отложенную пересборку.
func poll() -> void:
	_update_map_draw()
	var now := Time.get_ticks_msec()
	# Подогреваем следующий уровень заранее, чтобы переход через целую границу
	# зума не упирался в декод новых тайлов.
	if now - _last_prefetch_ms > 400:
		_last_prefetch_ms = now
		var z0 := floori(zoom)
		if zoom - float(z0) > 0.5:
			tiles.prefetch(center_ll, z0 + 1)
	if not _refresh_pending:
		return
	if now - _last_refresh_ms < Cfg.MAP_REFRESH_MS:
		return
	_refresh_pending = false
	_last_refresh_ms = now
	_refresh()


# --- Зум и сдвиг -------------------------------------------------------------


func set_zoom(value: float) -> void:
	var nz := clampf(value, Cfg.MAP_ZOOM_MIN, Cfg.MAP_ZOOM_MAX)
	if is_equal_approx(nz, zoom):
		return
	var level_changed := floori(nz) != floori(zoom)
	zoom = nz
	if level_changed:
		_refresh()
	else:
		_update_map_draw()
		_place_here()


func center_on(lon: float, lat: float, new_zoom: float) -> void:
	center_ll = Vector2(lon, lat)
	zoom = clampf(new_zoom, Cfg.MAP_ZOOM_MIN, Cfg.MAP_ZOOM_MAX)
	_refresh()


func preview_drag(dx: float, dy: float) -> void:
	# dx/dy — в метрах плоскости; переводим в пиксели вьюпорта (1:1 с мировыми).
	var px := Vector2(dx / PLANE_W * float(Cfg.MAP_VIEW_W), -dy / PLANE_H * float(Cfg.MAP_VIEW_H))
	var world := _center_world() - px
	center_ll = Geo.yandex_world_px_to_lon_lat(world, zoom)
	_update_map_draw()
	_place_here()
	_maybe_recenter()


## Пересборку запускаем только когда показываемое окно вышло за запас сдвига.
func _maybe_recenter() -> void:
	if _tex == null:
		_schedule_refresh()
		return
	var d := (
		Geo.yandex_world_px(center_ll.x, center_ll.y, _tex_z0)
		- Geo.yandex_world_px(_tex_center_ll.x, _tex_center_ll.y, _tex_z0)
	)
	var lim := float(Cfg.MAP_MARGIN) * 0.6
	if absf(d.x) > lim or absf(d.y) > lim:
		_schedule_refresh()


func end_drag() -> void:
	_refresh_pending = false
	_refresh()


# --- Клик по карте -----------------------------------------------------------


func tap_at(px: Vector2) -> Dictionary:
	var layer := -1
	if _tex != null:
		var z0 := _tex_z0
		var mag := pow(2.0, zoom - float(z0))
		var win := Vector2(tiles.window_px())
		var view := Vector2(Cfg.MAP_VIEW_W, Cfg.MAP_VIEW_H)
		# Экранный пиксель тапа -> пиксель собранной текстуры (окно с запасом).
		var d_z0 := (
			Geo.yandex_world_px(center_ll.x, center_ll.y, z0)
			- Geo.yandex_world_px(_tex_center_ll.x, _tex_center_ll.y, z0)
		)
		var img := (win - view) * 0.5 + d_z0 + (px - view * 0.5) / mag
		layer = tiles.sample_overlay(Vector2i(roundi(img.x), roundi(img.y)))
	return {
		"layer": layer,
		"ll": lon_lat_at_view_px(px),
		"overlay": tiles.has_overlay(),
	}


# --- Оверлей -----------------------------------------------------------------


func set_overlay(enabled: bool) -> void:
	tiles.set_overlay(enabled)
	if is_instance_valid(ui):
		ui.set_overlay_state(enabled)
	_refresh()


func _on_overlay_toggled(enabled: bool) -> void:
	tiles.set_overlay(enabled)
	State.set_value("overlay_pano", enabled)
	_refresh()
	overlay_changed.emit(enabled)


# --- Маркер «вы здесь» -------------------------------------------------------


func set_here(lon: float, lat: float, heading_deg: float) -> void:
	_here_lon = lon
	_here_lat = lat
	_here_heading = heading_deg
	_place_here()


func _place_here() -> void:
	if not is_instance_valid(ui):
		return
	if not is_finite(_here_lon) or not is_finite(_here_lat):
		ui.set_here(false, Vector2.ZERO, 0.0)
		return
	var px := visual_pixel(_here_lon, _here_lat)
	var in_view := px.x >= 0.0 and px.y >= 0.0 \
		and px.x <= float(Cfg.MAP_VIEW_W) and px.y <= float(Cfg.MAP_VIEW_H)
	ui.set_here(in_view, px, _here_heading)


# --- UI-виджеты (диспетчер из main) -----------------------------------------


func is_ui_px(px: Vector2) -> bool:
	return is_instance_valid(ui) and ui.interactive_at(px)


func ui_press(px: Vector2) -> bool:
	return is_instance_valid(ui) and ui.handle_press(px)


func ui_release(px: Vector2) -> void:
	if is_instance_valid(ui):
		ui.handle_release(px)


func set_active(value: bool) -> void:
	visible = value
	if sub_viewport != null:
		sub_viewport.render_target_update_mode = (
			SubViewport.UPDATE_ALWAYS if value else SubViewport.UPDATE_DISABLED
		)


func _on_place_selected(lon: float, lat: float, is_city: bool) -> void:
	center_on(lon, lat, 12.0 if is_city else 16.0)
	place_selected.emit(lon, lat, is_city)


func _save_state() -> void:
	State.set_value("map", {"lon": center_ll.x, "lat": center_ll.y, "zoom": zoom})
