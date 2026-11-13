extends Node3D
## Главная сцена: XR-риг, сфера-панорама, стрелки, планшет с картой.

const Cfg = preload("res://scripts/config.gd")
const Pano = preload("res://scripts/panorama.gd")
const PanoStream = preload("res://scripts/pano_stream.gd")
const PanoView = preload("res://scripts/pano_view.gd")
const MapTabletScript = preload("res://scripts/map_tablet.gd")
const Search = preload("res://scripts/search.gd")
const State = preload("res://scripts/state.gd")

## Переход между панорамами, секунды: фаза наезда (стартует сразу) и короткий
## кроссфейд фоновой сферы в момент свапа. Само раскрытие — по мере загрузки
## (сектора и фон входящей проявляются, как только приехали).
const TRANSITION_MOVE_SEC := 0.35
const TRANSITION_MOVE_SCALE := 0.7
## Дополнительный «долли» к шеврону, метры: сфера уезжает назад, ты — вперёд.
const TRANSITION_MOVE_SHIFT := 1.5
const TRANSITION_SWAP_FADE_SEC := 0.18

## Поворот вокруг своей оси левым стиком, градусов в секунду, и мёртвая зона.
const TURN_SPEED_DEG := 100.0
const TURN_DEADZONE := 0.2
## Приближение панорамы левым стиком (вертикаль), предел и скорость.
const ZOOM_MIN := 1.0
const ZOOM_MAX := 3.0
const ZOOM_RATE := 2.0
## Порог в метрах плоскости: меньше — тап (клик), больше — сдвиг карты.
const TAP_MAX_MOVE := 0.02
## Длина луча-указки (м) и небольшой заход за панель планшета (м): кончик должен
## касаться поверхности, лёгкий заход не страшен.
const POINTER_RAY_LEN := 6.0
const POINTER_RAY_OVERLAP := 0.01
## Половина стороны квада шеврона-перехода (QuadMesh 0.95×0.95), м — для проверки,
## попал ли луч в стрелку.
const ARROW_QUAD_HALF := 0.475

## Модели контроллеров. Если рантайм умеет render models — показываем штатные
## (анимированные). Иначе крепим свои готовые OBJ из системного ассета шлема
## (единицы файла — сантиметры, отсюда масштаб 0.01) на отдельный трекер в позе
## grip. Посадку правим поворотом (градусы) и сдвигом (м) в системе grip.
const HAND_LEFT_OBJ := "res://assets/controller_left.obj"
const HAND_RIGHT_OBJ := "res://assets/controller_right.obj"
const HAND_TEX := "res://assets/controller_atlas.png"
const HAND_SHADER := "res://shaders/hand.gdshader"
const HAND_MODEL_SCALE := 0.01
const HAND_MODEL_ROT_DEG := Vector3(0.0, 0.0, 0.0)
const HAND_MODEL_OFFSET := Vector3.ZERO

## Части модели контроллера — индексы устойчивы (порядок `_split_islands`), левая и
## правая совпадают. Проверены цветным рендером (`--hands-shot --islands`).
const HAND_PART_STICK := 2
const HAND_PART_GRIP := 3
const HAND_PART_TRIGGER := 4
const HAND_PART_BY := 5   # Y на левой, B на правой
const HAND_PART_AX := 6   # X на левой, A на правой
const HAND_PART_MENU := 8
## Ход частей при нажатии: вдавливаются вдоль своей нормали (сантиметры).
const HAND_PRESS_BUTTON := 0.12
const HAND_PRESS_GRIP := 0.20
const HAND_PRESS_STICK := 0.10
## Наклон стика от отклонения (градусы) и поворот курка вокруг кромки.
const HAND_STICK_TILT_DEG := 12.0
const HAND_TRIGGER_TILT_DEG := 14.0

var xr_origin: XROrigin3D
var xr_camera: XRCamera3D
var left_controller: XRController3D
var right_controller: XRController3D
var tablet: Variant
var left_ray: MeshInstance3D
var right_ray: MeshInstance3D
var left_grip: XRController3D
var right_grip: XRController3D
var left_model: Node3D
var right_model: Node3D
## Штатный менеджер модели левой руки (когда рантайм умеет render models).
var _left_render_model: OpenXRRenderModelManager
## Части моделей рук: "left"/"right" -> Array[MeshInstance3D] (см. `_split_islands`).
var _hand_parts: Dictionary = {}
## Модели контроллеров уже построены (штатные render models или свои OBJ).
var _hands_built := false
## Используем штатные render models рантайма, а не свои модели.
var _hands_native := false

## Текущий вид панорамы и входящий (только во время перехода).
var _view: Variant = null
var _incoming: Variant = null
var _transitioning := false
var _incoming_ready := false
var _incoming_failed := false
var _incoming_full := false

## Кэш предзагруженных соседей: oid -> {pano, levels, plan, low}.
var _cache: Dictionary = {}
var _prefetching := false
var _last_links: Array = []
## Направление и точка-якорь «наезда» на текущий переход.
var _move_dir := Vector3(0, 0, -1)
var _move_cam := Vector3.ZERO
## Проигрывать ли наезд (только переходы по шевронам, не телепорт по карте).
var _transition_animate := true
## Приближение панорамы левым стиком (вертикаль).
var _zoom := 1.0
## Лоурес соседей — на грейд выше самого мелкого (см. Cfg.INCOMING_LOW_STEP),
## поэтому текстуры крупнее: держим кэш короче.
const CACHE_MAX := 4

var _load_token := 0
var _here_lon := NAN
var _here_lat := NAN

var _trigger_down := false
var _left_trigger_down := false
var _left_ax_down := false
var _drag_last: Variant = null
var _drag_moved := 0.0
## Нажатие триггера попало в виджет UI планшета (кнопки/клавиатура), а не в карту.
var _ui_press := false
## Текущее взаимодействие — сдвиг карты (а не клик).
var _map_drag := false
## Пиксель вьюпорта планшета, куда пришёлся тап (для клика и UI).
var _press_px := Vector2(-1.0, -1.0)


func _ready() -> void:
	# Без этого Godot рендерит в 2D-окно: "No viewport was marked with use_xr".
	if XRServer.primary_interface != null:
		get_viewport().use_xr = true

	_build_environment()
	_build_xr_rig()
	_build_tablet()

	await get_tree().process_frame
	if OS.get_cmdline_user_args().has("--ui-shot"):
		await _dev_ui_shot()
		return
	if OS.get_cmdline_user_args().has("--search-test"):
		await _dev_search_test()
		return
	if OS.get_cmdline_user_args().has("--hands-shot"):
		await _dev_hands_shot()
		return
	await _boot()


# --- Построение сцены -------------------------------------------------------


func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.027, 0.04)
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)


func _build_xr_rig() -> void:
	xr_origin = XROrigin3D.new()
	xr_origin.name = "XROrigin3D"
	add_child(xr_origin)

	xr_camera = XRCamera3D.new()
	xr_camera.name = "XRCamera3D"
	xr_camera.current = true
	xr_camera.position = Vector3(0, 1.6, 0) # только для 2D-превью
	xr_origin.add_child(xr_camera)

	left_controller = XRController3D.new()
	left_controller.name = "LeftController"
	left_controller.tracker = &"left_hand"
	left_controller.pose = &"aim"
	xr_origin.add_child(left_controller)

	right_controller = XRController3D.new()
	right_controller.name = "RightController"
	right_controller.tracker = &"right_hand"
	right_controller.pose = &"aim"
	xr_origin.add_child(right_controller)

	left_ray = _add_pointer_ray(left_controller)
	right_ray = _add_pointer_ray(right_controller)


func _add_pointer_ray(controller: XRController3D) -> MeshInstance3D:
	var ray := MeshInstance3D.new()
	ray.name = "PointerRay"
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.003
	mesh.bottom_radius = 0.003
	mesh.height = POINTER_RAY_LEN
	mesh.radial_segments = 6
	ray.mesh = mesh

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.5, 0.83, 1.0, 0.55)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Поверх панорамы (она тоже прозрачная).
	mat.render_priority = 20
	ray.material_override = mat

	ray.rotation.x = -PI / 2.0
	ray.position = Vector3(0, 0, -POINTER_RAY_LEN * 0.5)
	controller.add_child(ray)
	return ray


## Строит модели контроллеров один раз, когда XR реально активен (на десктопе
## `--xr-mode off` трекеров нет, поэтому модели не создаём).
func _ensure_hands() -> void:
	if _hands_built or not _xr_active():
		return
	_hands_built = true
	_build_hand_models()


