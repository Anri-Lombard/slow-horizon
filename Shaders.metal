#include <metal_stdlib>
using namespace metal;

// res is the whole scene in this layer's pixels and originY is where the layer starts within it,
// so sky and sea compute one picture in the same coordinates.
struct Shared {
  float2 res, sun, moon;
  float originY, layerHeight, horizon, sunUp, moonUp, night, lowSun, fog, rain, rainX;
  float3 skyTop, skyHor, seaFar, seaNear, glow, whale, rainbow;
  float4 boats[5];
};

struct SkyParams {
  float2 cloudDrift, layerSize;
  float cloudAmount;
};

struct SeaParams {
  float2 scrollSwell, scrollChop, scrollRipple, driftGust, driftWind;
  float roughness;
};

struct Wave {
  float2 cycles;
  float amplitude, phase;
};

constant float slopeRMS = 0.12;
constant float cameraHeight = 18.0;

// Mipmaps average fine waves away with distance, so far water settles instead of shimmering.
constexpr sampler waveSampler(address::repeat, filter::linear, mip_filter::linear, max_anisotropy(4));
constexpr sampler starSampler(address::clamp_to_edge, filter::linear);

vertex float4 fullscreen(uint id [[vertex_id]]) {
  float2 corner = float2(id == 1 ? 3.0 : -1.0, id == 2 ? 3.0 : -1.0);
  return float4(corner, 0.0, 1.0);
}

// Baked once at launch. Summing waves per pixel every frame costs far more and shows no better
// from this distance. Each wave has a whole number of cycles per tile, so the tile has no seam.
fragment float4 bakeWaves(float4 position [[position]],
                          constant Wave *slopeWaves [[buffer(0)]],
                          constant uint &slopeCount [[buffer(1)]],
                          constant Wave *fieldWaves [[buffer(2)]],
                          constant uint &fieldCount [[buffer(3)]],
                          constant float &size [[buffer(4)]]) {
  float2 p = position.xy / size;
  float2 slope = 0.0;
  float field = 0.0;
  for (uint i = 0; i < slopeCount; i++) {
    Wave w = slopeWaves[i];
    slope += normalize(w.cycles) * w.amplitude * cos(6.2831853 * dot(w.cycles, p) + w.phase);
  }
  for (uint i = 0; i < fieldCount; i++) {
    Wave w = fieldWaves[i];
    field += w.amplitude * cos(6.2831853 * dot(w.cycles, p) + w.phase);
  }
  return float4(0.5 + slope, 0.5 + field, 1.0);
}

static float hash(float2 p) {
  float3 q = fract(p.xyx * 0.1031);
  q += dot(q, q.yzx + 33.33);
  return fract((q.x + q.y) * q.z);
}

static float3 skyGradient(float2 p, float aspect, constant Shared &s) {
  float v = clamp((p.y - s.horizon) / (1.0 - s.horizon), 0.0, 1.0);
  float dx = abs(p.x - s.sun.x) * aspect;
  float d = length((p - s.sun) * float2(aspect, 1.0));
  return mix(s.skyHor, s.skyTop, pow(v, 0.55))
       + s.glow * (exp(-d * 2.6) * 0.4 + exp(-v * v * 22.0) * exp(-dx * 0.9) * 0.45 * s.lowSun);
}

// Haze softens the join, so the horizon reads as a tone change and not a drawn line.
static float3 horizonHaze(float3 col, float y, constant Shared &s) {
  float offset = (y - s.horizon) * mix(150.0, 14.0, s.fog);
  return mix(col, mix(s.skyHor, s.seaFar, 0.45), exp(-offset * offset) * mix(0.55, 0.96, s.fog));
}

static float inside(float distance) {
  return 1.0 - smoothstep(-0.35, 0.35, distance);
}

