extends RefCounted
## Мини-клиент HTTP на HTTPRequest: один запрос = один временный узел.

const Cfg = preload("res://scripts/config.gd")

const TIMEOUT := 25.0


static func default_headers() -> PackedStringArray:
	# Нативному клиенту CORS не мешает, но Referer нужен для привязки ключа.
	return PackedStringArray([
		"Referer: " + Cfg.YANDEX_REFERER,
		"User-Agent: ya-maps-xr/0.2 (godot)",
	])


static func get_bytes(url: String, headers: PackedStringArray = PackedStringArray()) -> Array:
	## Возвращает [ok: bool, code: int, body: PackedByteArray].
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return [false, 0, PackedByteArray()]

	# Во время _ready корень ещё «занят настройкой детей»: add_child упадёт.
	# Один кадр ожидания — и дерево готово принимать узлы.
	await tree.process_frame

	var http := HTTPRequest.new()
	http.timeout = TIMEOUT
	http.use_threads = true
	tree.root.add_child(http)

	var err := http.request(url, headers)
	if err != OK:
		http.queue_free()
		return [false, 0, PackedByteArray()]

	var res: Array = await http.request_completed
	http.queue_free()

	var code: int = int(res[1])
	var body: PackedByteArray = res[3]
	var ok: bool = int(res[0]) == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300
	return [ok, code, body]


static func get_text(url: String, headers: PackedStringArray = PackedStringArray()) -> Array:
	## Возвращает [ok: bool, text: String].
	var r: Array = await get_bytes(url, headers)
	return [r[0], (r[2] as PackedByteArray).get_string_from_utf8()]