## Штатные render models рантайма (реальные анимированные модели контроллеров),
## если расширение поддерживается. Иначе — свои OBJ на трекерах в позе grip;
## луч и клики остаются на позе aim, их не трогаем.
func _build_hand_models() -> void:
	if _render_models_supported():
		_hands_native = true
		_left_render_model = _add_render_model_manager("LeftRenderModel", true)
		_add_render_model_manager("RightRenderModel", false)
		print("[hands] штатные render models рантайма")
		return
	print("[hands] расширение render models недоступно: свои OBJ-модели")
	left_grip = _add_grip_tracker(&"left_hand", "LeftGrip")
	left_model = _add_part_model(left_grip, HAND_LEFT_OBJ, "left")
	right_grip = _add_grip_tracker(&"right_hand", "RightGrip")
	right_model = _add_part_model(right_grip, HAND_RIGHT_OBJ, "right")
	if tablet != null:
		# Левый контроллер прячем, если планшет уже показан.
		_left_hands_visible(not (tablet as Node3D).visible)


func _render_models_supported() -> bool:
	if not Engine.has_singleton("OpenXRRenderModelExtension"):
		return false
	var ext: Object = Engine.get_singleton("OpenXRRenderModelExtension")
	return ext != null and ext.call("is_active")


func _add_render_model_manager(node_name: String, is_left: bool) -> OpenXRRenderModelManager:
	var mgr := OpenXRRenderModelManager.new()
	mgr.name = node_name
	mgr.tracker = (
		OpenXRRenderModelManager.RENDER_MODEL_TRACKER_LEFT_HAND
		if is_left
		else OpenXRRenderModelManager.RENDER_MODEL_TRACKER_RIGHT_HAND
	)
	xr_origin.add_child(mgr)
	return mgr


## Доп. трекер в позе grip — «где рука держит контроллер». Луч/клики висят на
## aim-трекере, поэтому эти два трекера независимы.
func _add_grip_tracker(tracker: StringName, node_name: String) -> XRController3D:
	var c := XRController3D.new()
	c.name = node_name
	c.tracker = tracker
	c.pose = &"grip"
	xr_origin.add_child(c)
	return c


func _add_hand_model(parent: Node3D, path: String) -> Node3D:
	var mesh: Mesh = load(path)
	if mesh == null:
		return null
	var mi := MeshInstance3D.new()
	mi.name = "ControllerModel"
	mi.mesh = mesh
	if OS.is_debug_build():
		print("[hands] %s AABB=%s" % [path, str(mesh.get_aabb().size)])

	var mat := StandardMaterial3D.new()
	# В сцене нет источников света: unshaded + baked-текстура ассета (светотени и
	# иконки кнопок уже впечатаны в атлас).
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = load(HAND_TEX)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.render_priority = 20
	mi.material_override = mat

	mi.scale = Vector3.ONE * HAND_MODEL_SCALE
	mi.rotation_degrees = HAND_MODEL_ROT_DEG
	mi.position = HAND_MODEL_OFFSET
	parent.add_child(mi)
	return mi


## Режет меш контроллера на отдельные «острова» (связные компоненты вершин), чтобы
## анимировать части по отдельности — курок, грип, кнопки, стик. Порядок устойчивый:
## по убыванию числа треугольников (индексы частей — HAND_PART_*).
func _split_islands(mesh: Mesh) -> Array:
	var islands: Array = []
	for s in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if idx.is_empty():
			continue
		# Ключ вершины — её позиция: при импорте OBJ вершины дублируются по UV и
		# нормалям, поэтому связность считаем по геометрии, а не по индексам.
		var key_of := PackedInt32Array()
		key_of.resize(verts.size())
		var ids: Dictionary = {}
		for i in verts.size():
			var k := Vector3i((verts[i] * 1000.0).round())
			if not ids.has(k):
				ids[k] = ids.size()
			key_of[i] = ids[k]
		var parent: Array = range(ids.size())
		var n_tris := idx.size() / 3
		for t in n_tris:
			var a: int = key_of[idx[t * 3]]
			_uf_union(parent, a, key_of[idx[t * 3 + 1]])
			_uf_union(parent, a, key_of[idx[t * 3 + 2]])
		var groups: Dictionary = {}
		for t in n_tris:
			var root: int = _uf_find(parent, key_of[idx[t * 3]])
			if not groups.has(root):
				groups[root] = []
			(groups[root] as Array).append(t)
		for key in groups.keys():
			islands.append(_build_island(arrays, idx, groups[key] as Array))
	islands.sort_custom(func(a, b): return int(a["tris"]) > int(b["tris"]))
	return islands


func _uf_find(parent: Array, x: int) -> int:
	while parent[x] != x:
		parent[x] = parent[parent[x]]
		x = parent[x]
	return x


func _uf_union(parent: Array, a: int, b: int) -> void:
	var ra: int = _uf_find(parent, a)
	var rb: int = _uf_find(parent, b)
	if ra != rb:
		parent[rb] = ra


func _build_island(arrays: Array, idx: PackedInt32Array, tris: Array) -> Dictionary:
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var remap: Dictionary = {}
	var nv := PackedVector3Array()
	var nn := PackedVector3Array()
	var nu := PackedVector2Array()
	var ni := PackedInt32Array()
	var sum := Vector3.ZERO
	for t in tris:
		for k in 3:
			var oi: int = idx[t * 3 + k]
			if not remap.has(oi):
				remap[oi] = nv.size()
				nv.append(verts[oi])
				sum += verts[oi]
				if norms.size() > oi:
					nn.append(norms[oi])
				if uvs.size() > oi:
					nu.append(uvs[oi])
			ni.append(remap[oi])
	var a: Array = []
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = nv
	if not nn.is_empty():
		a[Mesh.ARRAY_NORMAL] = nn
	if not nu.is_empty():
		a[Mesh.ARRAY_TEX_UV] = nu
	a[Mesh.ARRAY_INDEX] = ni
	var sub := ArrayMesh.new()
	sub.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
	var uv_center := Vector2.ZERO
	for uv in nu:
		uv_center += uv
	if nu.size() > 0:
		uv_center /= float(nu.size())
	var y_min := INF
	var y_max := -INF
	# Самая задняя вершина — там деталь крепится к корпусу; для курка это ось
	# вращения (кромка), иначе поворот идёт вокруг точки в воздухе.
	var hinge := Vector3.ZERO
	var hinge_z := -INF
	var top := Vector3.ZERO
	var top_y := -INF
	var n_sum := Vector3.ZERO
	for v in nv:
		y_min = minf(y_min, v.y)
		y_max = maxf(y_max, v.y)
		if v.z > hinge_z:
			hinge_z = v.z
			hinge = v
		if v.y > top_y:
			top_y = v.y
			top = v
	for n in nn:
		n_sum += n
	var bb_min := Vector3(INF, INF, INF)
	var bb_max := Vector3(-INF, -INF, -INF)
	for v in nv:
		bb_min = bb_min.min(v)
		bb_max = bb_max.max(v)
	return {
		"mesh": sub,
		"tris": tris.size(),
		"centroid": sum / float(nv.size()),
		"uv": uv_center,
		"y_min": y_min,
		"y_max": y_max,
		"hinge": hinge,
		"top": top,
		"normal": n_sum.normalized(),
		"bb_min": bb_min,
		"bb_max": bb_max,
	}


## Строит модель руки из отдельных частей (см. `_split_islands`) — так можно
## анимировать нажатия. Корень масштабируется в метры (OBJ в сантиметрах), части
## лежат в его локальных сантиметрах.
func _add_part_model(parent: Node3D, path: String, side: String) -> Node3D:
	var mesh: Mesh = load(path)
	if mesh == null:
		return null
	var root := Node3D.new()
	root.name = "ControllerModel"
	root.scale = Vector3.ONE * HAND_MODEL_SCALE
	root.rotation_degrees = HAND_MODEL_ROT_DEG
	root.position = HAND_MODEL_OFFSET
	var mat := _hand_material()
	var parts: Array = []
	for isl in _split_islands(mesh):
		var mi := MeshInstance3D.new()
		mi.mesh = isl["mesh"]
		mi.material_override = mat
		mi.set_meta("centroid", isl["centroid"])
		mi.set_meta("uv", isl["uv"])
		mi.set_meta("y_min", isl["y_min"])
		mi.set_meta("normal", isl["normal"])
		mi.set_meta("bb_max", isl["bb_max"])
		mi.set_meta("hinge", isl["hinge"])
		mi.set_meta("top", isl["top"])
		root.add_child(mi)
		parts.append(mi)
	_hand_parts[side] = parts
	parent.add_child(root)
	if OS.is_debug_build():
		print("[hands] %s: частей %d" % [side, parts.size()])
	return root


## В сцене нет источников света: unshaded + текстура ассета. Тёмный уровень атласа
## поднимает `shaders/hand.gdshader` — в атласе впёчатаны мягкие тени, которые на
## низу контроллера выглядят как грязные пятна.
func _hand_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(HAND_SHADER)
	mat.set_shader_parameter("albedo_tex", load(HAND_TEX))
	return mat


## Анимация нажатий: части модели двигаются/наклоняются по вводу контроллера.
## При штатных render models рантайм анимирует сам — не вмешиваемся.
func _update_hands() -> void:
	if _hands_native:
		return
	_animate_hand("left", left_controller)
	_animate_hand("right", right_controller)


