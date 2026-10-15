shader_type canvas_item;

// New colour of the cape, as a hue from 0 to 1 (0 = red, 0.33 = green, 0.66 = blue)
uniform float cape_hue : hint_range(0.0, 1.0) = 0.0;
// Pixels from the sprite's centre; only red pixels below this line count as the cape (the plume is above it)
uniform float cape_top = -2.0;

varying float local_y;
varying vec4 v_color;

void vertex() {
	local_y = VERTEX.y;
	v_color = COLOR;   // keeps modulate working (e.g. the white hit flash)
}

vec3 rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv2rgb(vec3 c) {
	vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
	return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

void fragment() {
	vec4 col = texture(TEXTURE, UV);
	// The cape's reds; the low green value leaves out the gold buckle
	bool is_red = col.r > col.g + 0.2 && col.r > col.b + 0.2 && col.g < 0.45;
	if (is_red && local_y > cape_top) {
		vec3 hsv = rgb2hsv(col.rgb);
		hsv.x = cape_hue;
		col.rgb = hsv2rgb(hsv);
	}
	COLOR = col * v_color;
}
