shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;
// Brightness above which a pixel turns black (below it turns white)
uniform float threshold : hint_range(0.0, 1.0) = 0.4;

void fragment() {
	float brightness = dot(texture(screen_tex, SCREEN_UV).rgb, vec3(0.299, 0.587, 0.114));
	// Bright things go black, dark things go white: the classic anime impact-frame look
	COLOR = vec4(vec3(1.0 - step(threshold, brightness)), 1.0);
}