func _animate_hand(side: String, c: XRController3D) -> void:
	if c == null:
		return
	_apply_hand_pose(
		side,
		c.get_float(&"trigger"),
		c.get_float(&"grip"),
		c.is_button_pressed(&"ax_button"),
		c.is_button_pressed(&"by_button"),
		c.is_button_pressed(&"menu_button"),
		c.get_vector2(&"primary"),
		c.is_button_pressed(&"primary_click"),
	)


## Раскладывает ввод по частям: курок поворачивается вокруг кромки, грип и кнопки
## вдавливаются вдоль своей нормали, стик наклоняется и щёлкает.
func _apply_hand_pose(
	side: String, trigger: float, grip: float, ax: bool, by: bool, menu: bool,
	stick: Vector2, stick_click: bool
) -> void:
	if not _hand_parts.has(side):
		return
	var parts: Array = _hand_parts[side]
	_tilt_trigger(parts, clampf(trigger, 0.0, 1.0))
	_press_part(parts, HAND_PART_GRIP, HAND_PRESS_GRIP * clampf(grip, 0.0, 1.0))
	_press_part(parts, HAND_PART_AX, HAND_PRESS_BUTTON if ax else 0.0)
	_press_part(parts, HAND_PART_BY, HAND_PRESS_BUTTON if by else 0.0)
	_press_part(parts, HAND_PART_MENU, HAND_PRESS_BUTTON if menu else 0.0)
	_tilt_stick(parts, stick, stick_click)


## Вдавливает часть внутрь — вдоль её собственной нормали (средней нормали
## поверхности), на `distance` сантиметров. Кнопки смотрят в разные стороны, поэтому
## одно направление на все не годится.
func _press_part(parts: Array, index: int, distance: float) -> void:
	if index < 0 or index >= parts.size():
		return
	var mi: MeshInstance3D = parts[index]
	mi.position = -(mi.get_meta("normal") as Vector3) * distance


## Курок поворачивается вокруг оси X через свою верхнюю кромку (`top` — самая верхняя
## вершина острова): верх остаётся на месте, низ уходит внутрь корпуса.
func _tilt_trigger(parts: Array, value: float) -> void:
	if HAND_PART_TRIGGER >= parts.size():
		return
	var mi: MeshInstance3D = parts[HAND_PART_TRIGGER]
	var hinge: Vector3 = mi.get_meta("top")
	var angle := -deg_to_rad(HAND_TRIGGER_TILT_DEG) * value
	var rot := Basis.from_euler(Vector3(angle, 0.0, 0.0))
	mi.transform = (
		Transform3D(Basis(), hinge)
		* Transform3D(rot, Vector3.ZERO)
		* Transform3D(Basis(), -hinge)
	)


## Наклоняет стик по вектору отклонения (поворот вокруг его основания) и вдавливает
## его при щелчке.
func _tilt_stick(parts: Array, stick: Vector2, pressed: bool) -> void:
	if HAND_PART_STICK >= parts.size():
		return
	var mi: MeshInstance3D = parts[HAND_PART_STICK]
	var center: Vector3 = mi.get_meta("centroid")
	var pivot := Vector3(center.x, float(mi.get_meta("y_min")), center.z)
	var tilt := deg_to_rad(HAND_STICK_TILT_DEG)
	# Ось Y у стика инвертирована (вперёд — это -Y в XR).
	var rot := Basis.from_euler(Vector3(-stick.y * tilt, 0.0, -stick.x * tilt))
	mi.transform = (
		Transform3D(Basis(), pivot)
		* Transform3D(rot, Vector3.ZERO)
		* Transform3D(Basis(), -pivot)
	)
	if pressed:
		mi.position -= (mi.get_meta("normal") as Vector3) * HAND_PRESS_STICK


## Укорачивает луч-указку до ближайшей поверхности, в которую он попадает —
## планшет или стрелка-шеврон, — чтобы луч не проходил сквозь них. Вне попадания —
## прежняя полная длина. Кончик чуть заходит за поверхность (`POINTER_RAY_OVERLAP`),
## чтобы визуально её касался.
func _update_ray(ray: MeshInstance3D, controller: XRController3D) -> void:
	if ray == null or not is_instance_valid(ray) or not ray.visible:
		return
	var origin := controller.global_position
	var dir := -controller.global_transform.basis.z
	var dist := POINTER_RAY_LEN
	var hit: Variant = _tablet_hit(origin, dir)
	if hit != null:
		var world_hit: Vector3 = tablet.global_transform * (hit as Vector3)
		dist = minf(dist, origin.distance_to(world_hit))
	dist = minf(dist, _chevron_hit_dist(origin, dir))
	var length := clampf(dist + POINTER_RAY_OVERLAP, 0.05, POINTER_RAY_LEN)
	var cyl := ray.mesh as CylinderMesh
	if cyl != null:
		cyl.height = length
	ray.position.z = -length * 0.5


## Дистанция по лучу до ближайшего ВИДИМОГО шеврона-перехода (или INF, если мимо).
## Шевроны — плоские горизонтальные квады у пола: пересекаем плоскость стрелки и
## проверяем границы квада, поэтому луч «касается» её поверхности. Смотрим оба вида
## (`_view` и `_incoming`), чтобы во время перехода луч не удлинялся: уходящие
## шевроны гаснут (alpha 0) и не учитываются, входящие — работают.
func _chevron_hit_dist(origin: Vector3, dir: Vector3) -> float:
	if absf(dir.y) < 1e-5:
		return INF
	var best := INF
	best = _chevrons_in(_view, origin, dir, best)
	best = _chevrons_in(_incoming, origin, dir, best)
	return best


func _chevrons_in(view: Variant, origin: Vector3, dir: Vector3, best: float) -> float:
	if view == null or not is_instance_valid(view.arrows):
		return best
	for i in view.arrows.get_child_count():
		var g := view.arrows.get_child(i) as Node3D
		if g == null or not g.visible or bool(g.get_meta("air", false)):
			continue
		var link: Dictionary = g.get_meta("link")
		if str(link.get("id", "")) == "" or not _arrow_shown(g):
			continue
		var t := (g.global_position.y - origin.y) / dir.y
		if t <= 0.0 or t >= best:
			continue
		var loc: Vector3 = g.global_transform.affine_inverse() * (origin + dir * t)
		if absf(loc.x) <= ARROW_QUAD_HALF and absf(loc.z) <= ARROW_QUAD_HALF:
			best = t
	return best


## Виден ли шеврон «на самом деле»: на переходе гаснут альфой, а не visible.
func _arrow_shown(g: Node3D) -> bool:
	var quad := g.get_child(0) as MeshInstance3D
	if quad == null:
		return false
	var m := quad.material_override as StandardMaterial3D
	return m != null and m.albedo_color.a > 0.01


func _set_status(_text: String) -> void:
	pass # плашку со статусом убрали: загрузка видна по самой панораме


func _build_tablet() -> void:
	var saved: Dictionary = State.all().get("map", {})
	var lon: float = Cfg.DEFAULT_LON
	var lat: float = Cfg.DEFAULT_LAT
	var zoom := 16.0
	if saved.has("lon") and saved.has("lat") and saved.has("zoom"):
		lon = float(saved["lon"])
		lat = float(saved["lat"])
		zoom = float(saved["zoom"])

	tablet = MapTabletScript.new()
	tablet.name = "MapTablet"
	left_controller.add_child(tablet)
	tablet.position = Vector3(0, 0.05, -0.12)
	tablet.rotation = Vector3(-0.55, 0, 0)
	tablet.scale = Vector3.ONE * 0.85
	tablet.setup(lon, lat, _set_status, zoom)
	tablet.place_selected.connect(_on_map_place_selected)
	tablet.set_overlay(bool(State.all().get("overlay_pano", false)))
	_set_tablet_visible(true)


func _on_map_place_selected(lon: float, lat: float, _is_city: bool) -> void:
	# Карта уже перецентрована самим планшетом; здесь можно было бы ещё сбросить
	# маркер «вы здесь», но он полезен как ориентир.
	if OS.is_debug_build():
		print("[search] карта к %.5f,%.5f" % [lon, lat])


func _set_tablet_visible(value: bool) -> void:
	if tablet == null:
		return
	tablet.set_active(value)
	# Луч и модель левой руки нужны только когда планшета нет.
	_left_hands_visible(not value)


## Показывает/прячет левый контроллер (нужен и луч, и модель).
func _left_hands_visible(enabled: bool) -> void:
	if left_ray != null:
		left_ray.visible = enabled
	if left_model != null:
		left_model.visible = enabled
	if _left_render_model != null:
		_left_render_model.visible = enabled


# --- Загрузка панорамы ------------------------------------------------------


