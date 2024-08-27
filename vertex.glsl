#version 330 core
layout (location = 0) in vec2 aPos;
layout (location = 1) in vec3 aColor;

out vec3 ourColor;

uniform float pos_x;
uniform float pos_y;

void main() {
    vec2 translation = vec2(pos_x, -pos_y); // Construct the translation vector
    vec2 translatedPos = aPos + translation; // Apply translation
    gl_Position = vec4(translatedPos, 0.0, 1.0);
    ourColor = aColor;
}

