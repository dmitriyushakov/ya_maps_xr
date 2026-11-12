extends RefCounted
## Состояние приложения: позиция и зум карты, последняя панорама.
## Лежит в user://state.json (на Android — внутренний каталог приложения).

const PATH := "user://state.json"

static var _data: Dictionary = {}
static var _loaded := false


static func all() -> Dictionary:
	if not _loaded:
		_loaded = true
		if FileAccess.file_exists(PATH):
			var f := FileAccess.open(PATH, FileAccess.READ)
			if f != null:
				var parsed: Variant = JSON.parse_string(f.get_as_text())
				if parsed is Dictionary:
					_data = parsed
	return _data


static func set_value(key: String, value: Variant) -> void:
	all()[key] = value
	_save()


static func _save() -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		push_warning("state: cannot write %s" % PATH)
		return
	f.store_string(JSON.stringify(_data))
