#ifdef GL_ES
precision mediump float;
#endif

varying vec4 v_fragmentColor;
varying vec2 v_texCoord;
varying float v_progress;

const vec4 color = vec4(0.92, 0.62, 0.32, 0.7);
const float maxDiff = 0.8;
const float halfDiff = 0.4;

void main()
{
    vec4 tex = vec4(texture2D(CC_Texture0, v_texCoord).rgb, texture2D(CC_Texture1, v_texCoord).r);
    tex.rgb *= tex.a; // Premultiply with Alpha channel

    float progress = v_progress + v_texCoord.y;

    float diff = v_texCoord.x - progress;
    if (diff <= maxDiff && diff > 0.0)
    {
        diff = maxDiff - (abs(diff - halfDiff) / halfDiff) * maxDiff;

        tex = tex + (color * diff) * color.a * tex.a;
    }
    gl_FragColor = tex * v_fragmentColor;
}