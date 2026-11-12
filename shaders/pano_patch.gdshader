shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

// Патч-сектор панорамы. UV меша — глобальные equirect-координаты (u,v) в [0,1],
// а текстура содержит только диапазон тайлов этого сектора. Пересчёт в координаты
// текстуры — в пикселях уровня, чтобы не зависеть от размера/тайла уровня.
//
// pano_px  — размер уровня в пикселях (width, height);
// tile_px  — левый-верхний пиксель текстуры в координатах уровня (x0*tw, y0*th);
// tex_px   — размер самой текстуры в пикселях ((x1-x0)*tw, (y1-y0)*th).

uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_disable;
uniform vec2 pano_px = vec2(1.0, 1.0);
uniform vec2 tile_px = vec2(0.0, 0.0);
uniform vec2 tex_px = vec2(1.0, 1.0);
// Прозрачность сектора: 1.0 — обычный вид, <1 — гасим при кроссфейде перехода.
// Как и сфера, сектора не пишут глубину (depth_draw_never): порядок прозрачных
// слоёв задаёт render_priority, поэтому сектора входящей панорамы появляются
// поверх исходящей по мере загрузки.
uniform float fade = 1.0;
// Приближение: то же, что в panorama.gdshader, но выполняется ГЕОМЕТРИЕЙ. Контент
// вершины (её UV) уезжает от точки взгляда по большой окружности в zoom раз — то
// же место, куда его ставит фон своей угловой магнификацией. Поэтому сектор под
// взглядом растягивается на весь экран, соседние уходят за край, а сэмплим мы
// всегда свою же текстуру (UV меша — координаты контента): фон в кадре не
// проступает, полюс ничего не затягивает, швов по долготе нет.
uniform float zoom = 1.0;
uniform vec2 zoom_uv = vec2(0.0, 0.5);
// Шарпен на приближении (см. panorama.gdshader).
uniform float sharpen = 0.0;
// Геометрия сектора: те же значения, что при построении меша (pano_stream):
// радиус сферы и добавка к азимуту (Origin + YAW_FIX).
uniform float radius = 10.0;
uniform float yaw_rad = 0.0;
// Вертикальная геометрия развёртки (радианы): широта верхнего края и охват
// (2π·H/W). Та же пара, что в panorama.gdshader — сектора ложатся на фон без сдвига.
uniform float lat_top_rad = 1.5707963;
uniform float lat_span_rad = 3.1415927;

const float TAU_F = 6.283185307179586;


// Та же функция, что pano_stream._dir_from_uv: точка сферы по глобальным
// equirect-координатам (u — долгота, v — полярный угол, v = 0 сверху).
vec3 dir_from_uv(vec2 uv, float yaw, float r) {
	float az = uv.x * TAU_F + yaw;
	float lat = lat_top_rad - uv.y * lat_span_rad;
	float cl = cos(lat);
	return vec3(sin(az) * cl, sin(lat), -cos(az) * cl) * r;
}


void vertex() {
	// Контент вершины — её собственные equirect-координаты (UV). Уезжаем от
	// направления взгляда в zoom раз по большой окружности: контент под углом θ
	// от взгляда встаёт под углом θ·zoom. Угол не имеет вырождения у полюса и не
	// требует ветки по долготе — поэтому и clamp, и ветка, что были тут раньше,
	// больше не нужны.
	vec3 g = normalize(dir_from_uv(zoom_uv, yaw_rad, 1.0));
	vec3 c = normalize(dir_from_uv(UV, yaw_rad, 1.0));
	float ct = clamp(dot(c, g), -1.0, 1.0);
	vec3 t = c - g * ct;
	float tl = length(t);
	vec3 d = c;
	if (tl > 1e-6) {
		float th = acos(ct) * zoom;
		d = normalize(g * cos(th) + (t / tl) * sin(th));
	}
	VERTEX = d * radius;
}


void fragment() {
	// UV меша — координаты самого сектора, они же координаты контента: выборка
	// всегда внутри своей текстуры.
	vec2 uv = (UV * pano_px - tile_px) / tex_px;
	// Страховка: если фрагмент всё же вышел за диапазон тайлов — не рисуем его,
	// сквозь него виден фон.
	float inside = step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0);
	vec2 suv = clamp(uv, vec2(0.0), vec2(1.0));
	vec3 col = texture(tex, suv).rgb;
	if (sharpen > 0.001) {
		// На два мипа грубее — грубая версия того же; разницу возвращаем.
		vec3 blur = textureLod(tex, suv, 2.0).rgb;
		col += (col - blur) * sharpen;
	}
	ALBEDO = col;
	ALPHA = fade * inside;
}
