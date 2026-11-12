shader_type spatial;
render_mode unshaded, cull_disabled;

// Атлас контроллера — запечённая светотень: в ней есть мягкие тёмные области
// (тени), которые на нижней части корпуса читаются как грязные пятна. Поднимаем
// тёмный уровень ТОЛЬКО снизу (по локальной Y модели), а лицо с кнопками не
// трогаем: кнопки видны именно как тёмные кружки с надписями, и подъём по всей
// модели их обесцвечивает.
uniform sampler2D albedo_tex : source_color, filter_linear;
uniform float dark_floor : hint_range(0.0, 1.0) = 0.8;
uniform float lift_y_lo = 0.4; // ниже этой Y модели тени подняты полностью
uniform float lift_y_hi = 1.8; // выше — не трогаем (кнопки лица на y >= 2.0)

varying float local_y;

void vertex() {
	local_y = VERTEX.y;
}

void fragment() {
	vec3 c = texture(albedo_tex, UV).rgb;
	float lift = 1.0 - smoothstep(lift_y_lo, lift_y_hi, local_y);
	ALBEDO = mix(c, max(c, vec3(dark_floor)), lift);
}
