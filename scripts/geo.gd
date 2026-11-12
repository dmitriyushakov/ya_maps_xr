extends RefCounted
## Проекция Меркатора: lon/lat <-> мировые пиксели на заданном зуме.
##
## Две проекции:
## - сферический Меркатор (`lon_lat_to_world_px`, как OSM/Leaflet) — оставлен для
##   отладки/совместимости;
## - EPSG:3395 (эллипсоидальный Меркатор WGS84, `yandex_world_px`) — в этой сетке
##   считаются тайлы Яндекса (карта `core-renderer-tiles` и слой панорам
##   `core-stv-renderer`). Разница по y достигает ~0.0009 нормированного, что на
##   z17 — десятки тайлов, поэтому индексы тайлов и смещения считаем ТОЛЬКО по EPSG.
##   Внутри одного окна планшета разница масштабов двух проекций субпиксельная.

const WORLD_TILE := 256.0
const MAX_LAT := 85.05112878

## Параметры эллипсоида WGS84 для EPSG:3395.
const ELL_A := 6378137.0
const ELL_E := 0.0818191908426  # sqrt(1 - (b/a)^2)


static func clamp_lat(lat: float) -> float:
	return clampf(lat, -MAX_LAT, MAX_LAT)


static func world_scale(zoom: int) -> float:
	return WORLD_TILE * pow(2.0, float(zoom))


static func lon_lat_to_world_px(lon: float, lat: float, zoom: int) -> Vector2:
	var scale := world_scale(zoom)
	var sin_lat := sin(deg_to_rad(clamp_lat(lat)))
	return Vector2(
		(lon + 180.0) / 360.0 * scale,
		(0.5 - log((1.0 + sin_lat) / (1.0 - sin_lat)) / (4.0 * PI)) * scale,
	)


static func world_px_to_lon_lat(p: Vector2, zoom: int) -> Vector2:
	var scale := world_scale(zoom)
	var n := PI - (2.0 * PI * p.y) / scale
	return Vector2(
		p.x / scale * 360.0 - 180.0,
		rad_to_deg(atan(sinh(n))),
	)


## --- EPSG:3395 (эллипсоидальный Меркатор) -----------------------------------


## Мировые пиксели в проекции EPSG:3395. `zoom` дробный: целые значения дают
## целые размеры мира (как у тайлов), дробные удобны для непрерывного зума.
static func yandex_world_px(lon: float, lat: float, zoom: float) -> Vector2:
	var ph := deg_to_rad(clamp_lat(lat))
	var s := world_scale_f(zoom)
	var ym := ELL_A * log(
		tan(PI / 4.0 + ph / 2.0)
		* pow((1.0 - ELL_E * sin(ph)) / (1.0 + ELL_E * sin(ph)), ELL_E / 2.0)
	)
	return Vector2((lon + 180.0) / 360.0 * s, (1.0 - ym / (ELL_A * PI)) / 2.0 * s)


## Обратная к `yandex_world_px`. Обратный Меркатор для эллипсоида решаем
## итерациями Ньютона (6 шагов даёт субпиксельную точность).
static func yandex_world_px_to_lon_lat(p: Vector2, zoom: float) -> Vector2:
	var s := world_scale_f(zoom)
	var lon := p.x / s * 360.0 - 180.0
	var ym := (1.0 - 2.0 * p.y / s) * ELL_A * PI
	var ph := PI / 2.0 - 2.0 * atan(exp(-ym / ELL_A))
	for i in 6:
		var sp := sin(ph)
		var cp := cos(ph)
		var t := tan(PI / 4.0 + ph / 2.0)
		var k := (1.0 - ELL_E * sp) / (1.0 + ELL_E * sp)
		var f := ELL_A * log(t * pow(k, ELL_E / 2.0)) - ym
		# d/dphi: A/cos(phi) - A*e^2*cos(phi)/(1 - e^2*sin^2(phi)).
		var df := ELL_A / cp - ELL_A * ELL_E * ELL_E * cp / (1.0 - ELL_E * ELL_E * sp * sp)
		if absf(df) < 1e-12:
			break
		ph -= f / df
	return Vector2(lon, rad_to_deg(ph))


static func world_scale_f(zoom: float) -> float:
	return WORLD_TILE * pow(2.0, zoom)
