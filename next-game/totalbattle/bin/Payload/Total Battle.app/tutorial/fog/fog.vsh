#ifdef GL_ES
precision highp float;
#endif

attribute vec4 a_position;
attribute vec2 a_texCoord;
attribute vec4 a_color;

uniform float u_speed;

varying vec2 v_texCoord;
varying vec2 v_texCoord1;
varying vec4 v_fragmentColor;

const vec2 tiling = vec2(2, 2);

void main() 
{
    gl_Position = CC_PMatrix * a_position;

	float time = CC_Time[0];

    v_texCoord = a_texCoord;
    v_texCoord1 = (a_texCoord * tiling) + time * u_speed * vec2(1.0, 0.0);
    v_fragmentColor = a_color;
}
