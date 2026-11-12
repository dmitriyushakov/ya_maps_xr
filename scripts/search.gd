extends RefCounted
## Поиск географических мест без ключа: подсказки `suggest-maps.yandex.ru` +
## разбор координат из поля `uri`.
##
## Ответ приходит как JSONP: `suggest.apply({...})`. Внутри каждого результата
## есть `uri` вида `ymapsbm1://geo?data=<base64 protobuf>`; в protobuf-сообщении
## лежат координаты как fixed32 (float32) — их и вытаскиваем. Это неофициальная
## ручка веб-клиента (как и слой панорам), поэтому разбор мягкий: не нашли
## координаты — результат показываем, но он не кликабелен.

const Cfg = preload("res://scripts/config.gd")
const Net = preload("res://scripts/net.gd")


## Возвращает список {title, subtitle, lon, lat, is_city, has_coords, dist_m}.
## `ll`/`span` — центр и охват карты: suggest ранжирует по близости, а мы ещё
## сортируем результат по расстоянию, чтобы сначала шли объекты текущего города.
static func suggest(part: String, ll := Vector2(NAN, NAN), span := Vector2.ZERO) -> Array:
	var q := part.strip_edges()
	if q == "":
		return []
	var url := "%s?part=%s&v=9&lang=ru&n=8&search_type=all" % [Cfg.SUGGEST_URL, q.uri_encode()]
	if is_finite(ll.x) and is_finite(ll.y):
		url += "&ll=%.6f,%.6f" % [ll.x, ll.y]
		if span.x > 0.0 and span.y > 0.0:
			url += "&spn=%.6f,%.6f" % [span.x, span.y]
	var r: Array = await Net.get_text(url, Net.default_headers())
	if not r[0]:
		return []
	var payload: Variant = _parse_jsonp(r[1])
	if not (payload is Dictionary):
		return []
	var out: Array = []
	for item in (payload.get("results", []) if payload is Dictionary else []):
		if not (item is Dictionary):
			continue
		var it: Dictionary = item
		var title := _text(it.get("title"))
		if title == "":
			continue
		var uri := str(it.get("uri", ""))
		var coords := _coords_from_uri(uri)
		var tags: Array = it.get("tags", []) if it.get("tags") is Array else []
		out.append({
			"title": title,
			"subtitle": _text(it.get("subtitle")),
			"lon": coords.x,
			"lat": coords.y,
			"has_coords": is_finite(coords.x) and is_finite(coords.y),
			"is_city": tags.has("locality"),
			"dist_m": _distance_of(it),
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("dist_m", INF)) < float(b.get("dist_m", INF))
	)
	return out


static func _distance_of(it: Dictionary) -> float:
	var dv: Variant = it.get("distance")
	if dv is Dictionary:
		var v: Variant = (dv as Dictionary).get("value")
		if v is float or v is int:
			return float(v)
	return INF


static func _text(v: Variant) -> String:
	if v is Dictionary:
		return str((v as Dictionary).get("text", ""))
	return ""


## JSONP-обёртка: `suggest.apply({...})` (иногда с `;` на конце).
static func _parse_jsonp(body: String) -> Variant:
	var start := body.find("(")
	var end := body.rfind(")")
	if start < 0 or end <= start:
		return null
	return JSON.parse_string(body.substr(start + 1, end - start - 1))


# --- Координаты из ymapsbm1-uri ---------------------------------------------


static func _coords_from_uri(uri: String) -> Vector2:
	var key := "data="
	var idx := uri.find(key)
	if idx < 0:
		return Vector2(NAN, NAN)
	# Поле `uri` приходит как base64url, иногда с мусорными символами по краям и
	# без паддинга — вычищаем и добиваем до кратности 4, иначе декодер вернёт пусто.
	var clean := ""
	for ch in uri.substr(idx + key.length()):
		if (ch >= "A" and ch <= "Z") or (ch >= "a" and ch <= "z") \
				or (ch >= "0" and ch <= "9") or ch == "+" or ch == "/" \
				or ch == "-" or ch == "_":
			clean += ch
	clean = clean.replace("-", "+").replace("_", "/")
	while clean.length() % 4 != 0:
		clean += "="
	var raw := Marshalls.base64_to_raw(clean)
	if raw.is_empty():
		return Vector2(NAN, NAN)
	return _find_ll(raw)


## Обходит protobuf верхнего уровня, ищет вложенное сообщение с парой fixed32
## (долгота/широта). Гео-месседж Яндекса короткий и состоит ровно из двух
## fixed32-полей (1=lon, 2=lat) — по этой строгости отсекаем ложные срабатывания
## на строках/случайных байтах.
static func _find_ll(raw: PackedByteArray) -> Vector2:
	var i := 0
	while i < raw.size():
		var tag_r := _varint(raw, i)
		var tag: int = tag_r[0]
		i = int(tag_r[1])
		var field := tag >> 3
		var wt := tag & 7
		if wt == 0:
			i = int(_varint(raw, i)[1])
		elif wt == 1:
			i += 8
		elif wt == 5:
			i += 4
		elif wt == 2:
			var ln: int = int(_varint(raw, i)[0])
			i = int(_varint(raw, i)[1])
			if i + ln > raw.size():
				break
			var sub := raw.slice(i, i + ln)
			i += ln
			var ll := _ll_from_msg(sub)
			if is_finite(ll.x) and is_finite(ll.y):
				return ll
		else:
			break
	return Vector2(NAN, NAN)


static func _ll_from_msg(raw: PackedByteArray) -> Vector2:
	if raw.size() > 24:
		return Vector2(NAN, NAN)
	var lon := NAN
	var lat := NAN
	var fields := 0
	var i := 0
	while i < raw.size():
		var tag_r := _varint(raw, i)
		var tag: int = tag_r[0]
		i = int(tag_r[1])
		var field := tag >> 3
		var wt := tag & 7
		if wt != 5:
			return Vector2(NAN, NAN) # в гео-месседже все поля fixed32
		if i + 4 > raw.size():
			return Vector2(NAN, NAN)
		var v := raw.decode_float(i)
		i += 4
		fields += 1
		if field == 1:
			lon = v
		elif field == 2:
			lat = v
	if fields < 2:
		return Vector2(NAN, NAN)
	if absf(lon) > 180.0 or absf(lat) > 90.0:
		return Vector2(NAN, NAN)
	return Vector2(lon, lat)


## Читает varint, возвращает [value, next_index].
static func _varint(raw: PackedByteArray, i: int) -> Array:
	var result := 0
	var shift := 0
	while i < raw.size():
		var b := raw[i]
		result |= (b & 0x7F) << shift
		i += 1
		if (b & 0x80) == 0:
			break
		shift += 7
		if shift > 63:
			break
	return [result, i]
