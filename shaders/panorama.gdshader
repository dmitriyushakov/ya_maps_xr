shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

// Equirect-панорама на сфере, видимая изнутри.
// u = (азимут - Origin) / 360, v = 0 сверху. Вертикаль задаётся парой
// lat_top/lat_span: широта верхнего края и вертикальный охват (2π·H/W). Полный шар
// (lat_top = π/2, lat_span = π) — только при H/W = 0.5; у «частичных» панорам
// направление вне [lat_top - lat_span, lat_top] не покрыто и остаётся прозрачным.
//
// Важно: u считается через atan2, у которого разрыв на шве (azimuth ±180°).
// Если отдать его в texture() с неявными производными, GPU на шве выбирает
// самый грубый mip — получается видимая полоса от полюса до полюса.
// Поэтому считаем градиенты UV аналитически и зовём textureGrad.
uniform sampler2D pano : source_color, filter_linear_mipmap, repeat_enable;
uniform float yaw_origin_deg = 0.0;
uniform float yaw_fix_deg = 0.0;
// Вертикальная геометрия развёртки (радианы): широта верхнего края и охват.
// lat_span = 2π·H/W уровня; по умолчанию — полный шар (π).
uniform float lat_top = 1.5707963;
uniform float lat_span = 3.1415927;
// Прозрачность сферы: 1.0 — обычный вид, <1 — гасим при кроссфейде перехода.
// Сферы не пишут глубину (render_mode depth_draw_never), поэтому порядок
// прозрачных слоёв задаёт render_priority: входящая панорама (выше) ложится
// поверх исходящей, даже когда исходящая ближе по глубине (наезд).
uniform float fade = 1.0;
// Приближение = сужение поля зрения: фрагмент под углом θ от направления взгляда
// смотрит на контент под углом θ/zoom (поворот к взгляду по большой окружности).
// zoom = 1 — без приближения.
//
// Почему не магнификация equirect-координат (как было раньше): у полюса чарт
// вырожден, и такая магнификация «засасывает» полярную шапку в точку (её ряды
// вообще перестают сэмплиться), а по долготе даёт разрыв-шов. Угловой поворот
// полюса не выделяет: это обычные направления, контент везде виден, швов нет.
uniform float zoom = 1.0;
uniform vec2 zoom_uv = vec2(0.0, 0.5);
// Шарпен на приближении: 3× зум — это цифровое растяжение уровня 7168 px, без
// подтягивания высоких частот картинка выглядит мыленной. amt = 0 — выключено.
uniform float sharpen = 0.0;

varying vec3 local_pos;

const float PI_F = 3.141592653589793;
const float TAU_F = 6.283185307179586;


// Направление по глобальным equirect-координатам (согласовано с pano_patch и
// pano_stream._dir_from_uv).
vec3 dir_from_uv(vec2 uv, float yaw) {
	float az = uv.x * TAU_F + yaw;
	float lat = lat_top - uv.y * lat_span;
	float cl = cos(lat);
	return vec3(sin(az) * cl, sin(lat), -cos(az) * cl);
}


// Поворот d к точке взгляда g по большой окружности так, что угол θ переходит в
// θ * scale (scale = 1/zoom — притянуть, scale = zoom — оттолкнуть).
vec3 rotate_about(vec3 d, vec3 g, float scale) {
	float ct = clamp(dot(d, g), -1.0, 1.0);
	vec3 t = d - g * ct;
	float tl = length(t);
	if (tl < 1e-6) {
		return d;
	}
	float th = acos(ct) * scale;
	return normalize(g * cos(th) + (t / tl) * sin(th));
}


void vertex() {
	local_pos = VERTEX;
}


void fragment() {
	vec3 d = normalize(local_pos);
	float yaw = (yaw_origin_deg + yaw_fix_deg) * PI_F / 180.0;

	vec3 dx = dFdx(d);
	vec3 dy = dFdy(d);

	// az = atan2(x, -z): daz = ((-z)*dx + x*dz) / (x^2 + z^2)
	float denom = max(d.x * d.x + d.z * d.z, 1e-6);
	float daz_dx = (-d.z * dx.x + d.x * dx.z) / denom;
	float daz_dy = (-d.z * dy.x + d.x * dy.z) / denom;

	// v = (lat_top - asin(y)) / lat_span: dv = -dy / (lat_span * sqrt(1 - y^2))
	float sy = sqrt(max(1.0 - d.y * d.y, 1e-6));
	float dv_dx = -dx.y / (lat_span * sy);
	float dv_dy = -dy.y / (lat_span * sy);

	// Приближение: смотрим не в d, а в повёрнутое к взгляду направление.
	vec3 g = dir_from_uv(zoom_uv, yaw);
	vec3 c = rotate_about(d, g, 1.0 / zoom);
	float az = atan(c.x, -c.z);
	float u = (az - yaw) / TAU_F;
	// Широта сэмпла → вертикальная координата развёртки.
	float v = (lat_top - asin(clamp(c.y, -1.0, 1.0))) / lat_span;

	// Градиенты UV: берём аналитические от d и делим на zoom — для выбора мипа
	// этого достаточно (локальный масштаб поворота ≈ 1/zoom).
	vec2 gx = vec2(daz_dx / TAU_F / zoom, dv_dx / zoom);
	vec2 gy = vec2(daz_dy / TAU_F / zoom, dv_dy / zoom);
	// v за пределами [0,1] — направление вне снятой области: не заворачиваем repeat'ом.
	vec2 suv = vec2(u, clamp(v, 0.0, 1.0));
	vec3 col = textureGrad(pano, suv, gx, gy).rgb;
	if (sharpen > 0.001) {
		// Размытая версия — тот же сэмпл с вчетверо большими градиентами
		// (на два мипа грубее); высокие частоты возвращаем в ALBEDO.
		vec3 blur = textureGrad(pano, suv, gx * 4.0, gy * 4.0).rgb;
		col += (col - blur) * sharpen;
	}
	ALBEDO = col;

	// Непокрытая область (низ/верх «частичной» развёртки) прозрачна — виден тёмный
	// фон сцены, как в плеере Яндекса, вместо растягивания до полюса.
	float inside = step(0.0, v) * step(v, 1.0);
	ALPHA = fade * inside;
}