// How much of a point is dark hull (x) and pale sail (y). q is in boat units with the waterline
// at zero, and h is the direction of travel.
static float2 boatShape(int kind, float2 q, float h) {
  if (kind == 0) {
    float hull = inside(max(max(abs(q.x) + q.y * 0.9 - 9.0, q.y - 2.0), -q.y));
    float bridge = inside(max(max(abs(q.x - h * 5.0) - 2.2, q.y - 3.9), -q.y));
    return float2(max(hull, bridge), 0.0);
  }
  if (kind == 1) {
    float hull = inside(max(max(abs(q.x) + q.y * 0.6 - 2.6, q.y - 0.7), -q.y));
    float k = (q.y - 0.9) / 6.1;
    float along = q.x * h;
    float sail = inside(max(max(-along, along - 2.4 * (1.0 - k)), max(-k * 6.1, (k - 1.0) * 6.1)));
    return float2(hull, sail);
  }
  if (kind == 3) {
    float hull = inside(max(max(abs(q.x) + q.y * 0.8 - 7.5, q.y - 1.3), -q.y));
    // Three masts of tapering sail, the middle one tallest, with the tiers just separated.
    float sails = 0.0;
    for (int mast = -1; mast <= 1; mast++) {
      float top = mast == 0 ? 9.0 : 7.6;
      float width = 1.55 * (top - q.y) / (top - 1.7);
      float cloth = inside(max(abs(q.x - float(mast) * 3.3) - width, max(1.7 - q.y, q.y - top)));
      sails = max(sails, cloth * (0.72 + 0.28 * smoothstep(-0.4, 0.4, sin(q.y * 3.1))));
    }
    return float2(hull, sails);
  }
  if (kind == 4) {
    // Tabular, as Southern Ocean bergs are: a long flat top and steep sides.
    float top = min(3.1 + 0.3 * sin(q.x * 0.55 + 0.6), (10.0 - abs(q.x)) * 1.5);
    return float2(0.0, inside(max(q.y - top, -q.y)));
  }
  float hull = inside(max(max(abs(q.x) + q.y * 0.7 - 4.0, q.y - 1.3), -q.y));
  float cabin = inside(max(abs(q.x + h * 1.3) - 1.0, abs(q.y - 1.9) - 1.1));
  float mast = inside(max(abs(q.x - h * 1.4) - 0.12, abs(q.y - 2.5) - 2.6));
  return float2(max(hull, max(cabin, mast)), 0.0);
}

// Evaluated in both layers, so a boat near the horizon draws across the join.
static float3 drawBoats(float3 col, float2 pixel, constant Shared &s) {
  if (abs(pixel.y / s.res.y - s.horizon) > 0.045) return col;
  float unit = s.res.y / 720.0;
  float seen = 1.0 - 0.92 * s.fog;
  float3 dark = s.seaNear * 0.85 + s.skyHor * 0.12;
  float3 pale = s.skyHor * 1.22 + s.glow * 0.25;
  for (int i = 0; i < 5; i++) {
    float4 b = s.boats[i];
    if (b.z == 0.0) continue;
    float2 q = (pixel - b.xy * s.res) / (unit * b.z);
    if (abs(q.x) > 12.0) continue;
    float2 shape = boatShape(i, q, b.w);
    col = mix(col, dark, shape.x * 0.82 * seen);
    col = mix(col, pale, shape.y * 0.85 * seen);
    if (q.y < 0.0) {
      float2 mirrored = boatShape(i, float2(q.x + sin(q.y * 2.4) * 0.35, -q.y * 0.8), b.w);
      col = mix(col, dark, mirrored.x * 0.32 * seen);
      col = mix(col, pale, mirrored.y * 0.22 * seen);
    }
    if (i == 4) continue;
    float2 lamp = i == 0 ? float2(b.w * 5.0, 4.6) : i == 1 ? float2(0.0, 7.3) : i == 2 ? float2(b.w * 1.4, 5.2) : float2(b.w * 6.0, 2.0);
    float2 toLamp = q - lamp;
    col += float3(0.75, 0.58, 0.36) * exp(-dot(toLamp, toLamp) * 0.6) * s.night * 0.75 * seen;
  }
  return col;
}

// Rain is only ever seen far off, as a curtain under the cloud. Falling streaks on screen would
// be constant fast motion.
static float rainCurtain(float x, float aspect, constant Shared &s) {
  float offset = (x - s.rainX) * aspect;
  return s.rain * exp(-offset * offset * 7.0);
}

// Fixed grain breaks up banding in the dark gradients. It must not animate: flicker would be the
// one thing on this screen the eye could not ignore.
static float3 grain(float3 col, float2 position) {
  return col + (hash(position) - 0.5) * 2.4 / 255.0;
}