func _boot() -> void:
	# Ключ необязателен: сервис панорам его не проверяет. Пустой — просто шумим в дебаге.
	if Cfg.YANDEX_API_KEY == "" and OS.is_debug_build():
		print("[cfg] YANDEX_API_KEY пуст: запросы панорам пойдут без apikey")

	var lon: float = Cfg.DEFAULT_LON
	var lat: float = Cfg.DEFAULT_LAT
	var saved: Dictionary = State.all().get("pano", {})
	if saved.has("lon") and saved.has("lat") and saved["lon"] != null and saved["lat"] != null:
		lon = float(saved["lon"])
		lat = float(saved["lat"])
		if OS.is_debug_build():
			print("[state] restore pano %.6f,%.6f" % [lon, lat])

	# Отладка: --ll=lon,lat и --air (открыть воздушную панораму в этой точке).
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--ll="):
			var p := a.substr(5).split(",")
			if p.size() == 2:
				lon = float(p[0])
				lat = float(p[1])

	if args.has("--air"):
		await _go_to_point_ll(Vector2(lon, lat), "sta")
		return

	# Восстанавливаем последнюю панораму, пробуя ОБА слоя: сохранённая точка могла
	# быть воздушной, а `stv` по ней не находится. Если совсем ничего — дефолт.
	await _go_to_layer(-1, Vector2(lon, lat))
	if _view == null:
		if OS.is_debug_build():
			print("[state] восстановить не удалось — дефолтная точка")
		await _go_to_layer(-1, Vector2(Cfg.DEFAULT_LON, Cfg.DEFAULT_LAT))
	if _view == null:
		# Совсем ничего не загрузилось (сеть/троттлинг) — показываем панораму-заглушку,
		# чтобы не сидеть в темноте и можно было открыть планшет с поиском.
		_view = PanoView.new()
		_view.build(self)
		_view.set_anchor(_pano_anchor_pos())
		_view.set_priority(0)


func _go_to_point(lon: float, lat: float) -> void:
	await _go_to_point_ll(Vector2(lon, lat), "stv")


func _go_to_layer(_layer: int, ll: Vector2) -> void:
	## Пробуем оба слоя и берём панораму, ближайшую к тапу по координатам:
	## по иконке воздушной панорамы победит воздушная (она рядом), в остальном —
	## ближайшая уличная. `_layer` (подсказка по альфе) больше не нужен.
	_load_token += 1
	var token := _load_token
	_set_status("Панорама: поиск…")
	var best: Variant = null
	var best_dist := INF
	var best_layer := ""
	for l in ["stv", "sta"]:
		var pano: Variant = await Pano.fetch_by_ll(ll.x, ll.y, l)
		if token != _load_token:
			return
		if pano == null:
			continue
		var d := _distance_m(ll, Vector2(float(pano.get("lon", NAN)), float(pano.get("lat", NAN))))
		if d < best_dist:
			best_dist = d
			best = pano
			best_layer = l
	if best == null:
		_set_status("Панорама не найдена рядом")
		if OS.is_debug_build():
			print("[tap] рядом панорамы нет: %.5f,%.5f" % [ll.x, ll.y])
		return
	if OS.is_debug_build():
		print("[tap] открываю %s (%.0f м от тапа)" % [best_layer, best_dist])
	await _apply_panorama(best, null, Vector3.ZERO, false)


func _distance_m(a: Vector2, b: Vector2) -> float:
	if not is_finite(a.x) or not is_finite(b.x):
		return INF
	var dlat := (b.y - a.y) * 111320.0
	var dlon := (b.x - a.x) * 111320.0 * cos(deg_to_rad((a.y + b.y) * 0.5))
	return sqrt(dlat * dlat + dlon * dlon)


func _go_to_point_ll(ll: Vector2, layer: String) -> void:
	_load_token += 1
	var token := _load_token
	_set_status("Панорама: поиск…")
	var pano: Variant = await Pano.fetch_by_ll(ll.x, ll.y, layer)
	if token != _load_token:
		return
	if pano == null:
		_set_status("Панорама не найдена (ключ / referer / сеть)")
		return
	if OS.is_debug_build():
		print("[pano] origin=%.2f levels=%d links=%d conns=%d" % [
			float(pano.get("yaw_origin", 0.0)), (pano.get("levels", []) as Array).size(),
			(pano.get("links", []) as Array).size(), (pano.get("connections", []) as Array).size(),
		])
	await _apply_panorama(pano, null, Vector3.ZERO, false)


func _go_to_id(id: String, yaw := 0.0) -> void:
	_load_token += 1
	var token := _load_token
	var entry: Variant = _cache.get(id, null)
	var pano: Variant
	if entry != null:
		pano = entry["pano"]
	else:
		pano = await Pano.fetch_by_id(id)
		if token != _load_token:
			return
		if pano == null:
			if OS.is_debug_build():
				print("[go] %s — не загрузилась" % id)
			return
	if OS.is_debug_build():
		print("[go] %s cache=%s conns=%d" % [
			id, str(entry != null), (pano.get("connections", []) as Array).size(),
		])
	# Наезд идёт в сторону шеврона (yaw ссылки, в системе сферы). Мир мог быть
	# развёрнут стиком — переводим направление в мировые координаты.
	var dir := Vector3(sin(yaw), 0.0, -cos(yaw))
	if _view != null and is_instance_valid(_view.root):
		dir = _view.root.global_transform.basis.orthonormalized() * dir
	await _apply_panorama(pano, entry, dir)


func _apply_panorama(
	pano: Dictionary, cached: Variant = null, move_dir := Vector3.ZERO, animate_move := true
) -> void:
	var levels: Array = _filter_levels(pano)
	if levels.is_empty():
		return

	var token := _load_token
	var plan: Dictionary = PanoStream.plan(levels, Cfg.LOD_TIERS)

	if _view == null:
		await _start_first(pano, levels, plan, token)
		return

	# Анимация наезда — только для переходов по шевронам; телепорт по карте — без.
	_transition_animate = animate_move
	# Направление наезда: к шеврону, иначе — горизонтальный forward камеры.
	var flat := Vector3(move_dir.x, 0.0, move_dir.z)
	if flat.length() < 0.001:
		flat = -xr_camera.global_transform.basis.z
		flat.y = 0.0
	_move_dir = flat.normalized()
	_move_cam = xr_camera.global_position

	# Если прошлый переход ещё не завершился — не откатываемся к прежней сфере:
	# принимаем текущую (входящую) как базу, даже если она не догрузилась.
	if _incoming != null:
		_promote_incoming()

	# Переход: наезд стартует сразу; фон входящей — из кэша либо быстрым мелким
	# уровнем (готовность не ждёт крупный фон); сектора проявляются по мере
	# загрузки поверх старой сферы (у входящей render_priority выше, глубину никто
	# не пишет).
	_cancel_transition()
	_incoming = PanoView.new()
	_incoming.build(self)
	_incoming.set_projection(
		float(pano.get("yaw_origin", 0.0)),
		float(pano.get("lat_top", PI / 2.0)), float(pano.get("lat_span", PI))
	)
	# Мир мог быть развёрнут стиком — входящая сфера наследует текущий разворот,
	# иначе при свапе панорама «прыгнет» в исходную ориентацию.
	if is_instance_valid(_view.root):
		_incoming.root.rotation = Vector3(0.0, _view.root.rotation.y, 0.0)
	_incoming.set_priority(10)     # поверх исходящего
	_incoming.set_fade(1.0)        # сектора/стрелки видны как приехали
	_incoming.set_backdrop_fade(0.0) # фон-заглушка не светится до загрузки
	# Центр панорамы — под голову (см. PanoView.anchor).
	_incoming.set_anchor(_pano_anchor_pos())
	_view.set_priority(0)          # исходящий — нижний слой (база)
	_view.hide_arrows()            # старые шевроны убираем сразу (новые — на входящей)

	_incoming.streamer = PanoStream.new()
	_incoming.set_priority(10)
	_incoming.streamer.setup(
		_incoming.root, pano, plan, token, PanoView.SPHERE_RADIUS * Cfg.PATCH_RADIUS_SCALE
	)
	_build_links(_incoming, pano)

	_incoming_ready = false
	_incoming_failed = false
	_incoming_full = false

	var backdrop: Dictionary = plan.get("backdrop", {})
	if backdrop.is_empty():
		backdrop = levels[0]
	if OS.is_debug_build():
		var ws: Array = []
		for l in levels:
			ws.append(int(l["width"]))
		print("[pano] переход: levels=%s фон=%d лоурес=%d" % [
			str(ws), int(backdrop["width"]), int(levels[0]["width"])
		])

	var low_tex: Variant = cached.get("low") if cached is Dictionary else null
	var refine: Dictionary = {}
	if low_tex != null:
		# Из кэша — сразу лоурес, переход мгновенный.
		_incoming.set_backdrop(low_tex)
		_incoming_ready = true
		if int(backdrop["width"]) > int(levels[0]["width"]):
			refine = backdrop
	else:
		# Без кэша: для готовности берём самый мелкий уровень (пара тайлов — один
		# медленный тайл не блокирует переход), затем уточняем до полного фона.
		_load_incoming_low(levels[0], token)
		if int(backdrop["width"]) > int(levels[0]["width"]):
			refine = backdrop
	if not refine.is_empty():
		_load_incoming_backdrop(refine, token)

	_save_panorama(pano)
	await _play_transition(token)
	if token != _load_token:
		return
	_set_here(pano)
	_set_status("")
	_schedule_prefetch()


