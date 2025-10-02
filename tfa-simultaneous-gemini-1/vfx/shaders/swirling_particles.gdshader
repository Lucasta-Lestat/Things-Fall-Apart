// swirling_particles.gdshader - Swirling Particle Effect
shader_type canvas_item;

uniform float time : hint_range(0.0, 10.0) = 0.0;
uniform float swirl_speed : hint_range(0.5, 5.0) = 2.0;
uniform vec4 particle_color : source_color = vec4(1.0, 0.5, 1.0, 1.0);
uniform vec2 resolution = vec2(100.0, 100.0);
uniform float time_seed : hint_range(0.0, 1000.0) = 0.0;

float random(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7)) + time_seed) * 43758.5453);
}

vec2 rotate(vec2 v, float a) {
    float s = sin(a);
    float c = cos(a);
    return mat2(vec2(c, -s), vec2(s, c)) * v;
}

void fragment() {
    vec2 uv = UV;
    vec2 center = vec2(0.5, 0.5);
    vec2 pos = uv - center;
    
    float particles = 0.0;
    
    // Create multiple spiraling particle streams
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float angle_offset = fi * 1.256; // Distribute around circle
        
        // Create spiral path
        float spiral_time = time * swirl_speed + fi * 0.5;
        float spiral_radius = 0.1 + fi * 0.08;
        
        for (int j = 0; j < 8; j++) {
            float fj = float(j);
            float particle_time = spiral_time - fj * 0.3;
            
            // Particle position along spiral
            float spiral_angle = particle_time * 2.0 + angle_offset;
            float current_radius = spiral_radius + sin(particle_time) * 0.05;
            
            vec2 particle_pos = vec2(
                cos(spiral_angle) * current_radius,
                sin(spiral_angle) * current_radius
            );
            
            // Distance to particle
            float dist = distance(pos, particle_pos);
            float particle_size = 0.02 + random(vec2(fi, fj)) * 0.01;
            
            // Add particle
            particles += (1.0 - smoothstep(0.0, particle_size, dist)) * 
                        (0.5 + 0.5 * sin(particle_time * 3.0));
        }
    }
    
    // Add central swirl distortion
    float swirl_dist = length(pos);
    float swirl_angle = atan(pos.y, pos.x) + swirl_dist * 3.0 - time * swirl_speed;
    vec2 swirl_uv = center + vec2(cos(swirl_angle), sin(swirl_angle)) * swirl_dist;
    
    // Particle trail effect
    float trail = random(swirl_uv * 10.0 + time) * 0.3;
    trail *= (1.0 - swirl_dist * 2.0);
    trail = max(0.0, trail);
    
    // Combine effects
    float total_particles = particles + trail;
    vec3 final_color = particle_color.rgb * total_particles;
    
    // Add sparkle
    float sparkle = step(0.95, random(uv * 15.0 + time * 3.0)) * (1.0 - swirl_dist);
    final_color += sparkle * vec3(1.0);
    
    COLOR = vec4(final_color, total_particles * particle_color.a);
}