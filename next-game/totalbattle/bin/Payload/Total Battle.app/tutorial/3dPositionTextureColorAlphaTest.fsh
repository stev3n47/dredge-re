#ifdef GL_ES
precision mediump float;
#endif

varying vec2 TextureCoordOut;

uniform vec4 u_color;
uniform float u_alphaThreshold;

void main(void)
{
    vec4 c = texture2D(CC_Texture0, TextureCoordOut) * u_color;
    if (c.a < u_alphaThreshold)
        discard;
    gl_FragColor = c;
}