## Принять текущую входящую сферу как базу, выбросив прежнюю — для повторного тапа
## во время незавершённого перехода. Не ждём догрузки: если фон ещё не приехал,
## временно берём фон прежней сферы, чтобы не было чёрного.
func _promote_incoming() -> void:
	var old: Variant = _view
	var incoming: Variant = _incoming
	_incoming = null
	if incoming == null or not is_instance_valid(incoming.root):
		return
	if not _incoming_ready and old != null and is_instance_valid(old.root):
		var t: Variant = old.material.get_shader_parameter("pano")
		if t != null:
			incoming.set_backdrop(t)
	incoming.root.scale = Vector3.ONE
	incoming.root.position = incoming.anchor
	incoming.set_backdrop_fade(1.0)
	incoming.set_fade(1.0)
	incoming.set_priority(0)
	_view = incoming
	if old != null:
		old.dispose()
	_incoming_ready = false
	_incoming_failed = false
	_incoming_full = false


func _start_first(pano: Dictionary, levels: Array, plan: Dictionary, token: int) -> void:
	_view = PanoView.new()
	_view.build(self)
	_view.set_projection(
		float(pano.get("yaw_origin", 0.0)),
		float(pano.get("lat_top", PI / 2.0)), float(pano.get("lat_span", PI))
	)
	_view.set_priority(0)
	# Центр панорамы — под голову (см. PanoView.anchor).
	_view.set_anchor(_pano_anchor_pos())

	# Первая загрузка: быстрый мелкий уровень, затем основной фон. Если фон не
	# приехал — не падаем: остаётся заглушка + сектора дотянут (без чёрного экрана).
	await _load_backdrop_into(_view, levels[0], token)
	if token != _load_token:
		return
	var backdrop: Dictionary = plan.get("backdrop", {})
	if not backdrop.is_empty() and int(backdrop["width"]) > int(levels[0]["width"]):
		await _load_backdrop_into(_view, backdrop, token)
	if token != _load_token:
		return

	_view.streamer = PanoStream.new()
	_view.set_priority(0)
	_view.streamer.setup(
		_view.root, pano, plan, token, PanoView.SPHERE_RADIUS * Cfg.PATCH_RADIUS_SCALE
	)
	_build_links(_view, pano)

	if OS.is_debug_build():
		var tier_widths: Array = []
		for t in plan.get("tiers", []):
			tier_widths.append(int(t["width"]))
		print("[pano] фон=%d px, LOD=%s, секторов=%d" % [
			int(backdrop.get("width", 0)), str(tier_widths), int(_view.streamer.total_count()),
		])

	_save_panorama(pano)
	_set_here(pano)
	_set_status("")
	_schedule_prefetch()

	await _dev_capture(levels)


func _filter_levels(pano: Dictionary) -> Array:
	var levels: Array = []
	for lvl in pano.get("levels", []):
		if float(lvl["width"]) <= Cfg.MAX_TEXTURE_WIDTH:
			levels.append(lvl)
	return levels


## Наполняет вид ссылками-переходами: уличные берут Direction из Thoroughfares,
## воздушные — соседей из Connections, направление считаем из координат.
## `_last_links` (для префетча) заполняем в обоих случаях.
func _build_links(view: Variant, pano: Dictionary) -> void:
	var links: Array = pano.get("links", [])
	var conns: Array = pano.get("connections", [])
	var plon := float(pano.get("lon", NAN))
	var plat := float(pano.get("lat", NAN))
	var palt := float(pano.get("alt", 0.0))

	if links.is_empty() and not conns.is_empty() and is_finite(plon) and is_finite(plat):
		var markers: Array = []
		var ids: Array = []
		for c in conns:
			var clon := float(c.get("lon", NAN))
			var clat := float(c.get("lat", NAN))
			if not is_finite(clon) or not is_finite(clat):
				continue
			markers.append({
				"id": str(c.get("id", "")),
				"name": str(c.get("name", "")),
				"dir": _dir_to(plon, plat, palt, clon, clat, float(c.get("alt", 0.0))),
			})
			ids.append({"id": str(c.get("id", ""))})
		view.build_markers(markers)
		_last_links = ids
	else:
		view.build_arrows(links)
		_last_links = links


## Направление на соседа по 3D-координатам (локальный фрейм сферы: север = -Z,
## восток = +X, вверх = +Y). Азимут — от севера по часовой; pitch — вверх/вниз.
## Никакой поправки на вертикальный Origin не нужно: сфера строится уже с учётом
## lat_top/lat_span, поэтому маркеры совпадают с картинкой.
func _dir_to(
	lon1: float, lat1: float, alt1: float,
	lon2: float, lat2: float, alt2: float
) -> Vector3:
	const M_PER_DEG := 111320.0
	var east := (lon2 - lon1) * M_PER_DEG * cos(deg_to_rad(lat1))
	var north := (lat2 - lat1) * M_PER_DEG
	var up := alt2 - alt1
	var yaw := atan2(east, north)
	var pitch := atan2(up, sqrt(east * east + north * north))
	return Vector3(sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))


func _load_incoming_low(level: Dictionary, token: int) -> void:
	## Дёшево: мелкий уровень целиком (пара тайлов) — чтобы входящий был готов сразу.
	var tex: ImageTexture = await Pano.build_texture(level)
	if token != _load_token or _incoming == null or _incoming_full:
		return
	if tex == null:
		return
	_incoming.set_backdrop(tex)
	_incoming_ready = true


func _load_backdrop_into(view: Variant, level: Dictionary, token: int) -> bool:
	_set_status("Панорама: фон %d px…" % int(level["width"]))
	var tex: ImageTexture = await Pano.build_texture(
		level, func(done: int, total: int) -> void: _set_status("Панорама: фон %d/%d" % [done, total])
	)
	if token != _load_token or view.root == null:
		return false
	if tex == null:
		return false
	view.set_backdrop(tex)
	return true


## Фон входящего панорамы грузится параллельно наезду (не блокирует движение).
## Если переход уже завершился, а фон приехал позже — доставляем его в текущий вид.
func _load_incoming_backdrop(level: Dictionary, token: int) -> void:
	_set_status("Панорама: фон %d px…" % int(level["width"]))
	var tex: ImageTexture = await Pano.build_texture(
		level, func(done: int, total: int) -> void: _set_status("Панорама: фон %d/%d" % [done, total])
	)
	if token != _load_token:
		return
	var target: Variant = _incoming if _incoming != null else _view
	if target == null:
		return
	if tex == null:
		# Уточнение фона — необязательное: переход уже может состояться на лоуресе.
		# Раньше здесь выставлялся _incoming_failed, и один несобранный тайл
		# откатывал весь переход назад.
		return
	target.set_backdrop(tex)
	if target == _incoming:
		_incoming_full = true
		_incoming_ready = true


## Фоновая предзагрузка лоурес-фона соседей по стрелкам (для мгновенного перехода).
func _schedule_prefetch() -> void:
	if _prefetching or _shot_enabled() or _dump_enabled():
		return
	_prefetching = true
	_prefetch_worker()


func _prefetch_worker() -> void:
	var token := _load_token
	await _wait_sec(1.5) # даём текущей панораме устояться
	for link in _last_links:
		if token != _load_token:
			break
		var id := str(link.get("id", ""))
		if id == "" or _cache.has(id):
			continue
		var pano: Variant = await Pano.fetch_by_id(id)
		if pano == null or token != _load_token:
			continue
		var levels := _filter_levels(pano)
		if levels.is_empty():
			continue
		var low: ImageTexture = await Pano.build_texture(levels[0])
		if low == null:
			continue
		if _cache.size() >= CACHE_MAX:
			_cache.erase(_cache.keys()[0])
		_cache[id] = {"pano": pano, "levels": levels, "low": low}
	_prefetching = false


# --- Центр панорамы ----------------------------------------------------------


## Центр панорамы (точка съёмки) — где голова в момент открытия. Развёртка должна
## быть вокруг глаз: reference space — STAGE (origin на полу), поэтому иначе глаз
## оказывается в 1.6 м от центра развёртки и картинка уезжает по вертикали на ~9°.
func _pano_anchor_pos() -> Vector3:
	return xr_camera.global_position


# --- Переход (сразу наезд, затем свап по готовности) -------------------------


