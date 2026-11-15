#ifdef GL_ES
precision mediump float;
#endif

varying vec4 v_fragmentColor;
varying vec2 v_texCoord;

void main()
{
    vec4 tex = texture2D(CC_Texture0, v_texCoord);

    // Apply vertex color/opacity like the default pipeline
    vec4 c = tex * v_fragmentColor;

    // --- Handle premultiplied alpha
    float a = c.a;
    vec3 rgb = c.rgb;
    if (a > 0.0) {
        rgb /= a;
    }

    // 1) Luminance
    float luma = dot(rgb, vec3(0.299, 0.587, 0.114));

    // 2) Gentler shaping: gamma closer to 1 => less extreme highlights
    float gamma = 0.94;
    float l = clamp(pow(luma, gamma), 0.0, 1.0);

    // Add a "toe" so shadows don't go too dark
    float toe = 0.10;                  // raise to brighten darks, lower to darken
    float l2 = mix(toe, 1.0, l);       // remap l into [toe..1]

    // 3) Two-tone ramp: lift shadows and slightly reduce highlight intensity
    vec3 shadowTint    = vec3(0.76, 0.46, 0.16);
    vec3 highlightTint = vec3(1.125, 0.965, 0.615); // slightly less yellow (↓G, tiny ↑B)

    float shadowStart = 0.12;
    float shadowEnd   = 0.78;
    float t = smoothstep(shadowStart, shadowEnd, l2);

    vec3 tint = mix(shadowTint, highlightTint, t);

    // 4) Much smaller highlight pop
    float highlightBoost = 0.08;
    float pop = 1.0 + highlightBoost * smoothstep(0.65, 1.0, l2);

    vec3 sepiaRgb = clamp(l2 * tint * pop, 0.0, 1.0);

    // 5) Strength
    float strength = 0.98;
    vec3 outRgb = mix(rgb, sepiaRgb, strength);

    // Re-premultiply alpha
    outRgb *= a;

    gl_FragColor = vec4(outRgb, a);
}
