extends RefCounted
## Один вид панорамы: сфера-фон, стрелки перехода и стример секторов.
##
## Во время перехода видов одновременно два: исходящий гаснет (и «надвигается»),
## входящий проявляется. Поэтому у материала сферы и секторов есть параметр
## `fade`, а порядок отрисовки задаётся render_priority (входящий — ниже).

const Cfg = preload("res://scripts/config.gd")
const PanoStream = preload("res://scripts/pano_stream.gd")

const SPHERE_RADIUS := 10.0
const ARROW_RADIUS := 2.6
## Воздушные маркеры ставим далеко — чтобы читались «вон там, где та панорама»,
## а не у ног, как уличные шевроны.
const AIR_MARKER_RADIUS := 8.5
## Высота шевронов над центром сферы (камера примерно на высоте глаз — шевроны
## висят ниже линии взгляда). Пониже = отрицательнее.
const ARROW_Y := -0.5
const PLACEHOLDER_SIZE := Vector2i(1024, 512)
const ARROW_ALPHA := 0.9

var root: Node3D
var sphere: MeshInstance3D
var material: ShaderMaterial
var arrows: Node3D
var streamer: Variant = null
## Центр панорамы (точка съёмки) в мировых координатах. Сферу ставим туда, где
## голова была в момент открытия панорамы: иначе глаз оказывается в стороне от
## центра развёртки (в STAGE-пространстве — на высоте глаз над полом, т.е. ~1.6 м
## выше центра) и картинка уезжает по вертикали на ~9°.
var anchor := Vector3.ZERO
var _priority_base := 0
var _arrows_hidden := false
var _yaw_deg := 0.0
var _lat_top := PI / 2.0
var _lat_span := PI
var _zoom_last := -1.0
var _zoom_uv_last := Vector2(-1.0, -1.0)

static var _arrow_texture: Texture2D
static var _airship_texture: Texture2D


func build(host: Node3D) -> void:
	root = Node3D.new()
	host.add_child(root)

	sphere = MeshInstance3D.new()
	sphere.name = "PanoramaSphere"
	var mesh := SphereMesh.new()
	mesh.radius = SPHERE_RADIUS
	mesh.height = SPHERE_RADIUS * 2.0
	mesh.radial_segments = 64
	mesh.rings = 40
	sphere.mesh = mesh

	material = ShaderMaterial.new()
	material.shader = load("res://shaders/panorama.gdshader")
	material.set_shader_parameter("pano", _placeholder_texture())
	material.set_shader_parameter("yaw_origin_deg", 0.0)
	material.set_shader_parameter("lat_top", PI / 2.0)
	material.set_shader_parameter("lat_span", PI)
	material.set_shader_parameter("yaw_fix_deg", Cfg.YAW_FIX_DEG)
	material.set_shader_parameter("fade", 1.0)
	material.set_shader_parameter("zoom", 1.0)
	material.set_shader_parameter("zoom_uv", Vector2(0.0, 0.5))
	sphere.material_override = material
	root.add_child(sphere)

	arrows = Node3D.new()
	arrows.name = "Arrows"
	root.add_child(arrows)


## Центр панорамы (точка съёмки) — туда, где была голова при открытии.
func set_anchor(pos: Vector3) -> void:
	anchor = pos
	if root != null and is_instance_valid(root):
		root.position = pos


func dispose() -> void:
	if streamer != null:
		streamer.clear()
		streamer = null
	if root != null and is_instance_valid(root):
		root.queue_free()
	root = null


func set_backdrop(tex: Texture2D) -> void:
	material.set_shader_parameter("pano", tex)


## Проекция развёртки: азимут шва и вертикальная геометрия.
## `lat_top_rad` — широта ВЕРХНЕГО края, `lat_span_rad` — вертикальный охват
## (2π·H/W). Фон-сфера и сектора используют одну пару, поэтому «частичные»
## панорамы (не всё небо/надир) не растягиваются до полюсов; направление вне
## охвата прозрачно (тёмный фон), как в плеере Яндекса.
func set_projection(yaw_origin_deg: float, lat_top_rad: float, lat_span_rad: float) -> void:
	_yaw_deg = yaw_origin_deg
	_lat_top = lat_top_rad
	_lat_span = lat_span_rad
	material.set_shader_parameter("yaw_origin_deg", yaw_origin_deg)
	material.set_shader_parameter("lat_top", lat_top_rad)
	material.set_shader_parameter("lat_span", lat_span_rad)
	material.set_shader_parameter("yaw_fix_deg", Cfg.YAW_FIX_DEG)