func _play_transition(token: int) -> void:
	_transitioning = true
	var start := Time.get_ticks_msec()

	# Фаза наезда — сразу по клику, не ждём загрузку. Масштабируем ВОКРУГ камеры
	# (иначе камера «всплывает» внутри уезжающей сферы и кажется, что летишь вверх)
	# и уводим сферу назад в сторону, обратную шеврону, — читается как движение вперёд.
	# Для телепорта по карте (`_transition_animate == false`) наезда нет.
	if _transition_animate:
		while _incoming != null and token == _load_token and not _incoming_failed:
			await get_tree().process_frame
			var now := Time.get_ticks_msec()
			if now - start > 20000:
				_incoming_failed = true
				break
			var mt := _smooth(clampf(float(now - start) / 1000.0 / TRANSITION_MOVE_SEC, 0.0, 1.0))
			var s := lerpf(1.0, TRANSITION_MOVE_SCALE, mt)
			_view.root.scale = Vector3.ONE * s
			_view.root.position = _view.anchor + (1.0 - s) * (_move_cam - _view.anchor) \
					- _move_dir * (TRANSITION_MOVE_SHIFT * mt)
			if mt >= 1.0:
				break

	# Старая сфера заморожена; ждём готовности лоуреса входящей, но недолго.
	# Сектора входящей при этом уже проявляются по мере загрузки — они рисуются
	# поверх исходящей (высокий render_priority, глубина не пишется).
	var deadline := Time.get_ticks_msec() + 5000
	while _incoming != null and token == _load_token and not _incoming_failed and not _incoming_ready:
		await get_tree().process_frame
		if Time.get_ticks_msec() > deadline:
			break

	# Не дождались (медленно/не приехало) — берём фон прежней сферы, чтобы переход
	# СОСТОЯЛСЯ, а не откатился назад. Сектора и настоящий фон догрузятся позже.
	if _incoming != null and token == _load_token and not _incoming_failed and not _incoming_ready \
			and _view != null and is_instance_valid(_view.root):
		var old_tex: Variant = _view.material.get_shader_parameter("pano")
		if old_tex != null:
			_incoming.set_backdrop(old_tex)
			_incoming_ready = true

	var ok := _incoming != null and not _incoming_failed and token == _load_token and _incoming_ready
	if ok:
		# Короткий кроссфейд: исходящая гаснет, фон входящей проявляется.
		var swap_start := Time.get_ticks_msec()
		while _incoming != null and token == _load_token:
			await get_tree().process_frame
			var f := _smooth(clampf(
				float(Time.get_ticks_msec() - swap_start) / 1000.0 / TRANSITION_SWAP_FADE_SEC, 0.0, 1.0
			))
			_view.set_fade(1.0 - f)
			_incoming.set_backdrop_fade(f)
			if f >= 1.0:
				break
		ok = _incoming != null and token == _load_token

	# Переход устарел (начался новый) — не трогаем ни входящую, ни вид: этим уже
	# занимается новый переход.
	if token != _load_token:
		return

	if not ok:
		if OS.is_debug_build():
			print("[pano] откат: входящая не готова (failed=%s ready=%s)" % [
				str(_incoming_failed), str(_incoming_ready),
			])
		if _incoming != null:
			_incoming.dispose()
			_incoming = null
		if _view != null and is_instance_valid(_view.root):
			_view.root.scale = Vector3.ONE
			_view.root.position = _view.anchor
			_view.show_arrows()
			_view.set_fade(1.0)
			_view.set_priority(0)
		_transitioning = false
		return

	var old: Variant = _view
	_view = _incoming
	_incoming = null
	old.dispose()
	_view.root.scale = Vector3.ONE
	_view.root.position = _view.anchor
	_view.set_backdrop_fade(1.0)
	_view.set_fade(1.0)
	_view.set_priority(0)
	_transitioning = false


func _smooth(x: float) -> float:
	return x * x * (3.0 - 2.0 * x)


func _cancel_transition() -> void:
	if _incoming != null:
		_incoming.dispose()
		_incoming = null
	_incoming_ready = false
	_incoming_failed = false
	_incoming_full = false
	_transitioning = false
	if _view != null and is_instance_valid(_view.root):
		_view.root.scale = Vector3.ONE
		_view.root.position = _view.anchor
		_view.set_fade(1.0)
		_view.set_priority(0)


# --- Прочее -----------------------------------------------------------------


func _dev_search_test() -> void:
	var origin := Vector2(49.1157, 55.7936) # Казань — проверяем привязку к городу
	for q in ["Красная площадь", "Кремль", "Санкт-Петербург"]:
		var res: Array = await Search.suggest(q, origin, Vector2(0.5, 0.5))
		print("[search-test] %s -> %d" % [q, res.size()])
		for r in res:
			print("   %s | %s | ll=%s,%s | city=%s | coords=%s | dist=%s м" % [
				r.get("title"), r.get("subtitle"), r.get("lon"), r.get("lat"),
				r.get("is_city"), r.get("has_coords"), r.get("dist_m"),
			])
	get_tree().quit()


## Отладочный кадр планшета без загрузки панорамы: `-- --ui-shot` (опц.## `--overlay`, `--keyboard`, `--ll=lon,lat`). Требует рендера (X11/Xvfb).
func _dev_ui_shot() -> void:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--ll="):
			var p := a.substr(5).split(",")
			if p.size() == 2:
				tablet.center_on(float(p[0]), float(p[1]), tablet.zoom)
		elif a.begins_with("--mzoom="):
			tablet.center_on(tablet.center_ll.x, tablet.center_ll.y, float(a.substr(8)))
	tablet.set_overlay(args.has("--overlay"))
	if args.has("--keyboard"):
		tablet.ui.open_keyboard()
	# Направить камеру на планшет (в XR-off контроллер не трекается и планшет
	# висит у начала координат — иначе он вне кадра).
	var tpos: Vector3 = (tablet as Node3D).global_position
	var tz: Vector3 = (tablet as Node3D).global_transform.basis.z.normalized()
	xr_camera.global_position = tpos + tz * 0.7 + Vector3(0.0, 0.12, 0.0)
	xr_camera.look_at(tpos)
	# Контроль утечек узлов: счётчик должен стоять на месте (кроме коротких всплесков
	# на сетевых запросах), а не расти каждый кадр.
	for i in 300:
		await get_tree().process_frame
		if i % 60 == 0:
			print("[nodes] %d (frame %d)" % [get_tree().get_node_count(), i])
	await _capture("ui")
	get_tree().quit()


## Отладка моделей контроллеров: строим их принудительно (в XR-off трекеров нет,
## поэтому модели висят в начале координат) и снимаем с нескольких сторон.
func _dev_hands_shot() -> void:
	if tablet is Node3D:
		(tablet as Node3D).visible = false
	_build_hand_models()
	if OS.get_cmdline_user_args().has("--flat"):
		_debug_flat_material()
	if OS.get_cmdline_user_args().has("--uv-probe"):
		_debug_uv_probe()
	if OS.get_cmdline_user_args().has("--islands"):
		_debug_color_islands()
	if OS.get_cmdline_user_args().has("--press"):
		for side in ["left", "right"]:
			_apply_hand_pose(side, 1.0, 1.0, true, true, true, Vector2(0.7, 0.6), true)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--solo="):
			var solo := int(a.substr(7))
			for side in _hand_parts.keys():
				var ps: Array = _hand_parts[side]
				for i in ps.size():
					(ps[i] as MeshInstance3D).visible = i == solo and side == "left"
	# По умолчанию показываем один контроллер: в XR-off оба трекера в начале
	# координат, и левая с правой накладываются.
	if right_model != null:
		right_model.visible = OS.get_cmdline_user_args().has("--both")
	var views: Array = [
		["front", Vector3(0.0, 0.10, 0.45), Vector3.ZERO, Vector3.UP],
		["back", Vector3(0.0, 0.10, -0.45), Vector3.ZERO, Vector3.UP],
		["side", Vector3(0.45, 0.10, 0.0), Vector3.ZERO, Vector3.UP],
		["top", Vector3(0.0, 0.5, 0.02), Vector3.ZERO, Vector3.UP],
		["iso", Vector3(0.32, 0.26, 0.32), Vector3.ZERO, Vector3.UP],
		["face", Vector3(-0.006, 0.17, -0.005), Vector3(-0.006, 0.025, -0.005), Vector3(0, 0, -1)],
		["face_iso", Vector3(0.06, 0.11, -0.10), Vector3(-0.006, 0.025, -0.005), Vector3.UP],
		["bottom", Vector3(0.0, -0.35, 0.0), Vector3.ZERO, Vector3(0, 0, -1)],
		["bottom_iso", Vector3(0.26, -0.24, 0.26), Vector3.ZERO, Vector3.UP],
		["bottom_close", Vector3(-0.01, -0.16, 0.03), Vector3(-0.006, 0.0, 0.0), Vector3(0, 0, -1)],
		["solo_side", Vector3(0.13, -0.02, -0.03), Vector3(-0.006, -0.01, -0.03), Vector3.UP],
		["solo_below", Vector3(-0.006, -0.13, -0.11), Vector3(-0.006, -0.015, -0.03), Vector3(0, 0, -1)],
	]
	for v in views:
		xr_camera.global_position = v[1]
		xr_camera.look_at(v[2], v[3])
		await _capture("hands_%s" % v[0])
	get_tree().quit()


