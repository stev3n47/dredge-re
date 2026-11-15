#ifdef GL_ES
precision highp float;
#else
// Desktop GL below 1.30 has no precision qualifiers and reserves the keywords, and the engine
// prepends nothing on Win32/Linux/Mac — so define them away here or the shader will not compile.
	#define highp
	#define mediump
	#define lowp
#endif

attribute vec4 a_position;
attribute vec2 a_texCoord;
attribute vec4 a_color;

// World rect of the bar's track in design points: xy is the bottom-left corner, zw the size.
// The CPU has to push it: see below for why the shader cannot work it out on its own. The track
// and not the fill, so nothing stretches as the fill grows.
uniform vec4 u_barRect;

varying vec2 v_texCoord;
varying vec4 v_fragmentColor;

// Bar-local position. The renderer bakes the node transform into the vertex buffer, so a_position
// is already world space, and nine-slice rules out v_texCoord as the alternative: every slice
// carries its own piece of the atlas, so texture coordinates jump at the cap seams.
//
// Both forms are worked out here rather than in the fragment shader, which is what lets that one
// run at mediump — it never has to touch a world coordinate.
varying highp vec2 v_localPos;	// design points, for the sparkle field
varying vec2 v_localNorm;  // fractions of the track, for the wave lines

void main()
{
	gl_Position = CC_PMatrix * a_position;

	v_localPos = a_position.xy - u_barRect.xy;
	v_localNorm = v_localPos / u_barRect.zw;

	v_texCoord = a_texCoord;
	v_fragmentColor = a_color;
}
