#ifdef GL_ES
precision highp float;
#endif

attribute vec4 a_position;
attribute vec2 a_texCoord;
attribute vec4 a_color;

varying vec2 v_texCoord;
varying vec4 v_fragmentColor;
varying float v_progress;

void main() 
{
    gl_Position = CC_PMatrix * a_position;

    v_progress = fract(CC_Time[1]);

    v_texCoord = a_texCoord;
    v_fragmentColor = a_color;
}