## Отладка: однотонный материал без атласа — проверить, из текстуры ли пятна.
func _debug_flat_material() -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.85, 0.85, 0.86)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.render_priority = 20
	for side in _hand_parts.keys():
		for p in _hand_parts[side]:
			(p as MeshInstance3D).material_override = mat


## Отладка: режет атлас вокруг UV-центра каждой части — по иконке на вырезке
## видно, какая это кнопка (A/B/X/Y/menu и т.п.). Вырезки — в `user://dump/uv_*.png`.
func _debug_uv_probe() -> void:
	var img := Image.load_from_file(HAND_TEX)
	if img == null:
		print("[uv] атлас не загрузился")
		return
	# Гистограмма яркости атласа — чтобы подбирать кривую/подъём тёмного.
	var hist := PackedInt32Array()
	hist.resize(16)
	var data := img.get_data()
	for i in range(0, data.size(), 4):
		hist[int(data[i]) >> 4] += 1
	var total: int = img.get_width() * img.get_height()
	var line := ""
	for b in 16:
		line += "%.2f:%d%% " % [b / 16.0, roundi(100.0 * hist[b] / total)]
	print("[hist] ", line)
	var parts: Array = _hand_parts.get("left", [])
	for i in parts.size():
		var uv: Vector2 = parts[i].get_meta("uv")
		var px := Vector2i(int(uv.x * img.get_width()), int((1.0 - uv.y) * img.get_height()))
		print("[uv] часть %2d uv=%s -> px=%s" % [i, str(uv), str(px)])
		var size := Vector2i(180, 180)
		var pos := px - size / 2
		pos.x = clampi(pos.x, 0, img.get_width() - size.x)
		pos.y = clampi(pos.y, 0, img.get_height() - size.y)
		var crop := img.get_region(Rect2i(pos, size))
		crop.resize(size.x * 2, size.y * 2, Image.INTERPOLATE_NEAREST)
		DirAccess.make_dir_recursive_absolute("user://dump")
		crop.save_png("user://dump/uv_%02d.png" % i)


## Отладка: красит каждую часть модели своим цветом и печатает легенду, чтобы
## глазами сопоставить части (курок/грип/кнопки/стик) с их индексами.
func _debug_color_islands() -> void:
	var palette := [
		Color(0.9, 0.9, 0.9), Color(1, 0, 0), Color(0, 1, 0), Color(0.2, 0.4, 1),
		Color(1, 1, 0), Color(1, 0, 1), Color(0, 1, 1), Color(1, 0.5, 0),
		Color(0.5, 0, 1), Color(0, 0.5, 0.5), Color(1, 0.4, 0.7), Color(0.35, 0.35, 0.35),
	]
	for side in _hand_parts.keys():
		var parts: Array = _hand_parts[side]
		for i in parts.size():
			var mi: MeshInstance3D = parts[i]
			var col: Color = palette[i % palette.size()]
			var mat := StandardMaterial3D.new()
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.albedo_color = col
			mat.cull_mode = BaseMaterial3D.CULL_DISABLED
			mat.render_priority = 20
			mi.material_override = mat
			if side == "left":
				print("[island] %2d цвет=%s центр=%s" % [
					i, col.to_html(false), str(mi.get_meta("centroid"))
				])


func _dev_capture(levels: Array) -> void:
	if _dump_enabled():
		var dump_level: Dictionary = levels[levels.size() - 1]
		var full_tex: ImageTexture = await Pano.build_texture(dump_level)
		if full_tex == null:
			print("[dump] фон не собрался")
			return
		var img := full_tex.get_image()
		DirAccess.make_dir_recursive_absolute("user://dump")
		var path := "user://dump/pano_%dx%d.png" % [img.get_width(), img.get_height()]
		img.save_png(path)
		print("[dump] %s" % ProjectSettings.globalize_path(path))

	if _shot_enabled():
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--yaw="):
				xr_camera.rotation.y = -deg_to_rad(float(arg.substr(6)))
			elif arg.begins_with("--pitch="):
				xr_camera.rotation.x = deg_to_rad(float(arg.substr(8)))
			elif arg.begins_with("--zoom="):
				_zoom = float(arg.substr(7))
		if _view != null and _view.streamer != null:
			await _view.streamer.wait_idle()
			if OS.get_cmdline_user_args().has("--nopatches"):
				_view.streamer.set_fade(0.0) # отладка: только фон, без секторов
		if OS.get_cmdline_user_args().has("--transition"):
			await _dev_transition()
			return
		await _capture("shot")
		get_tree().quit()
	elif _dump_enabled():
		get_tree().quit()


## Отладка перехода: по умолчанию прогреваем кэш соседей, затем снимаем кадры
## наезда. С `--no-prefetch` — без прогрева (виден путь «входящая ещё грузится»).
func _dev_transition() -> void:
	var id := ""
	var links: Array = []
	for group in _view.arrows.get_children():
		var link: Dictionary = group.get_meta("link")
		links.append(link)
		if id == "" and str(link.get("id", "")) != "":
			id = str(link["id"])
	if id == "":
		print("[dev] нет ссылок для перехода")
		get_tree().quit()
		return
	_last_links = links
	if not OS.get_cmdline_user_args().has("--no-prefetch"):
		_prefetching = false
		_prefetch_worker()
		var t0 := Time.get_ticks_msec()
		while not _cache.has(id) and Time.get_ticks_msec() - t0 < 15000:
			await get_tree().process_frame
	print("[dev] кэш соседей: %d, цель готова: %s" % [_cache.size(), _cache.has(id)])

	await _capture("t_base")
	_go_to_id(id)
	if OS.get_cmdline_user_args().has("--twice"):
		# Повторный тап во время незавершённого перехода — проверяем, что прежняя
		# сфера отбрасывается, а текущая входящая становится базой.
		await _wait_sec(0.12)
		var id2 := ""
		if _incoming != null:
			for group in _incoming.arrows.get_children():
				var link2: Dictionary = group.get_meta("link")
				if str(link2.get("id", "")) != "":
					id2 = str(link2["id"])
					break
		print("[dev] второй переход -> %s (incoming=%s)" % [id2, str(_incoming != null)])
		if id2 != "":
			_go_to_id(id2)
	for i in 40:
		await _wait_sec(0.1)
		await _capture("t%02d" % i)
	get_tree().quit()


func _capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute("user://dump")
	img.save_png("user://dump/%s.png" % name)
	print("[shot] %s" % ProjectSettings.globalize_path("user://dump/%s.png" % name))


func _wait_sec(seconds: float) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(seconds * 1000.0):
		await get_tree().process_frame


func _dump_enabled() -> bool:
	return OS.get_cmdline_user_args().has("--dump")


func _shot_enabled() -> bool:
	return OS.get_cmdline_user_args().has("--shot")


func _save_panorama(pano: Dictionary) -> void:
	var lon := float(pano.get("lon", NAN))
	var lat := float(pano.get("lat", NAN))
	if not is_finite(lon) or not is_finite(lat):
		return
	var image_id := ""
	var levels: Array = pano.get("levels", [])
	if not levels.is_empty():
		var first: Dictionary = levels[0]
		image_id = str(first.get("image_id", ""))
	State.set_value("pano", {"lon": lon, "lat": lat, "image_id": image_id})
	if OS.is_debug_build():
		print("[state] saved pano %.6f,%.6f" % [lon, lat])


func _set_here(pano: Dictionary) -> void:
	var lon := float(pano.get("lon", NAN))
	var lat := float(pano.get("lat", NAN))
	if not is_finite(lon) or not is_finite(lat):
		return
	_here_lon = lon
	_here_lat = lat
	_update_here()


func _update_here() -> void:
	if tablet == null or not tablet.visible:
		return
	if not is_finite(_here_lon) or not is_finite(_here_lat):
		return
	# Север — это -Z мира (по этой оси размещены стрелки перехода), азимут по
	# часовой стрелке: +X — восток.
	var fwd := -xr_camera.global_transform.basis.z
	# Мир можно разворачивать стиком (крутим сферу, а не камеру) — учитываем этот
	# разворот, иначе маркер направления на карте не крутится вместе с видом.
	if _view != null and is_instance_valid(_view.root):
		fwd = Basis(Vector3.UP, -_view.root.rotation.y) * fwd
	var heading := fposmod(rad_to_deg(atan2(fwd.x, -fwd.z)), 360.0)
	tablet.set_here(_here_lon, _here_lat, heading)


# --- Ввод -------------------------------------------------------------------


func _xr_active() -> bool:
	var iface := XRServer.primary_interface
	return iface != null and iface.is_initialized()


func _process(delta: float) -> void:
	_ensure_hands()
	if _hands_built:
		_update_hands()

	if _xr_active():
		_poll_controllers(delta)

	_update_ray(left_ray, left_controller)
	_update_ray(right_ray, right_controller)

	_update_here()

	if tablet != null:
		tablet.poll()

	var cam := xr_camera.global_transform
	var cam_fwd := -cam.basis.z
	if _view != null:
		_view.update_zoom(cam.origin, cam_fwd, _zoom)
	if _incoming != null:
		_incoming.update_zoom(cam.origin, cam_fwd, _zoom)

	if _view != null and _view.streamer != null:
		_view.streamer.pump(cam.origin, cam_fwd)
	if _incoming != null and _incoming.streamer != null:
		_incoming.streamer.pump(cam.origin, cam_fwd)

	var now := Time.get_ticks_msec() / 1000.0
	_pulse_arrows(_view, now)
	_pulse_arrows(_incoming, now)


