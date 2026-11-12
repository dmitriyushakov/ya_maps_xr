extends Control
## UI планшета: карта (фон), строка поиска, подсказки, встроенная клавиатура и
## тоггл оверлея. Всё — обычные Control-ноды внутри SubViewport; ввод приходит
## не синтетическими событиями, а явной диспетчеризацией (`handle_press` /
## `handle_release`), чтобы не зависеть от прокидки InputEvent в SubViewport.
##
## Стиль — ближе к Яндекс.Картам: белая верхняя панель, светлое скруглённое поле
## поиска с лупой, светлая клавиатура.

const Cfg = preload("res://scripts/config.gd")
const Search = preload("res://scripts/search.gd")

signal place_selected(lon: float, lat: float, is_city: bool)
signal overlay_toggled(enabled: bool)

const TOP_H := 76.0
const KEYBOARD_H := 360.0
const FONT_SIZE := 24
const KEY_H := 48.0

const COL_ACCENT := Color("2e6bf0")
const COL_FIELD := Color("f2f3f5")
const COL_KEY := Color("f2f3f5")
const COL_ACTION := Color("e6e8eb")
const COL_TEXT := Color("1a1a1a")
const COL_PLACEHOLDER := Color("8a8f98")

var _map_view: Control
var _map_tex: Texture2D = null
var _map_rect := Rect2()
var _marker: Control
var _search_field: Button
var _search_icon: Control
var _overlay_btn: Button
var _suggest_panel: PanelContainer
var _suggest_box: VBoxContainer
var _keyboard: PanelContainer
var _letters: GridContainer

var _pressed_btn: Button = null

var _query := ""
var _overlay_on := false
var _ru := true
var _debounce: Timer
var _search_token := 0
var _search_ll := Vector2(NAN, NAN)
var _search_span := Vector2.ZERO

var _here_visible := false
var _here_px := Vector2.ZERO
var _here_heading := 0.0

var _pending_tex: Texture2D = null


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	size = Vector2(Cfg.MAP_VIEW_W, Cfg.MAP_VIEW_H)

	# Карта в клиппующем Control'е: сдвиг/дробный зум — смещение и масштаб
	# готовой текстуры при отрисовке, UI при этом не трогается.
	_map_view = Control.new()
	_map_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_map_view.clip_contents = true
	_map_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_map_view)
	_map_view.draw.connect(_draw_map)
	if _pending_tex != null:
		_map_tex = _pending_tex

	_marker = Control.new()
	_marker.set_anchors_preset(Control.PRESET_FULL_RECT)
	_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_marker)
	_marker.draw.connect(_draw_marker)

	_build_top_bar()
	_build_suggestions()
	_build_keyboard()

	_debounce = Timer.new()
	_debounce.one_shot = true
	_debounce.wait_time = Cfg.SEARCH_DEBOUNCE_SEC
	_debounce.timeout.connect(_run_search)
	add_child(_debounce)

	_update_query_display()


# --- Верхняя панель ----------------------------------------------------------


func _build_top_bar() -> void:
	var bar := Panel.new()
	bar.position = Vector2(0, 0)
	bar.size = Vector2(Cfg.MAP_VIEW_W, TOP_H)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color.WHITE
	sb.border_color = Color("d9dbe0")
	sb.border_width_bottom = 1
	bar.add_theme_stylebox_override("panel", sb)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bar)

	_search_field = Button.new()
	_search_field.add_theme_font_size_override("font_size", FONT_SIZE)
	_search_field.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_search_field.position = Vector2(16, 14)
	_search_field.size = Vector2(Cfg.MAP_VIEW_W - 16 * 3 - 260, 48)
	_style_button(_search_field, COL_FIELD, COL_TEXT, 12, 44.0)
	_search_field.set_meta("act", _toggle_keyboard)
	add_child(_search_field)

	_search_icon = Control.new()
	_search_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_search_icon.position = Vector2(16 + 10, 14)
	_search_icon.size = Vector2(34, 48)
	_search_icon.draw.connect(_draw_magnifier)
	add_child(_search_icon)

	_overlay_btn = Button.new()
	_overlay_btn.add_theme_font_size_override("font_size", FONT_SIZE)
	_overlay_btn.position = Vector2(Cfg.MAP_VIEW_W - 16 - 244, 14)
	_overlay_btn.size = Vector2(244, 48)
	_overlay_btn.set_meta("act", _on_overlay)
	add_child(_overlay_btn)
	_update_overlay_btn()


