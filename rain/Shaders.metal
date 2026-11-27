//
//  Shaders.metal
//  rain
//
//  Rain on a fogged window at night.
//  Glass space: x = 0…aspect, y = 0…1 (top → bottom). uv = 0…1, y down.
//

#include <metal_stdlib>
using namespace metal;

// Must match RainRenderer.swift
struct Uniforms {
    float4 a; // aspect, time, dt, fogInit
    float4 b; // drawableW, drawableH, waterW, waterH
    float4 c; // photoAspect, hasPhoto, photoExposure, refraction
    float4 d; // fogTau, wetTau, fogStrength, seed
    float4 e; // vanishX fraction, horizon, haze warmth, skyline seed
    float4 f; // parallax: street offset (uv), bokeh offset (glass units)
    float4 k; // parallax: glass offset (uv), glass zoom, street zoom
};
struct DropInstance  { float4 a; float4 b; }; // a: x, y, radius, stretch
struct BokehInstance { float4 a; float4 b; }; // a: x, y, radius, intensity | b: rgb, seed

constant float2 kQuad[4] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0) };

// ───────────────────────── noise ─────────────────────────

float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float3 hash32(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return fract((p3.xxy + p3.yzz) * p3.zyx);
}

float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash12(i);
    float b = hash12(i + float2(1.0, 0.0));
    float c = hash12(i + float2(0.0, 1.0));
    float d = hash12(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(float2 p, int octaves) {
    float v = 0.0, amp = 0.5;
    for (int i = 0; i < octaves; i++) {
        v += amp * vnoise(p);
        p = p * 2.03 + float2(17.1, 9.7);
        amp *= 0.5;
    }
    return v;
}

float3 aces(float3 x) {
    return saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
}

float2 glassToClip(float2 g, float aspect) {
    return float2(g.x / aspect * 2.0 - 1.0, 1.0 - g.y * 2.0);
}

// ───────────────────────── fullscreen ─────────────────────────

struct FSOut {
    float4 position [[position]];
    float2 uv;
};

vertex FSOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    FSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

// ───────────────────────── 1. scene ─────────────────────────

float3 proceduralStreet(float2 g, float aspect, float4 P) {
    float vanish = P.x;
    float horizon = P.y;
    float warmth = P.z;
    float sk = P.w;
    float y = g.y;
    float xn = g.x / aspect;
    float side = saturate(abs(xn - vanish) / max(vanish, 1.0 - vanish));

    // sky: blue-black with city haze at the horizon (sodium-warm or LED-cool)
    float3 hazeColor = mix(float3(0.020, 0.028, 0.050), float3(0.060, 0.030, 0.012), warmth);
    float haze = exp(-abs(y - horizon) * 7.0);
    float3 col = mix(float3(0.004, 0.006, 0.012), float3(0.010, 0.010, 0.016), y);
    col += hazeColor * haze;

    // out-of-focus building masses, taller away from the vanishing point
    float skyline = horizon - (0.06 + 0.42 * side * side) * (0.7 + 0.6 * fbm(float2(g.x * 1.7 + sk, 2.3), 3));
    float building = smoothstep(skyline - 0.05, skyline + 0.05, y) * (1.0 - smoothstep(horizon, horizon + 0.12, y));
    float3 facade = float3(0.010, 0.009, 0.010)
                  + hazeColor * 0.75 * pow(fbm(g * float2(2.5, 1.8) + 4.0 + sk, 3), 3.0);
    col = mix(col, facade, building * 0.9);

    // wet asphalt reflecting the haze in soft vertical streaks
    float road = smoothstep(horizon - 0.01, horizon + 0.10, y);
    float streak = fbm(float2(g.x * 4.0 + sk, y * 0.6 + 1.0), 3);
    float3 asphalt = float3(0.012, 0.011, 0.012)
                   + hazeColor * haze * 1.5
                   + hazeColor * 0.5 * streak * (1.0 - side * 0.5) * exp(-(y - horizon) * 2.0);
    return mix(col, asphalt, road);
}

float3 photoSample(texture2d<float> photo, sampler s, float2 uv, float viewAspect, float photoAspect) {
    float2 p = uv - 0.5;
    if (viewAspect > photoAspect) p.y *= photoAspect / viewAspect;
    else                          p.x *= viewAspect / photoAspect;
    return photo.sample(s, p + 0.5).rgb;
}

fragment float4 sceneFragment(FSOut in [[stage_in]],
                              constant Uniforms& U [[buffer(0)]],
                              texture2d<float> photo [[texture(0)]],
                              sampler s [[sampler(0)]]) {
    float aspect = U.a.x;
    float2 uvS = (in.uv - 0.5) / U.k.w + 0.5 + U.f.xy;   // parallax: far street
    float2 g = float2(uvS.x * aspect, uvS.y);
    float3 col = U.c.y > 0.5
        ? photoSample(photo, s, uvS, aspect, U.c.x) * U.c.z
        : proceduralStreet(g, aspect, U.e);
    return float4(col, 1.0);
}

// ───────────────────────── bokeh ─────────────────────────

struct BokehVOut {
    float4 position [[position]];
    float2 local;
    float3 color;
    float intensity;
    float2 catDir;
    float seed;
};

vertex BokehVOut bokehVertex(uint vid [[vertex_id]],
                             uint iid [[instance_id]],
                             const device BokehInstance* inst [[buffer(0)]],
                             constant Uniforms& U [[buffer(1)]]) {
    BokehInstance b = inst[iid];
    float aspect = U.a.x;
    float2 corner = kQuad[vid] * 1.15;
    float2 g = b.a.xy + U.f.zw + corner * b.a.z;           // parallax: lights
    BokehVOut o;
    o.position = float4(glassToClip(g, aspect), 0.0, 1.0);
    o.local = corner;
    o.color = b.b.rgb;
    o.intensity = b.a.w;
    o.seed = b.b.w;
    o.catDir = (b.a.xy - float2(aspect * 0.5, 0.5)) / float2(aspect * 0.5, 0.5);
    return o;
}

// Distance to a rounded polygonal aperture (1.0 = edge).
float apertureDist(float2 p, float blades, float rot, float roundness) {
    float r = length(p);
    float seg = 2.0 * M_PI_F / blades;
    float a = atan2(p.y, p.x) + rot + 64.0 * M_PI_F;
    float local = fmod(a, seg) - 0.5 * seg;
    float poly = r * cos(0.5 * seg) / cos(local);
    return mix(poly, r, roundness);
}

fragment float4 bokehFragment(BokehVOut in [[stage_in]]) {
    float2 p = in.local;
    float cat = length(in.catDir);
    float2 cdir = cat > 1e-3 ? in.catDir / cat : float2(0.0);
    float catAmt = smoothstep(0.35, 1.3, cat) * 0.55;     // mechanical vignetting → cat's-eye
    float rot = in.seed * 6.2831;
    const float3 chroma = float3(1.012, 1.0, 0.986);      // lateral chromatic fringe

    float3 col = float3(0.0);
    for (int c = 0; c < 3; c++) {
        float2 q = p * chroma[c];
        float d1 = apertureDist(q, 7.0, rot, 0.65);
        float d2 = length(q + cdir * catAmt);
        float d = max(d1, d2);
        float body = 1.0 - smoothstep(0.965, 1.035, d);
        float rim = smoothstep(0.55, 0.97, d) * 0.55;               // brighter outline (spherical aberration)
        float rings = 1.0 + 0.035 * sin(d * 38.0 + in.seed * 20.0); // "onion rings" of aspheric optics
        float dust = 0.93 + 0.07 * vnoise(q * 9.0 + in.seed * 50.0);
        col[c] = body * (0.72 + rim) * rings * dust;
    }
    return float4(col * in.color * in.intensity, 1.0);
}

// ───────────────────────── 3. water height field ─────────────────────────

struct DropVOut {
    float4 position [[position]];
    float2 local;
    float r;
    float stretch;
};

vertex DropVOut dropVertex(uint vid [[vertex_id]],
                           uint iid [[instance_id]],
                           const device DropInstance* inst [[buffer(0)]],
                           constant Uniforms& U [[buffer(1)]]) {
    DropInstance d = inst[iid];
    float aspect = U.a.x;
    float r = max(d.a.z, 1e-5);
    float st = d.a.w;
    float2 c = kQuad[vid];
    const float ext = 1.65;
    float2 local = float2(c.x * ext * 1.1,
                          c.y < 0.0 ? c.y * ext * st * 1.15 : c.y * ext * (1.0 + (st - 1.0) * 0.3));
    float2 g = d.a.xy + local * r;
    DropVOut o;
    o.position = float4(glassToClip(g, aspect), 0.0, 1.0);
    o.local = local;
    o.r = r;
    o.stretch = st;
    return o;
}

// Metaball kernel: surface of a lone drop sits exactly at value 1.0.
fragment float4 dropFragment(DropVOut in [[stage_in]]) {
    float2 p = in.local;
    float st = in.stretch;
    float py = p.y < 0.0 ? p.y / st : p.y / (1.0 + (st - 1.0) * 0.3); // tail above, round front below
    float taper = 1.0 + max(-py, 0.0) * (st - 1.0) * 0.6;
    float px = p.x * taper;
    float d2 = (px * px + py * py) / (1.6 * 1.6);
    if (d2 >= 1.0) discard_fragment();
    float k = 1.0 - d2;
    float b = k * k * k / 0.2267;
    return float4(b, b * in.r, 0.0, 0.0);
}

// ───────────────────────── 4. condensation memory ─────────────────────────

fragment float4 fogFragment(FSOut in [[stage_in]],
                            constant Uniforms& U [[buffer(0)]],
                            texture2d<float> prevFog [[texture(0)]],
                            texture2d<float> water [[texture(1)]],
                            sampler s [[sampler(0)]]) {
    float2 uv = in.uv;
    float aspect = U.a.x;
    float2 g = float2(uv.x * aspect, uv.y);
    float dt = U.a.z;

    // condensation is uneven: patches, and heavier towards the bottom of the pane
    float maxFog = mix(0.55, 1.0, smoothstep(0.25, 0.75, fbm(g * 1.3 + 7.3, 4)));
    maxFog *= mix(0.85, 1.0, uv.y);

    float2 prev = prevFog.sample(s, uv).rg;
    float fog = prev.r;
    float wet = prev.g;
    if (U.a.w > 0.5) {
        fog = maxFog * (0.85 + 0.15 * vnoise(g * 20.0));
        wet = 0.0;
    }

    float w = water.sample(s, uv).r;

    // re-fogging: exponential approach, slower where the glass is still wet
    float rate = mix(0.6, 1.4, fbm(g * 2.7 + 3.1, 3)) * (1.0 - wet * 0.85);
    fog += (maxFog - fog) * (1.0 - exp(-dt * rate / U.d.x));

    // water (and the halo around it) wipes condensation away
    fog *= 1.0 - smoothstep(0.3, 0.95, w);
    wet = max(wet * exp(-dt / U.d.y), smoothstep(0.5, 1.0, w));

    return float4(saturate(fog), saturate(wet), 0.0, 1.0);
}

// ───────────────────────── 5. composite ─────────────────────────

struct Bead { float2 n; float mask; };

// Tiny droplets: condensation beads on the fog, or residue left in fresh trails.
Bead microDrop(float2 g, float scale, float seed, float aspect, float wetMode,
               texture2d<float> fogT, sampler s) {
    float2 p = g * scale;
    float2 id = floor(p);
    float2 f = fract(p) - 0.5;
    float3 h = hash32(id + seed);
    float rad = mix(0.12, 0.34, h.z * h.z);
    float2 c = (h.xy - 0.5) * (1.0 - 2.0 * rad);
    float2 cg = (id + 0.5 + c) / scale;
    float2 fw = fogT.sample(s, float2(cg.x / aspect, cg.y), level(0.0)).rg;
    float presence = wetMode > 0.5 ? fw.g * (1.0 - fw.r) : smoothstep(0.25, 0.8, fw.r);
    float exists = step(hash12(id * 1.37 + seed + 3.3), presence * 0.8);
    float2 d = (f - c) / rad;
    float l = length(d);
    float aa = fwidth(l) + 1e-4;
    Bead b;
    b.mask = (1.0 - smoothstep(1.0 - aa, 1.0 + aa, l)) * exists;
    b.n = d * 0.85;
    return b;
}

float3 shadeBead(float3 base, Bead b, float2 uv, float2 toUV, float strength,
                 texture2d<float> scene, sampler s) {
    if (b.mask <= 0.0) return base;
    float nz = sqrt(saturate(1.0 - dot(b.n, b.n)));
    float edge = 1.0 - nz;
    float3 col = scene.sample(s, uv - b.n * toUV * 0.02, level(0.0)).rgb;
    col *= 1.0 - smoothstep(0.25, 0.85, edge) * 0.85;
    return mix(base, col * 1.05, b.mask * strength);
}

fragment float4 compositeFragment(FSOut in [[stage_in]],
                                  constant Uniforms& U [[buffer(0)]],
                                  texture2d<float> scene [[texture(0)]],
                                  texture2d<float> blurT [[texture(1)]],
                                  texture2d<float> water [[texture(2)]],
                                  texture2d<float> fogT  [[texture(3)]],
                                  sampler s [[sampler(0)]]) {
    float2 uv = in.uv;                                   // screen: the scene behind the glass
    float2 uvG = (uv - 0.5) / U.k.z + 0.5 + U.k.xy;      // parallax: the pane, nearest layer
    float aspect = U.a.x;
    float t = U.a.y;
    float2 g = float2(uvG.x * aspect, uvG.y);
    float2 toUV = float2(1.0 / aspect, 1.0);
    float2 wt = 1.0 / U.b.zw;

    // ── water surface from the metaball field
    float2 w0 = water.sample(s, uvG).rg;
    float hL = water.sample(s, uvG - float2(wt.x, 0.0)).r;
    float hR = water.sample(s, uvG + float2(wt.x, 0.0)).r;
    float hU = water.sample(s, uvG - float2(0.0, wt.y)).r;
    float hD = water.sample(s, uvG + float2(0.0, wt.y)).r;
    float2 grad = float2((hR - hL) / (2.0 * wt.x * aspect), (hD - hU) / (2.0 * wt.y));
    float h = w0.r;
    float rLocal = w0.g / max(w0.r, 1e-4);
    float aa = max(fwidth(h), 1e-3) * 0.8;
    float dropMask = smoothstep(1.0 - aa, 1.0 + aa, h);
    float3 n = normalize(float3(-grad * rLocal * 0.5, 1.0));

    // ── glass: clear / wet film / condensation
    float2 fw = fogT.sample(s, uvG).rg;
    float wet = fw.g;
    float smudge = fbm(g * 4.0 + 11.0, 5);
    float fog = saturate(fw.r * U.d.z * (0.78 + 0.35 * smudge));

    float2 film = (float2(vnoise(g * 55.0), vnoise(g * 55.0 + 5.2)) - 0.5) * 0.005 * wet * toUV;
    float3 clearCol = scene.sample(s, uv + film).rgb * (1.0 - 0.15 * wet);

    float3 blurCol = blurT.sample(s, uv).rgb;
    float lum = dot(blurCol, float3(0.2126, 0.7152, 0.0722));
    float3 fogCol = blurCol * 0.8 + lum * 0.12 + float3(0.008, 0.010, 0.013); // milky scatter
    float3 glass = mix(clearCol, fogCol, fog);

    Bead b1 = microDrop(g,  90.0,  0.0, aspect, 0.0, fogT, s);
    Bead b2 = microDrop(g, 160.0, 13.7, aspect, 0.0, fogT, s);
    Bead b3 = microDrop(g, 210.0, 41.3, aspect, 1.0, fogT, s);
    glass = shadeBead(glass, b1, uv, toUV, 0.9, scene, s);
    glass = shadeBead(glass, b2, uv, toUV, 0.7, scene, s);
    glass = shadeBead(glass, b3, uv, toUV, 0.8, scene, s);

    // ── drops: each is a tiny inverted lens showing the sharp street
    float2 refr = uv - n.xy * toUV * (U.c.w + rLocal * 2.0);
    float3 dropCol = scene.sample(s, refr).rgb * 1.08;
    float edge = 1.0 - n.z;
    dropCol *= 1.0 - smoothstep(0.18, 0.7, edge) * 0.88;            // dark rim (total internal reflection)
    float3 L = normalize(float3(-0.35, -0.75, 0.55));
    float spec = pow(saturate(dot(n, L)), 140.0);
    dropCol += spec * (0.03 + lum * 0.8);
    float lower = saturate(n.y * 1.5) * smoothstep(0.12, 0.45, edge) * (1.0 - smoothstep(0.5, 0.8, edge));
    dropCol += lower * blurCol * 0.7;                                // back-light gathered at the lower edge

    float3 col = mix(glass, dropCol, dropMask);

    // ── camera
    col = aces(col * 1.1);
    float2 vc = (uv - 0.5) * float2(aspect, 1.0) / max(aspect, 1.0);
    col *= 1.0 - smoothstep(0.25, 0.85, length(vc)) * 0.45;
    float grain = hash12(in.position.xy + fract(t * 7.13) * 1000.0) - 0.5;
    col = max(col + grain * 0.004, 0.0);
    return float4(col, 1.0);
}