## Пульсация шевронов/маркеров без создания массивов на каждый кадр.
func _pulse_arrows(view: Variant, now: float) -> void:
	if view == null or not is_instance_valid(view.arrows):
		return
	var n: int = view.arrows.get_child_count()
	for i in n:
		var g := view.arrows.get_child(i) as Node3D
		if g != null:
			g.scale = Vector3.ONE * (1.0 + 0.06 * sin(now * 2.2 + float(i)))


func _poll_controllers(delta: float) -> void:
	var trigger := (
		right_controller.is_button_pressed(&"trigger_click")
		or right_controller.get_float(&"trigger") > 0.6
	)
	var ray_origin := right_controller.global_position
	var ray_dir := -right_controller.global_transform.basis.z

	if trigger and not _trigger_down:
		_trigger_down = true
		_drag_moved = 0.0
		_drag_last = null
		_ui_press = false
		_map_drag = false
		_press_px = Vector2(-1.0, -1.0)
		var hit: Variant = _tablet_hit(ray_origin, ray_dir)
		if hit != null:
			var px: Vector2 = tablet.view_px_at_local(hit as Vector3)
			_press_px = px
			# Сначала виджеты UI (кнопки/клавиатура), иначе — сдвиг карты.
			if tablet.ui_press(px):
				_ui_press = true
			else:
				_drag_last = hit
	elif not trigger and _trigger_down:
		_trigger_down = false
		if _ui_press:
			tablet.ui_release(_press_px)
			_ui_press = false
		elif _map_drag:
			tablet.end_drag()
		elif _drag_moved < TAP_MAX_MOVE:
			_resolve_click(ray_origin, ray_dir)
		_drag_last = null
		_map_drag = false

	if trigger and _trigger_down and not _ui_press:
		var hit: Variant = _tablet_hit(ray_origin, ray_dir)
		if hit != null:
			var local: Vector3 = hit
			if _drag_last != null:
				var prev: Vector3 = _drag_last
				var d := local - prev
				var dist := Vector2(d.x, d.y).length()
				if dist > 0.0:
					_drag_moved += dist
					# Сдвиг начинаем только после заметного смещения: иначе дрожь
					# руки помечала бы тап как сдвиг и клик бы не срабатывал.
					if _map_drag or _drag_moved > TAP_MAX_MOVE:
						_map_drag = true
						tablet.preview_drag(d.x, d.y)
			_drag_last = local

	# Непрерывный зум карты правым стиком (вертикаль): отклонение = скорость.
	var stick := right_controller.get_vector2(&"primary")
	if absf(stick.y) > Cfg.MAP_ZOOM_DEADZONE:
		var curved := signf(stick.y) * pow(absf(stick.y), Cfg.MAP_STICK_CURVE)
		tablet.set_zoom(tablet.zoom + curved * Cfg.MAP_ZOOM_RATE * delta)

	# Левая рука: триггер работает как клик по стрелкам (планшет она держит,
	# поэтому в карту левым лучом не стреляем).
	var left_trigger := (
		left_controller.is_button_pressed(&"trigger_click")
		or left_controller.get_float(&"trigger") > 0.6
	)
	if left_trigger and not _left_trigger_down:
		_left_trigger_down = true
	elif not left_trigger and _left_trigger_down:
		_left_trigger_down = false
		_resolve_arrows(
			left_controller.global_position,
			-left_controller.global_transform.basis.z,
		)

	var ax := left_controller.is_button_pressed(&"ax_button")
	if ax and not _left_ax_down:
		_set_tablet_visible(not tablet.visible)
	_left_ax_down = ax

	# Левый стик: горизонталь — поворот вокруг своей оси, вертикаль — приближение.
	var lstick := left_controller.get_vector2(&"primary")
	if absf(lstick.x) > TURN_DEADZONE:
		_turn_view(lstick.x * deg_to_rad(TURN_SPEED_DEG) * delta)
	if absf(lstick.y) > TURN_DEADZONE:
		_zoom = clampf(_zoom + lstick.y * ZOOM_RATE * delta, ZOOM_MIN, ZOOM_MAX)


## Поворот вокруг своей оси: разворачиваем МИР (сферу панорамы со стрелками), а не
## XR-риг — иначе виртуальные руки/планшет уезжают от реальных. Сфера отцентрована
## на голове по горизонтали, так что вращение вокруг её оси Y = вращение вокруг тебя.
func _turn_view(angle: float) -> void:
	if is_zero_approx(angle):
		return
	for v in [_view, _incoming]:
		if v != null and is_instance_valid(v.root):
			v.root.rotate_y(angle)


func _unhandled_input(event: InputEvent) -> void:
	if _xr_active():
		return

	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		xr_camera.rotation.y -= event.relative.x * 0.0035
		xr_camera.rotation.x = clampf(
			xr_camera.rotation.x - event.relative.y * 0.0035, -1.4, 1.4
		)
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_resolve_ray(xr_camera.global_position, -xr_camera.global_transform.basis.z)
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_M:
		_set_tablet_visible(not tablet.visible)


func _tablet_hit(origin: Vector3, dir: Vector3) -> Variant:
	if tablet == null or not tablet.visible:
		return null
	var normal: Vector3 = tablet.global_transform.basis.z.normalized()
	var plane := Plane(normal, normal.dot(tablet.global_position))
	var hit: Variant = plane.intersects_ray(origin, dir)
	if hit == null:
		return null
	var local: Vector3 = tablet.global_transform.affine_inverse() * (hit as Vector3)
	var half_w := MapTabletScript.PLANE_W * 0.5
	var half_h := MapTabletScript.PLANE_H * 0.5
	if absf(local.x) > half_w or absf(local.y) > half_h:
		return null
	return local


## Клик правым триггером по планшету: сначала виджеты UI, затем карта.
func _resolve_click(origin: Vector3, dir: Vector3) -> void:
	if _transitioning or _view == null:
		return
	if _resolve_arrows(origin, dir):
		return
	if _press_px.x >= 0.0:
		_resolve_map_tap(_press_px)


## Клик по стрелкам/маркерам перехода. Возвращает true, если попал.
## Уличные шевроны — по близости (они рядом), воздушные маркеры — по углу
## (они далеко, у горизонта).
func _resolve_arrows(origin: Vector3, dir: Vector3) -> bool:
	if _transitioning or _view == null:
		return false
	var best_link: Variant = null
	var best_score := -INF
	for i in _view.arrows.get_child_count():
		var group := _view.arrows.get_child(i) as Node3D
		if group == null:
			continue
		if not group.visible:
			continue
		var link: Dictionary = group.get_meta("link")
		if str(link.get("id", "")) == "":
			continue
		var to := group.global_position - origin
		if to.dot(dir) <= 0.0:
			continue
		if bool(group.get_meta("air", false)):
			var ang := dir.angle_to(to.normalized())
			if ang <= deg_to_rad(6.0) and -ang > best_score:
				best_score = -ang
				best_link = link
		else:
			var closest := origin + dir * to.dot(dir)
			var d := closest.distance_to(group.global_position)
			if d < 0.55 and -d > best_score:
				best_score = -d
				best_link = link
	if best_link == null:
		return false
	if OS.is_debug_build():
		print("[link] -> %s" % str(best_link.get("id", "")))
	_go_to_id(str(best_link["id"]), float(best_link.get("yaw", 0.0)))
	return true


## Тап по карте: слой определяем по альфе оверлея (sta → воздух, stv → улица),
## пустое место — ближайшая уличная панорама (как раньше).
func _resolve_map_tap(px: Vector2) -> void:
	if not is_instance_valid(tablet):
		return
	# Тап по карте — тоже «клик вне клавиатуры»: закрываем её.
	tablet.close_keyboard()
	var t: Dictionary = tablet.tap_at(px)
	if OS.is_debug_build():
		var ll: Vector2 = t.get("ll", Vector2.ZERO)
		print("[tap] px=%.0f,%.0f layer=%d ll=%.5f,%.5f" % [
			px.x, px.y, int(t.get("layer", -1)), ll.x, ll.y,
		])
	_go_to_layer(int(t.get("layer", -1)), t.get("ll", Vector2.ZERO))


func _resolve_ray(origin: Vector3, dir: Vector3) -> void:
	## Общий путь для клика (в т.ч. мышью на десктопе): стрелки, затем карта.
	if _transitioning or _view == null:
		return
	if _resolve_arrows(origin, dir):
		return
	var hit: Variant = _tablet_hit(origin, dir)
	if hit != null:
		_resolve_map_tap(tablet.view_px_at_local(hit as Vector3))
