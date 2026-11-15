#ifdef GL_ES
precision mediump float;
#endif

varying vec4 v_fragmentColor;
varying vec2 v_texCoord;

uniform float u_progress;
uniform vec2 u_uvOrigin;
uniform vec2 u_uvSize;
uniform float u_rotated;

const vec4 color = vec4(0.92, 0.62, 0.32, 0.7);
const float maxDiff = 0.8;
const float halfDiff = 0.4;

void main()
{
	vec4 tex = vec4(texture2D(CC_Texture0, v_texCoord).rgb, texture2D(CC_Texture1, v_texCoord).r);
	tex.rgb *= tex.a;

	vec2 n = (v_texCoord - u_uvOrigin) / u_uvSize;
	vec2 uv = mix(n, vec2(n.y, 1.0 - n.x), u_rotated);

	float diff = uv.x - (u_progress + uv.y);
	if (diff <= maxDiff && diff > 0.0)
	{
		diff = maxDiff - (abs(diff - halfDiff) / halfDiff) * maxDiff;

		tex = tex + (color * diff) * color.a * tex.a;
	}
	gl_FragColor = tex * v_fragmentColor;
}