## Приближение панорамы: центр зума — точка, куда смотрит камера (в equirect
## сферы). Одинаковые zoom/zoom_uv идут и в фон, и в сектора.
##
## Шевроны и планшет в приближении не участвуют (HUD): панорама «уезжает», а
## стрелки остаются на своих местах — иначе на зуме стрелку сдувает в зенит, и по
## ней уже не ткнёшь. Это осознанный компромисс: стрелка на большом зуме может
## стоять не над тем местом панорамы, зато она всегда там, где ожидается, и клик
## (рейкаст по её позиции) работает.
##
## Маркеры соседей воздушной панорамы — наоборот, часть панорамы: к ним применяем
## ту же угловую магнификацию, что к фону и секторам, иначе на приближении они
## расходятся с картинкой («параллакс»). См. `_update_marker_zoom`.
func update_zoom(cam_pos: Vector3, cam_fwd: Vector3, zoom: float) -> void:
	var uv := _zoom_center(cam_pos, cam_fwd)
	if absf(zoom - _zoom_last) < 0.002 and uv.distance_squared_to(_zoom_uv_last) < 1e-6:
		return
	_zoom_last = zoom
	_zoom_uv_last = uv
	material.set_shader_parameter("zoom", zoom)
	material.set_shader_parameter("zoom_uv", uv)
	material.set_shader_parameter(
		"sharpen", clampf((zoom - 1.0) * Cfg.ZOOM_SHARPEN_RATE, 0.0, Cfg.ZOOM_SHARPEN_MAX)
	)
	if streamer != null:
		streamer.set_zoom(uv, zoom)
	_update_marker_zoom(uv, zoom)


func _zoom_center(cam_pos: Vector3, cam_fwd: Vector3) -> Vector2:
	if root == null or not is_instance_valid(root):
		return Vector2(0.0, 0.5)
	# Луч взгляда из камеры → дальняя точка на сфере → направление от центра
	# сферы (именно направление задаёт UV в шейдере).
	var center := root.global_position
	var r := SPHERE_RADIUS * maxf(root.scale.x, 0.0001)
	var oc := cam_pos - center
	var b := oc.dot(cam_fwd)
	var disc := maxf(b * b - (oc.length_squared() - r * r), 0.0)
	var t := -b + sqrt(disc)
	if t <= 0.0:
		t = maxf(-b - sqrt(disc), 0.0001)
	var hit := cam_pos + cam_fwd * t
	var d := (root.global_transform.basis.inverse() * (hit - center)).normalized()
	var yaw := deg_to_rad(_yaw_deg + Cfg.YAW_FIX_DEG)
	var az := atan2(d.x, -d.z)
	var u := fposmod((az - yaw) / TAU, 1.0)
	var v := (_lat_top - asin(clampf(d.y, -1.0, 1.0))) / _lat_span
	return Vector2(u, v)


func set_fade(value: float) -> void:
	material.set_shader_parameter("fade", value)
	if streamer != null:
		streamer.set_fade(value)
	_apply_arrows_fade(value)


func _apply_arrows_fade(value: float) -> void:
	var a := 0.0 if _arrows_hidden else ARROW_ALPHA * value
	for group in arrows.get_children():
		var quad := group.get_child(0) as MeshInstance3D
		if quad != null:
			var m := quad.material_override as StandardMaterial3D
			if m != null:
				m.albedo_color.a = a


## Спрятать стрелки (мгновенно). На переходе старые шевроны убираем сразу, чтобы
## они не висели, пока их перекроет новая сфера.
func hide_arrows() -> void:
	_arrows_hidden = true
	_apply_arrows_fade(1.0)


func show_arrows() -> void:
	_arrows_hidden = false
	_apply_arrows_fade(1.0)