func _draw_magnifier() -> void:
	var c := Vector2(12, 24)
	_search_icon.draw_arc(c, 8.0, 0.0, TAU, 24, COL_PLACEHOLDER, 2.5)
	_search_icon.draw_line(c + Vector2(6, 6), c + Vector2(12, 12), COL_PLACEHOLDER, 2.5)


func _build_suggestions() -> void:
	_suggest_panel = PanelContainer.new()
	_suggest_panel.position = Vector2(16, TOP_H + 6)
	_suggest_panel.custom_minimum_size = Vector2(760, 0)
	_suggest_panel.visible = false
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color.WHITE
	sb.set_corner_radius_all(12)
	sb.set_content_margin_all(6)
	sb.shadow_color = Color(0, 0, 0, 0.18)
	sb.shadow_size = 8
	_suggest_panel.add_theme_stylebox_override("panel", sb)
	add_child(_suggest_panel)

	_suggest_box = VBoxContainer.new()
	_suggest_box.add_theme_constant_override("separation", 2)
	_suggest_panel.add_child(_suggest_box)


# --- Клавиатура --------------------------------------------------------------


func _build_keyboard() -> void:
	_keyboard = PanelContainer.new()
	_keyboard.position = Vector2(0, Cfg.MAP_VIEW_H - KEYBOARD_H)
	_keyboard.size = Vector2(Cfg.MAP_VIEW_W, KEYBOARD_H)
	_keyboard.visible = false
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color.WHITE
	sb.border_color = Color("d9dbe0")
	sb.border_width_top = 1
	sb.set_content_margin_all(10)
	_keyboard.add_theme_stylebox_override("panel", sb)
	add_child(_keyboard)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	_keyboard.add_child(vbox)

	var digits := HBoxContainer.new()
	digits.add_theme_constant_override("separation", 6)
	vbox.add_child(digits)
	for i in 10:
		var d := str((i + 1) % 10)
		digits.add_child(_mk_button(d, _on_char.bind(d), "action"))
	digits.add_child(_mk_button("⌫", _on_backspace, "action"))
	digits.add_child(_mk_button("RU/EN", _on_lang, "action"))

	_letters = GridContainer.new()
	_letters.columns = 12
	_letters.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_letters.add_theme_constant_override("h_separation", 6)
	_letters.add_theme_constant_override("v_separation", 8)
	vbox.add_child(_letters)
	_fill_letters()

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 6)
	vbox.add_child(bottom)
	bottom.add_child(_mk_button("Пробел", _on_char.bind(" "), "action"))
	bottom.add_child(_mk_button("Найти", _on_search, "action"))
	bottom.add_child(_mk_button("Скрыть", _toggle_keyboard, "action"))


func _fill_letters() -> void:
	for c in _letters.get_children():
		c.queue_free()
	var rows: Array = (
		["йцукенгшщзхъ", "фывапролджэ", "ячсмитьбю"]
		if _ru
		else ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
	)
	for row in rows:
		var s: String = row
		for i in s.length():
			_letters.add_child(_mk_button(s[i], _on_char.bind(s[i]), "key"))
		for i in range(s.length(), 12):
			var pad := Control.new()
			pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			pad.custom_minimum_size = Vector2(0, KEY_H)
			_letters.add_child(pad)


