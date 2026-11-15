#ifdef GL_ES
precision mediump float;
#endif

varying vec4 v_fragmentColor;
varying vec2 v_texCoord;

void main()
{
    vec4 tex = vec4(texture2D(CC_Texture0, v_texCoord).rgb,
                    texture2D(CC_Texture1, v_texCoord).r);
    tex.rgb *= tex.a;

    vec4 c = tex * v_fragmentColor;

    float a = c.a;
    vec3 rgb = c.rgb;
    if (a > 0.0) {
        rgb /= a;
    }

    float luma = dot(rgb, vec3(0.299, 0.587, 0.114));

    float gamma = 0.94;
    float l = clamp(pow(luma, gamma), 0.0, 1.0);

    float toe = 0.06;
    float l2 = mix(toe, 1.0, l) * 0.68;

    vec3 shadowTint    = vec3(0.76, 0.52, 0.26);
    vec3 highlightTint = vec3(1.02, 0.85, 0.58);

    float t = smoothstep(0.10, 0.74, l2);
    vec3 tint = mix(shadowTint, highlightTint, t);

    vec3 outRgb = clamp(l2 * tint, 0.0, 1.0);

    float strength = 0.93;
    outRgb = mix(rgb, outRgb, strength);

    outRgb *= a;

    gl_FragColor = vec4(outRgb, a);
}
