#ifdef GL_ES
precision highp float;
#endif

uniform sampler2D u_octave;

uniform float u_emptiness;
uniform float u_sharpness;

varying vec2 v_texCoord;
varying vec2 v_texCoord1;
varying vec4 v_fragmentColor;

void main() 
{
    vec4 mainColor = texture2D(CC_Texture0, v_texCoord);
    vec4 noiseColor = texture2D(u_octave, v_texCoord1);
    float n1 = noiseColor.r;
    float n2 = noiseColor.g;
    float n3 = noiseColor.b;
    float n4 = noiseColor.a;

    float fbm = 0.5 * n1 + 0.25 * n2 + 0.125 * n3 + 0.0625 * n4;
    fbm = (clamp(fbm, u_emptiness, u_sharpness) - u_emptiness) / (u_sharpness - u_emptiness);

    vec4 finalColor = v_fragmentColor * mainColor;
    finalColor.a = fbm * mainColor.a;

    gl_FragColor = finalColor;
}