func _mk_button(text: String, act: Callable, kind := "key") -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", FONT_SIZE)
	b.custom_minimum_size = Vector2(0, KEY_H)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.set_meta("act", act)
	if kind == "action":
		_style_button(b, COL_ACTION, COL_TEXT, 10, 0.0)
	else:
		_style_button(b, COL_KEY, COL_TEXT, 10, 0.0)
	return b


func _style_button(b: Button, bg: Color, fg: Color, radius: float, left_pad: float) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(int(radius))
	sb.content_margin_left = left_pad if left_pad > 0.0 else 12.0
	sb.content_margin_right = 12.0
	sb.content_margin_top = 4.0
	sb.content_margin_bottom = 4.0
	b.add_theme_stylebox_override("normal", sb)
	var hover := sb.duplicate() as StyleBoxFlat
	hover.bg_color = bg.lerp(Color.BLACK, 0.06)
	b.add_theme_stylebox_override("hover", hover)
	var pressed := sb.duplicate() as StyleBoxFlat
	pressed.bg_color = bg.lerp(Color.BLACK, 0.12)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_color_override("font_color", fg)
	b.add_theme_color_override("font_hover_color", fg)
	b.add_theme_color_override("font_pressed_color", fg)


# --- Диспетчеризация ввода ---------------------------------------------------


func interactive_at(px: Vector2) -> bool:
	return _button_at(px) != null


func handle_press(px: Vector2) -> bool:
	_pressed_btn = _button_at(px)
	return _pressed_btn != null


func handle_release(px: Vector2) -> void:
	var b := _pressed_btn
	_pressed_btn = null
	if b == null or not b.is_visible_in_tree():
		return
	if not b.get_global_rect().has_point(px):
		return
	# Тап вне клавиатуры (кроме самого поля поиска) закрывает клавиатуру.
	if _keyboard.visible and b != _search_field and not _keyboard.is_ancestor_of(b):
		_keyboard.visible = false
	var act: Variant = b.get_meta("act", Callable())
	if act is Callable and (act as Callable).is_valid():
		(act as Callable).call()


func _button_at(px: Vector2) -> Button:
	var found: Array = find_children("*", "Button", true, false)
	# Позже добавленные рисуются выше — ищем с конца.
	for i in range(found.size() - 1, -1, -1):
		var b := found[i] as Button
		if b != null and b.is_visible_in_tree() and b.get_global_rect().has_point(px):
			return b
	return null


# --- Обработчики -------------------------------------------------------------


func _on_char(ch: String) -> void:
	_query += ch
	_update_query_display()
	_debounce.start()


func _on_backspace() -> void:
	if _query.length() > 0:
		_query = _query.substr(0, _query.length() - 1)
	_update_query_display()
	_debounce.start()


func _on_lang() -> void:
	_ru = not _ru
	_fill_letters()


func _on_search() -> void:
	_debounce.stop()
	_run_search()


func _toggle_keyboard() -> void:
	_keyboard.visible = not _keyboard.visible
	if _keyboard.visible:
		_clear_suggestions()


func _on_overlay() -> void:
	_overlay_on = not _overlay_on
	_update_overlay_btn()
	overlay_toggled.emit(_overlay_on)


func _on_pick(item: Dictionary) -> void:
	var lon := float(item.get("lon", NAN))
	var lat := float(item.get("lat", NAN))
	if not is_finite(lon) or not is_finite(lat):
		return
	_query = str(item.get("title", ""))
	_update_query_display()
	_clear_suggestions()
	_keyboard.visible = false
	place_selected.emit(lon, lat, bool(item.get("is_city", false)))


# --- Поиск -------------------------------------------------------------------


func _run_search() -> void:
	var q := _query.strip_edges()
	if q == "":
		_clear_suggestions()
		return
	_search_token += 1
	var token := _search_token
	var res: Array = await Search.suggest(q, _search_ll, _search_span)
	if token != _search_token:
		return
	_show_suggestions(res)