fragment float4 drawSky(float4 position [[position]],
                        constant Shared &s [[buffer(0)]],
                        constant SkyParams &sky [[buffer(1)]],
                        texture2d<float> waveMap [[texture(0)]],
                        texture2d<float> starLayer [[texture(1)]]) {
  float2 pixel = float2(position.x, s.layerHeight - position.y + s.originY);
  float2 uv = pixel / s.res;
  float aspect = s.res.x / s.res.y;
  float2 toSun = (uv - s.sun) * float2(aspect, 1.0);
  float dSun = length(toSun);
  float dMoon = length((uv - s.moon) * float2(aspect, 1.0));
  float sunDx = abs(toSun.x);
  float v = (uv.y - s.horizon) / (1.0 - s.horizon);
  float3 col = skyGradient(uv, aspect, s);

  // Clouds flatten towards the horizon, as high stratus does in a long exposure.
  // Two scales of the baked noise hide the tile across the width of the sky.
  float depth = 1.0 / (v + 0.18);
  float2 cp = float2(uv.x * aspect * 0.9 * depth, depth * 1.7) + sky.cloudDrift;
  float field = 0.5 + (waveMap.sample(waveSampler, cp * 0.125).b + waveMap.sample(waveSampler, cp * 0.047 + 0.37).b - 1.0) * 0.75;
  float c = smoothstep(0.42, 0.68, field + sky.cloudAmount);
  float3 cloudTint = mix(s.skyHor * 0.82, s.skyTop * 0.72 + s.glow * 0.9 * exp(-sunDx * 0.7), 0.6 - 0.25 * v);
  // Thick cloud keeps its shape through lighter and darker undersides. By day cloud is brighter
  // than the sky behind it, or an overcast afternoon reads as nightfall.
  float daylight = 1.0 - max(s.night, s.lowSun);
  float cloudGrey = dot(cloudTint, float3(0.3, 0.59, 0.11));
  cloudTint = mix(cloudTint, float3(cloudGrey), 0.6 * daylight) * (0.84 + 0.75 * (field - 0.5)) * (1.0 + 0.42 * daylight);
  col += starLayer.sample(starSampler, position.xy / sky.layerSize).rgb * (1.0 - c * 0.8);
  col = mix(col, cloudTint + s.night * float3(0.012, 0.014, 0.02) * s.moonUp, c * 0.72);

  // Mixed towards a fixed tone, not added, so the disc stays close to the sky around it.
  float3 disc = mix(float3(0.95, 0.95, 0.9), float3(0.98, 0.76, 0.55), s.lowSun * s.lowSun);
  col = mix(col, disc, s.sunUp * (1.0 - smoothstep(0.006, 0.046, dSun)) * (1.0 - c * 0.75) * 0.82);
  col += s.glow * s.sunUp * exp(-dSun * 15.0) * 0.3;
  col += float3(0.85, 0.85, 0.8) * s.sunUp * (1.0 - c * 0.5) * exp(-dSun * 9.0) * 0.2;
  col += float3(0.75, 0.8, 0.9) * s.moonUp * exp(-dMoon * 13.0) * 0.1;

  // Curtains lean with the wind and have no edge at the top, where they merge into the cloud.
  float streaks = waveMap.sample(waveSampler, float2((uv.x + v * 0.1) * aspect * 0.55, v * 0.05 + 0.17)).b;
  col = mix(col, mix(s.skyHor, s.skyTop, 0.5) * 0.48,
            rainCurtain(uv.x + v * 0.1, aspect, s) * (1.0 - smoothstep(0.02, 0.5, v)) * clamp(0.55 + 1.1 * (streaks - 0.5), 0.0, 1.0) * 0.85);

  // A primary bow, 40 to 42 degrees from the point opposite the sun, red on the outside.
  if (s.rainbow.z > 0.0) {
    float altitude = v * 1.5708;
    float2 fromCentre = float2((uv.x - s.rainbow.x) * 4.3633 * cos(altitude), altitude - s.rainbow.y);
    float t = (length(fromCentre) - 0.716) / 0.032;
    float3 spectrum = float3(smoothstep(-0.2, 1.0, t), exp(-t * t * 2.2), 1.0 - smoothstep(-1.0, 0.2, t));
    // Faint, and strongest low down: rain seldom reaches high enough to carry the whole arc.
    col += spectrum * exp(-t * t * 0.7) * s.rainbow.z * 0.055 * (1.0 - smoothstep(0.05, 0.42, v));
  }

  col = drawBoats(horizonHaze(col, uv.y, s), pixel, s);

  return float4(grain(col, position.xy), 1.0);
}

static float2 slopeAt(texture2d<float> waveMap, float2 coord) {
  return (waveMap.sample(waveSampler, coord).rg - 0.5) / slopeRMS;
}

static float softField(texture2d<float> waveMap, float2 p) {
  return 0.5 + (waveMap.sample(waveSampler, p * 0.125).b - 0.5) * 1.1;
}

