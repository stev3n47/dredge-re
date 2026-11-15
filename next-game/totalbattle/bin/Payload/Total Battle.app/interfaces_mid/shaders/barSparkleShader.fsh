#ifdef GL_ES
precision mediump float;
#else
// Desktop GL below 1.30 has no precision qualifiers and reserves the keywords, and the engine
// prepends nothing on Win32/Linux/Mac — so define them away here or the shader will not compile.
	#define highp
	#define mediump
	#define lowp
#endif

varying vec2 v_texCoord;
varying vec4 v_fragmentColor;

// Kept highp while everything else drops to mediump: the sparkle field measures distances of a
// point or two against coordinates that run into the hundreds, and fp16 quantises that into
// visible steps. The wave lines work in fractions of the track and do not care.
varying highp vec2 v_localPos;
varying vec2 v_localNorm;

/** Tuning. Constants rather than uniforms so the compiler can fold them — the divisions below
	turn into multiplications, which matters because division costs a sine on mobile. A shader is
	re-read from disk on launch, so trying numbers here costs a restart and not a rebuild. **/

// Blurred wavy lines drawn along the bar.
const int WispCount = 3;
const vec3 WispColor = vec3(1.0, 0.92, 0.66);
const float WispWaves = 6.0;  // radians of wave across the track
const float WispSwing = 0.22;  // vertical travel of a crest, in bar heights
const float WispBlur = 0.09;  // blur reach either side of a crest, in bar heights
const float WispCrestSpeed = 0.94;	// radians per second
const float WispPatchWaves = 6.5;  // radians of the brightness wave across the track
const float WispPatchSpeed = 1.56;	// radians per second
const float WispStrength = 0.32;

// Sparkles: one per cell, each blinking on its own clock.
const vec3 SparkleColor = vec3(1.0, 0.94, 0.74);
const vec2 SparkleCell = vec2(46.0, 26.0);	// design points
const vec2 SparkleDrift = vec2(0.35, 0.2);	// travel over one life, in cells; must stay under 1
const float SparkleRadius = 1.1;  // design points
const float SparkleSpeed = 0.39;  // lives per second
const float SparkleStrength = 1.0;

// A dot is a tight core plus a wide halo — one lobe alone reads as a flat blob. Both are
// polynomials that reach zero at a finite distance, which is what replaced a pair of exp() calls
// per cell: same shape to the eye, no transcendental. The numbers are the reciprocal of where
// each lobe dies, in squared radii — so the core ends at two radii and the halo at seven.
const float SparkleCoreFalloff = 0.25;
const float SparkleHaloFalloff = 0.02;
const float SparkleHaloWeight = 0.3;

const float InvWispBlur = 1.0 / WispBlur;
const float InvSparkleRadius2 = 1.0 / (SparkleRadius * SparkleRadius);

// Soft wavy lines, drawn rather than sampled. Each one is a crest snaking along the bar; the
// brightness falls off with distance to it, and that falloff is the whole blur.
float wisps(vec2 norm, highp float time)
{
	float total = 0.0;

	for (int i = 0; i < WispCount; ++i)
	{
		float band = float(i);

		// Own tilt, own phase, own resting height. Without that the three run parallel and read
		// as one thick stripe instead of crossing lines. The loop unrolls, so none of this costs
		// anything at runtime.
		float tilt = 1.0 + band * 0.45;
		float phase = band * 2.4;

		float crest = 0.5 + (band - 1.0) * 0.2
				+ WispSwing * sin(norm.x * WispWaves * tilt + time * WispCrestSpeed + phase);

		// Bright patches travel along the line at their own rate, so it never lights up from cap
		// to cap. Reaching below zero is the point: that is where the line breaks up.
		float envelope = 0.35 + 0.65 * sin(norm.x * WispPatchWaves - time * WispPatchSpeed + phase * 1.7);

		float offset = (norm.y - crest) * InvWispBlur;

		// Three exponentials in the whole shader, against sixty-odd the sparkles used to spend.
		// Not worth trading for a polynomial when this is the shape the eye actually reads.
		total += exp(-offset * offset) * max(envelope, 0.0);
	}

	return min(total, 2.0);
}

// One sine per cell rather than three: the other two seeds fall out of the same number, scaled
// past the fraction so what is left is uncorrelated enough to place and time a dot.
highp vec3 cellSeeds(highp vec2 cell)
{
	highp float single = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5453);
	return fract(single * vec3(1.0, 137.17, 1013.31));
}

float sparkles(highp vec2 local, highp float time)
{
	highp vec2 field = local / SparkleCell;
	highp vec2 origin = floor(field);

	float glow = 0.0;

	// Three columns but only two rows. A dot sits above its own cell origin and drifts further up
	// from there, so the row above can never reach far enough down to be seen; the row below can.
	for (int y = -1; y <= 0; ++y)
	{
		for (int x = -1; x <= 1; ++x)
		{
			highp vec2 cell = origin + vec2(float(x), float(y));
			highp vec3 seeds = cellSeeds(cell);

			// Own period and own phase per cell, otherwise the whole bar blinks in lockstep.
			float life = fract(time * SparkleSpeed * (0.6 + 0.8 * seeds.x) + seeds.y);

			// sin(pi * life) squared in all but name, minus the transcendental.
			float bump = life * (1.0 - life);
			float fade = 16.0 * bump * bump;

			highp vec2 center = cell + vec2(0.2 + 0.6 * seeds.y, 0.15 + 0.7 * seeds.z) + SparkleDrift * life;

			// Back to points before measuring: a non-square cell would stretch a round dot into
			// an ellipse otherwise.
			highp vec2 delta = (field - center) * SparkleCell;

			// Randomised in reciprocal form on purpose. Picking a radius and dividing by it would
			// cost a division per cell, and a division is priced like a sine on mobile.
			float falloff = dot(delta, delta) * InvSparkleRadius2 * (0.55 + 0.9 * seeds.z);

			float core = max(0.0, 1.0 - falloff * SparkleCoreFalloff);
			float halo = max(0.0, 1.0 - falloff * SparkleHaloFalloff);

			glow += fade * (core * core * core + SparkleHaloWeight * halo * halo);
		}
	}

	return min(glow, 1.5);
}

void main()
{
	vec4 tex = texture2D(CC_Texture0, v_texCoord);

	// Highp deliberately: this is seconds since launch, and at mediump it would quantise into a
	// stutter within minutes and freeze outright within the hour.
	highp float time = CC_Time[1];

	vec3 add = SparkleColor * sparkles(v_localPos, time) * SparkleStrength
			+ WispColor * wisps(v_localNorm, time) * WispStrength;

	// The bar's own alpha is the mask: nothing leaks past the fill's edge or its pointed cap.
	// Textures are premultiplied, so scaling by tex.a keeps the addition in the same space.
	tex.rgb += add * tex.a;

	gl_FragColor = tex * v_fragmentColor;
}