func _show_suggestions(items: Array) -> void:
	for c in _suggest_box.get_children():
		c.queue_free()
	var shown := 0
	for item in items:
		if not bool((item as Dictionary).get("has_coords", false)):
			continue
		var b := Button.new()
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.add_theme_font_size_override("font_size", 22)
		b.custom_minimum_size = Vector2(700, 46)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var sub := str((item as Dictionary).get("subtitle", ""))
		var dist := float((item as Dictionary).get("dist_m", NAN))
		b.text = str((item as Dictionary).get("title", ""))
		if sub != "":
			b.text += "  ·  " + sub
		_style_button(b, Color(1, 1, 1, 0), COL_TEXT, 8, 10.0)
		b.set_meta("act", _on_pick.bind(item))
		_suggest_box.add_child(b)
		shown += 1
		if shown >= 8:
			break
	_suggest_panel.visible = shown > 0


func _clear_suggestions() -> void:
	for c in _suggest_box.get_children():
		c.queue_free()
	_suggest_panel.visible = false


# --- Внешнее состояние -------------------------------------------------------


func set_map_texture(tex: Texture2D) -> void:
	if _map_view == null:
		_pending_tex = tex
		return
	_map_tex = tex
	_map_view.queue_redraw()


func set_map_draw(tex: Texture2D, rect: Rect2) -> void:
	if _map_view == null:
		_pending_tex = tex
		_map_rect = rect
		return
	_map_tex = tex
	_map_rect = rect
	_map_view.queue_redraw()


func _draw_map() -> void:
	if _map_tex != null:
		_map_view.draw_texture_rect(_map_tex, _map_rect, false)


func set_overlay_state(enabled: bool) -> void:
	_overlay_on = enabled
	_update_overlay_btn()


## Точка для смещения поиска: центр карты и её охват в градусах (для suggest).
func set_search_origin(ll: Vector2, span: Vector2) -> void:
	_search_ll = ll
	_search_span = span


func close_keyboard() -> void:
	if _keyboard != null:
		_keyboard.visible = false


func open_keyboard() -> void:
	if _keyboard != null:
		_keyboard.visible = true
		_clear_suggestions()


func set_here(visible: bool, px: Vector2, heading_deg: float) -> void:
	if visible == _here_visible and px == _here_px and is_equal_approx(heading_deg, _here_heading):
		return
	_here_visible = visible
	_here_px = px
	_here_heading = heading_deg
	if _marker != null:
		_marker.queue_redraw()


func _update_query_display() -> void:
	if _search_field == null:
		return
	if _query != "":
		_search_field.text = _query
		_search_field.add_theme_color_override("font_color", COL_TEXT)
	else:
		_search_field.text = "Поиск мест и адресов"
		_search_field.add_theme_color_override("font_color", COL_PLACEHOLDER)


func _update_overlay_btn() -> void:
	if _overlay_btn == null:
		return
	if _overlay_on:
		_overlay_btn.text = "Панорамы: вкл"
		_style_button(_overlay_btn, COL_ACCENT, Color.WHITE, 12, 0.0)
	else:
		_overlay_btn.text = "Панорамы"
		_style_button(_overlay_btn, COL_FIELD, COL_TEXT, 12, 0.0)


# --- Маркер «вы здесь» -------------------------------------------------------


func _draw_marker() -> void:
	if not _here_visible:
		return
	var c := _here_px
	# Экран: север — вверх (0,-1), восток — вправо (1,0); азимут по часовой.
	var dir := Vector2(sin(deg_to_rad(_here_heading)), -cos(deg_to_rad(_here_heading)))
	var perp := Vector2(-dir.y, dir.x) * 15.0
	_marker.draw_colored_polygon(
		PackedVector2Array([c + perp, c - perp, c + dir * 48.0]),
		Color(0.15, 0.62, 1.0, 0.5),
	)
	_marker.draw_circle(c, 9.0, Color(1.0, 0.86, 0.25, 1.0))
	_marker.draw_arc(c, 9.0, 0.0, TAU, 24, Color(1, 1, 1, 0.9), 2.0)