## Прозрачность только фоновой сферы (не трогает сектора/стрелки).
## Нужна при переходе: держим фон входящей скрытым, пока не загрузится, но
## сектора при этом видны как приехали (раскрытие по загрузке), и наоборот —
## плавно проявляем фон при свапе.
func set_backdrop_fade(value: float) -> void:
	material.set_shader_parameter("fade", value)


func set_priority(base: int) -> void:
	# Порядок прозрачных слоёв: фон(base) -> сектора(base+1) -> стрелки(base+2).
	_priority_base = base
	material.render_priority = base
	if streamer != null:
		streamer.set_priority(base + 1)
	for group in arrows.get_children():
		var quad := group.get_child(0) as MeshInstance3D
		if quad != null:
			var m := quad.material_override as StandardMaterial3D
			if m != null:
				m.render_priority = base + 2


func build_arrows(links: Array) -> void:
	for child in arrows.get_children():
		child.queue_free()
	for link in links:
		var yaw := float(link.get("yaw", 0.0))
		# Шевроны висят на фиксированной высоте ОТ ПОЛА, а не от центра сферы:
		# центр теперь на голове (anchor, см. pano_view.set_anchor), и без этой
		# поправки они уезжают вверх вместе с ним. Так их место не зависит ни от
		# центра развёртки, ни от роста пользователя.
		var y := ARROW_Y - anchor.y
		var pos := Vector3(sin(yaw) * ARROW_RADIUS, y, -cos(yaw) * ARROW_RADIUS)
		_add_marker(pos, yaw, Color(1, 1, 1), link)
	_apply_arrows_fade(1.0)


## Маркеры соседей воздушной панорамы: направление (yaw+pitch) считается из
## координат, маркер — билборд с иконкой дирижабля Яндекса (styles/airship.png),
## чтобы отличался от уличных шевронов. Каждый элемент — {id, name, dir}.
func build_markers(items: Array) -> void:
	for child in arrows.get_children():
		child.queue_free()
	for it in items:
		var dir: Vector3 = it.get("dir", Vector3.ZERO)
		if dir.length() < 0.0001:
			continue
		dir = dir.normalized()
		var link := {
			"id": str(it.get("id", "")),
			"name": str(it.get("name", "")),
			"yaw": atan2(dir.x, -dir.z),
		}
		_add_air_marker(dir, link)
	_apply_arrows_fade(1.0)
	# Если приближение уже включено — сразу ставим маркеры на магнифицированные
	# направления (иначе кадр-другой они висят в базовых точках).
	if _zoom_last >= 1.0:
		_update_marker_zoom(_zoom_uv_last, _zoom_last)


func _add_air_marker(dir: Vector3, link: Dictionary) -> void:
	var group := Node3D.new()
	group.position = dir * AIR_MARKER_RADIUS
	group.set_meta("link", link)
	group.set_meta("air", true)
	# Базовое направление контента (локальный фрейм сферы) — по нему маркер
	# пересчитывается при приближении (см. _update_marker_zoom).
	group.set_meta("dir", dir)
	_orient_air_marker(group)

	var quad := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.35, 0.35 * 30.0 / 27.0) # пропорции иконки дирижабля
	quad.mesh = mesh

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.render_priority = _priority_base + 2
	mat.albedo_texture = _airship_tex()
	mat.albedo_color = Color(1, 1, 1, ARROW_ALPHA)
	quad.material_override = mat

	group.add_child(quad)
	arrows.add_child(group)


## Ориентация маркера ФИКСИРОВАНА в мире (не билборд): нормаль (локальная +Z)
## смотрит в центр сферы, верх (локальная +Y) — по мировой вертикали. Поэтому
## поворот головы по рысканью/наклону маркер не крутит. Базис — правый, +Y вверх.
func _orient_air_marker(group: Node3D) -> void:
	var z_axis := -group.position.normalized()
	var y_axis := Vector3.UP - z_axis * Vector3.UP.dot(z_axis)
	if y_axis.length() < 1e-4:
		y_axis = Vector3.FORWARD
	y_axis = y_axis.normalized()
	var x_axis := y_axis.cross(z_axis).normalized() # x = y × z (right-handed)
	group.transform.basis = Basis(x_axis, y_axis, z_axis)


