#ifdef GL_ES
precision mediump float;
#endif

varying vec4 v_fragmentColor;
varying vec2 v_texCoord;

// Direction the fade runs along, in texture space (e.g. (0,1) = along Y).
uniform vec2 u_dir;
// Fade band along u_dir: fully transparent at u_edge0, fully opaque at u_edge1.
uniform float u_edge0;
uniform float u_edge1;

void main()
{
    // CC_Texture0 is premultiplied, as is v_fragmentColor.
    vec4 c = texture2D(CC_Texture0, v_texCoord) * v_fragmentColor;

    // Project from the center so direction flips around the middle and
    // edges stay in [0..1] for axis-aligned directions (incl. negatives).
    float s = dot(v_texCoord - vec2(0.5), u_dir) + 0.5;
    float g = smoothstep(u_edge0, u_edge1, s);

    // Scaling the whole premultiplied color keeps premultiplication valid.
    gl_FragColor = c * g;
}