fragment float4 drawSea(float4 position [[position]],
                        constant Shared &s [[buffer(0)]],
                        constant SeaParams &sea [[buffer(1)]],
                        texture2d<float> waveMap [[texture(0)]]) {
  float2 pixel = float2(position.x, s.layerHeight - position.y + s.originY);
  float2 uv = pixel / s.res;
  float aspect = s.res.x / s.res.y;

  // A ray from a clifftop camera meets the sea, so wave size follows true perspective.
  float3 ray = normalize(float3((uv.x - 0.5) * aspect, uv.y - s.horizon, 1.0));
  float2 ground = ray.xz * cameraHeight / max(-ray.y, 0.0001);

  // Wind arrives in patches, which is what gives open water its light and dark areas.
  float gust = softField(waveMap, ground * 0.0035 + sea.driftGust);

  // Three scales scrolling across each other keep any one tile from reading as a sliding sheet.
  const float2x2 turnA = float2x2(float2(0.76, 0.65), float2(-0.65, 0.76));
  const float2x2 turnB = float2x2(float2(0.9, -0.44), float2(0.44, 0.9));
  float2 swell = slopeAt(waveMap, ground / 190.0 + sea.scrollSwell);
  float2 chop = slopeAt(waveMap, turnA * ground / 67.0 + sea.scrollChop) * turnA;
  float2 ripple = slopeAt(waveMap, turnB * ground / 23.0 + sea.scrollRipple) * turnB;
  float2 slope = swell * 0.045 * (0.7 + 0.6 * sea.roughness)
               + chop * 0.06 * (0.5 + sea.roughness)
               + ripple * 0.065 * (0.35 + 1.3 * gust) * (0.4 + 1.2 * sea.roughness);

  float3 normal = normalize(float3(-slope.x, 1.0, -slope.y));
  float fresnel = min(0.02 + 0.98 * pow(1.0 - max(dot(-ray, normal), 0.0), 5.0), 0.62);
  float3 bounce = reflect(ray, normal);
  bounce.y = max(bounce.y, 0.004);
  float2 seen = float2(0.5 + bounce.x / bounce.z / aspect, s.horizon + bounce.y / bounce.z);

  float3 mirrored = skyGradient(seen, aspect, s);
  float2 toSun = (seen - s.sun) * float2(aspect, 1.0);
  float2 toMoon = (seen - s.moon) * float2(aspect, 1.0);
  mirrored += mix(float3(0.9, 0.9, 0.84), float3(0.95, 0.6, 0.36), s.lowSun) * s.sunUp
            * exp(-dot(toSun, toSun) * 120.0) * mix(1.1, 0.7, s.lowSun);
  mirrored += float3(0.62, 0.68, 0.8) * s.moonUp * exp(-dot(toMoon, toMoon) * 160.0) * 2.4;

  // Waves too small to resolve still show far out as wind lines, stretched by perspective.
  float below = (s.horizon - uv.y) / s.horizon;
  float nearHorizon = 1.0 / (below + 0.04);
  float windLines = softField(waveMap, float2((uv.x - 0.5) * aspect * nearHorizon * 0.35, nearHorizon * 2.2) + sea.driftWind);
  float farAway = 1.0 - smoothstep(0.1, 0.5, below);
  fresnel *= 0.78 + 0.44 * windLines * farAway + 0.22 * (1.0 - farAway);

  float3 col = mix(mix(s.seaFar, s.seaNear, smoothstep(0.0, 1.0, below) * 0.9 + 0.1), mirrored, fresnel);
  col = mix(col, mix(s.skyHor, s.skyTop, 0.5) * 0.62, rainCurtain(uv.x, aspect, s) * exp(-below * 12.0) * 0.6);

  // A whale surfacing far off: a low back and a blow of mist that drifts away.
  if (s.whale.z > 0.0) {
    float2 q = (pixel - s.whale.xy * s.res) / (s.res.y / 720.0);
    float width = 0.7 + max(q.y, 0.0) * 0.28;
    float blow = exp(-q.x * q.x / (width * width)) * smoothstep(-0.3, 0.6, q.y) * (1.0 - smoothstep(2.5, 6.5, q.y));
    float2 onBack = (q - float2(1.4, 0.0)) / float2(2.4, 0.5);
    col = mix(col, s.seaNear * 0.8, inside(dot(onBack, onBack) - 1.0) * step(0.0, q.y) * 0.4 * s.whale.z);
    col = mix(col, s.skyHor * 1.25, blow * 0.6 * s.whale.z);
  }

  return float4(grain(drawBoats(horizonHaze(col, uv.y, s), pixel, s), position.xy), 1.0);
}