## Сдвигает маркеры воздушных соседей той же угловой магнификацией, что фон и
## сектора: контент под углом θ от точки взгляда встаёт под углом θ·zoom. Маркер —
## часть панорамы, поэтому он «приклеен» к своему месту и не даёт параллакса.
func _update_marker_zoom(uv: Vector2, zoom: float) -> void:
	var g := _dir_from_uv_local(uv)
	for group in arrows.get_children():
		if not bool(group.get_meta("air", false)):
			continue
		var base: Vector3 = group.get_meta("dir", Vector3.ZERO)
		if base.length_squared() < 1e-8:
			continue
		# Угол до маркера ПОСЛЕ магнификации: θ·zoom. За 180° он «перескакивает»
		# за спину и выныривает уже с другой стороны (ровно как сектор в
		# pano_stream), поэтому такой маркер прячем — иначе он «летает из края в
		# край» и кажется, будто висит перед глазами.
		var th := acos(clampf(base.dot(g), -1.0, 1.0)) * zoom
		group.visible = th < PI - 0.03
		if not group.visible:
			continue
		var d := _rotate_about(base, g, zoom)
		group.position = d * AIR_MARKER_RADIUS
		_orient_air_marker(group)


## Направление по equirect (u,v) в локальном фрейме сферы — согласовано с
## shaders/panorama.gdshader (dir_from_uv).
func _dir_from_uv_local(uv: Vector2) -> Vector3:
	var yaw := deg_to_rad(_yaw_deg + Cfg.YAW_FIX_DEG)
	var az := uv.x * TAU + yaw
	var lat := _lat_top - uv.y * _lat_span
	var cl := cos(lat)
	return Vector3(sin(az) * cl, sin(lat), -cos(az) * cl)


## Поворот направления d к g по большой окружности так, что угол θ переходит в
## θ·scale. Тождественно rotate_about из shaders/panorama.gdshader и pano_patch.
static func _rotate_about(d: Vector3, g: Vector3, scale: float) -> Vector3:
	var ct := clampf(d.dot(g), -1.0, 1.0)
	var t := d - g * ct
	var tl := t.length()
	if tl < 1e-6:
		return d
	var th := acos(ct) * scale
	return (g * cos(th) + (t / tl) * sin(th)).normalized()


func _add_marker(pos: Vector3, yaw: float, color: Color, link: Dictionary) -> void:
	var group := Node3D.new()
	group.position = pos
	group.rotation.y = -yaw
	group.set_meta("link", link)

	var quad := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.95, 0.95)
	quad.mesh = mesh
	quad.rotation.x = -PI / 2.0

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.render_priority = _priority_base + 2
	mat.albedo_texture = _arrow_tex()
	mat.albedo_color = Color(color.r, color.g, color.b, ARROW_ALPHA)
	quad.material_override = mat

	group.add_child(quad)
	arrows.add_child(group)


static func _placeholder_texture() -> Texture2D:
	var small := Image.create(64, 32, false, Image.FORMAT_RGB8)
	small.fill(Color(0.05, 0.07, 0.09))
	for x in 64:
		for y in 32:
			if x % 8 == 0 or y % 8 == 0:
				small.set_pixel(x, y, Color(0.1, 0.15, 0.2))
	small.resize(PLACEHOLDER_SIZE.x, PLACEHOLDER_SIZE.y, Image.INTERPOLATE_NEAREST)
	return ImageTexture.create_from_image(small)


static func _airship_tex() -> Texture2D:
	if _airship_texture != null:
		return _airship_texture
	_airship_texture = load("res://assets/airship.png")
	return _airship_texture


static func _arrow_tex() -> Texture2D:
	if _arrow_texture != null:
		return _arrow_texture
	var size := 128
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var color := Color(0.85, 0.95, 1.0, 1.0)

	# Древко.
	for y in range(58, 116):
		for x in range(52, 76):
			img.set_pixel(x, y, color)
	# Наконечник.
	for y in range(10, 70):
		var t := float(y - 10) / 60.0
		var half := lerpf(2.0, 38.0, t)
		for x in range(int(64.0 - half), int(64.0 + half)):
			if x >= 0 and x < size:
				img.set_pixel(x, y, color)

	img.generate_mipmaps()
	_arrow_texture = ImageTexture.create_from_image(img)
	return _arrow_texture
