#ifdef GL_ES
precision mediump float;
#endif

attribute vec4 a_position;
attribute vec2 a_texCoord;
attribute vec4 a_color;

varying vec2 v_texCoord;
varying vec4 v_fragmentColor;
varying float v_progress;

float easeOutCubic(float t, float b, float c, float d) 
{
	t /= d;
	t--;
	return c*(t*t*t + 1.0) + b;
}

void main() 
{
    gl_Position = CC_PMatrix * a_position;

	float ctime = (CC_SinTime[3] + 1.0) / 2.0;
	v_progress = easeOutCubic(ctime, -2.0, 3.0, 2.0);

    v_texCoord = a_texCoord;
    v_fragmentColor = a_color;
}
