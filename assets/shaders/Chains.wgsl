// Copyright (c) 2026 depis. All Rights Reserved.

struct Uniforms {
  resolution: vec2f,
  time: f32,
  color_t: f32,
  yaw: f32,
  pitch: f32,
  quality: f32,
  click_time: f32,
}

@group(0) @binding(0) var<uniform> uniforms: Uniforms;

// Tunables
const CAM_RADIUS          = 3.8;
const CAM_PITCH_GAIN      = 0.35;
const STEP_SCALE          = 0.75;
const SURF_EPS            = 0.0015;
const MAX_DIST            = 22.0;
const NORMAL_EPS          = 0.002;

const STEPS_LOW  : i32    = 75;
const STEPS_HIGH : i32    = 135;

const LIGHT_POS           = vec3f(2.5, 5.0, 3.0);
const LIGHT_INTENSITY     = 14.0;
const FOG_DENSITY         = 0.014;
const GLOW_FOG_DENSITY    = 0.003;
const GRAIN_STRENGTH      = 22.0 / 255.0;
const WILD_EVENT_DURATION = 2.4;

// Palette (matches TheRose.wgsl crossfade behavior)
const COLOR_RED           = vec3f(0.45, 0.08, 0.08);
const COLOR_WHITE         = vec3f(0.85, 0.80, 0.82);

@vertex
fn vs_main(@builtin(vertex_index) in_vertex_index: u32) -> @builtin(position) vec4f {
  var pos = array<vec2f, 3>(
    vec2f(-1.0, -1.0),
    vec2f(3.0, -1.0),
    vec2f(-1.0, 3.0)
  );
  return vec4f(pos[in_vertex_index], 0.0, 1.0);
}

fn hash12(p: vec2f) -> f32 {
  var p3 = fract(vec3f(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

fn getWildEventFactor(time: f32) -> f32 {
  let elapsed = time - uniforms.click_time;
  if (elapsed <= 0.0 || elapsed >= WILD_EVENT_DURATION) {
    return 0.0;
  }
  let attack = smoothstep(0.0, 0.20, elapsed);
  let release = smoothstep(WILD_EVENT_DURATION, WILD_EVENT_DURATION * 0.25, elapsed);
  let raw = attack * release;
  return raw * raw * (3.0 - 2.0 * raw);
}

fn opRotateX(p: vec3f, angle: f32) -> vec3f {
  let c = cos(angle);
  let s = sin(angle);
  return vec3f(p.x, c * p.y - s * p.z, s * p.y + c * p.z);
}

fn opRotateY(p: vec3f, angle: f32) -> vec3f {
  let c = cos(angle);
  let s = sin(angle);
  return vec3f(c * p.x - s * p.z, p.y, s * p.x + c * p.z);
}

fn opRotateZ(p: vec3f, angle: f32) -> vec3f {
  let s = sin(angle);
  let c = cos(angle);
  return vec3f(c * p.x - s * p.y, s * p.x + c * p.y, p.z);
}

// Signed Distance to a single chain link (elongated torus along X)
fn sdChainLink(p: vec3f, le: f32, r1: f32, r2: f32) -> f32 {
  let q = vec3f(p.x, max(abs(p.y) - le, 0.0), p.z);
  return length(vec2f(length(q.xy) - r1, q.z)) - r2;
}

// Infinite interlocking chain along the local Y axis, moving at `speed`
fn sdMovingChain(
  p_world: vec3f,
  offset: vec3f,
  angles: vec3f,
  speed: f32,
  scale: f32,
  chain_id: f32,
  wild: f32
) -> vec2f {
  var q = p_world - offset;
  q = opRotateZ(q, angles.z);
  q = opRotateY(q, angles.y);
  q = opRotateX(q, angles.x);
  q /= scale;

  // Fast cylindrical bounding volume: skip link math when the ray is far from this chain's axis
  let radial_dist = length(q.xz);
  if (radial_dist > 0.65) {
    return vec2f((radial_dist - 0.50) * scale, chain_id);
  }

  let time = uniforms.time;

  // Subtle transverse sway (intensifies during click wild event)
  let sway_amp = mix(0.06, 0.20, wild);
  let sway_freq = mix(2.0, 9.0, wild);
  q.x += sin(q.y * 0.8 + time * sway_freq + chain_id * 2.1) * sway_amp;
  q.z += cos(q.y * 0.7 - time * (sway_freq * 0.85) + chain_id * 3.7) * sway_amp;

  // Axial travel in this chain's direction (+ surge on click)
  let travel = time * speed + sign(speed) * wild * 1.35;
  q.y -= travel;

  // Twist chain slightly along its length
  let twist = q.y * 0.18 + sin(time * 0.6 + chain_id) * 0.3;
  let ct = cos(twist);
  let st = sin(twist);
  let xz = vec2f(ct * q.x - st * q.z, st * q.x + ct * q.z);
  q.x = xz.x;
  q.z = xz.y;

  // Repeat links every `spacing` units along Y, alternating 90-degree orientation
  let spacing = 0.72;
  let link_le = 0.18;
  let link_r1 = 0.20;
  let link_r2 = 0.068;

  var p1 = q;
  p1.y = (fract(q.y / spacing) - 0.5) * spacing;
  let d1 = sdChainLink(p1, link_le, link_r1, link_r2);

  var p2 = vec3f(q.z, (fract(q.y / spacing + 0.5) - 0.5) * spacing, q.x);
  let d2 = sdChainLink(p2, link_le, link_r1, link_r2);

  let d = min(d1, d2) * scale;
  // Fractional material ID encodes whether it's an even or odd link for subtle shading variation
  let link_parity = select(0.25, 0.75, d2 < d1);
  return vec2f(d, chain_id + link_parity);
}

fn map(p: vec3f) -> vec2f {
  let wild = getWildEventFactor(uniforms.time);
  var res = vec2f(100.0, 0.0);

  // Chain 1: Foreground diagonal (Top-Left to Bottom-Right, moving UP-LEFT)
  let c1 = sdMovingChain(p, vec3f(-0.4, 0.1, 0.7), vec3f(0.15, 0.25, 0.85), 1.45, 0.95, 1.0, wild);
  if (c1.x < res.x) { res = c1; }

  // Chain 2: Foreground counter-diagonal (Bottom-Left to Top-Right, moving DOWN-LEFT)
  let c2 = sdMovingChain(p, vec3f(0.5, -0.2, 0.4), vec3f(-0.20, -0.15, -0.75), -1.25, 0.90, 2.0, wild);
  if (c2.x < res.x) { res = c2; }

  // Chain 3: Midground vertical-left (Moving DOWN)
  let c3 = sdMovingChain(p, vec3f(-1.55, 0.0, -0.4), vec3f(0.10, 0.40, 0.18), -1.80, 0.82, 3.0, wild);
  if (c3.x < res.x) { res = c3; }

  // Chain 4: Midground vertical-right (Moving UP)
  let c4 = sdMovingChain(p, vec3f(1.60, 0.0, -0.5), vec3f(-0.12, -0.35, -0.22), 1.65, 0.82, 4.0, wild);
  if (c4.x < res.x) { res = c4; }

  // Chain 5: Background horizontal-ish sweep (Moving RIGHT)
  let c5 = sdMovingChain(p, vec3f(0.0, 0.95, -1.5), vec3f(0.30, 0.10, 1.42), 1.15, 1.10, 5.0, wild);
  if (c5.x < res.x) { res = c5; }

  // Chain 6: Deep background low sweep (Moving LEFT)
  let c6 = sdMovingChain(p, vec3f(0.0, -1.05, -1.8), vec3f(-0.25, -0.20, -1.35), -1.35, 1.15, 6.0, wild);
  if (c6.x < res.x) { res = c6; }

  return res;
}

// 4-sample Tetrahedral Normal
fn calc_normal(p: vec3f) -> vec3f {
  let e = vec2f(1.0, -1.0) * 0.57735027 * NORMAL_EPS;
  return normalize(
    e.xyy * map(p + e.xyy).x +
    e.yyx * map(p + e.yyx).x +
    e.yxy * map(p + e.yxy).x +
    e.xxx * map(p + e.xxx).x
  );
}

@fragment
fn fs_main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  let resolution = uniforms.resolution;
  let uv = (pos.xy * 2.0 - resolution) / resolution.y;
  let uv_flipped = vec2f(uv.x, -uv.y);

  let wild = getWildEventFactor(uniforms.time);

  // Orbit camera driven by mouse/gyro yaw and pitch
  let yaw = uniforms.yaw * 0.35;
  let pitch = clamp(uniforms.pitch, -1.0, 1.0) * CAM_PITCH_GAIN;
  let ro = vec3f(
    CAM_RADIUS * cos(pitch) * sin(yaw),
    CAM_RADIUS * sin(pitch),
    CAM_RADIUS * cos(pitch) * cos(yaw)
  );

  let lookAt = vec3f(0.0, 0.0, 0.0);
  let fwd = normalize(lookAt - ro);
  let right = normalize(cross(vec3f(0.0, 1.0, 0.0), fwd));
  let up = cross(fwd, right);
  let rd = normalize(fwd + right * uv_flipped.x + up * uv_flipped.y);

  var t = 0.0;
  var hit = false;
  var mat_id = 0.0;

  let primary_accent = mix(COLOR_RED, COLOR_WHITE, uniforms.color_t);
  let secondary_accent = mix(COLOR_WHITE, COLOR_RED, uniforms.color_t);
  let glow_color = mix(primary_accent, secondary_accent, wild) * (1.35 + wild * 1.6);

  var accumulated_glow = vec3f(0.0);

  let quality_01 = clamp(uniforms.quality * 0.5, 0.0, 1.0);
  let max_steps = i32(mix(f32(STEPS_LOW), f32(STEPS_HIGH), quality_01));

  for (var i = 0; i < max_steps; i++) {
    let p = ro + rd * t;
    let res = map(p);
    let d = res.x;
    mat_id = res.y;

    // Volumetric metallic halo around the chains
    accumulated_glow += glow_color * (0.00055 / (0.015 + d * d * 14.0));

    if (d < SURF_EPS) {
      hit = true;
      break;
    }
    if (t > MAX_DIST) {
      break;
    }
    t += d * STEP_SCALE;
  }

  // Deep atmospheric background gradient
  var final_color = primary_accent * 0.05 * (1.0 - length(uv) * 0.45);

  if (hit) {
    let p = ro + rd * t;
    let normal = calc_normal(p);
    let view_dir = normalize(ro - p);

    let light_vec = LIGHT_POS - p;
    let light_dist = length(light_vec);
    let light_dir = light_vec / light_dist;
    let half_dir = normalize(light_dir + view_dir);

    let attenuation = LIGHT_INTENSITY / (1.0 + 0.08 * light_dist + 0.06 * light_dist * light_dist);
    let diff = clamp(dot(normal, light_dir), 0.08, 1.0);

    // Procedural brushed iron / dark chrome surface detail
    let parity = fract(mat_id);
    let micro_grain = sin(p.x * 45.0) * sin(p.y * 45.0) * sin(p.z * 45.0) * 0.5 + 0.5;
    let base_metal = mix(vec3f(0.08, 0.08, 0.09), vec3f(0.16, 0.15, 0.17), parity);
    let albedo = base_metal * (0.85 + 0.3 * micro_grain);

    // Dual-lobe metallic specular + colored Fresnel rim light
    let spec_sharp = pow(max(dot(normal, half_dir), 0.0), 96.0) * 1.6;
    let spec_broad = pow(max(dot(normal, half_dir), 0.0), 14.0) * 0.35;
    let fresnel = pow(1.0 - max(dot(normal, view_dir), 0.0), 3.2);

    // Fake studio reflection bands for realistic dark metal
    let refl = reflect(-view_dir, normal);
    let env_band = smoothstep(-0.2, 0.8, sin(refl.y * 4.5 + refl.x * 2.0)) * 0.22;

    let diffuse = albedo * diff * attenuation;
    let specular = mix(vec3f(1.0, 0.92, 0.88), primary_accent * 2.5, 0.35) * (spec_sharp + spec_broad) * attenuation;
    let rim = glow_color * fresnel * (1.1 + wild * 1.4);

    final_color = albedo * 0.35 + diffuse + specular + env_band * primary_accent + rim;
    accumulated_glow *= 0.35;
  }

  let fog_factor = 1.0 - exp(-FOG_DENSITY * t * t);
  final_color = mix(final_color, vec3f(0.01, 0.01, 0.015), clamp(fog_factor, 0.0, 1.0));

  let glow_fog = exp(-GLOW_FOG_DENSITY * t * t);
  final_color += accumulated_glow * glow_fog;

  let noise = hash12(pos.xy + uniforms.time);
  final_color += (noise - 0.5) * GRAIN_STRENGTH;

  return vec4f(final_color, 1.0);
}