#include <metal_stdlib>
using namespace metal;

struct VertexIn { float3 position [[attribute(0)]]; float3 normal [[attribute(1)]]; };

struct FrameUniforms {
    float4x4 viewProj;            // rasterisation matrix (carries the MetalFX jitter when upscaling)
    float4x4 lightViewProj;       // near sun cascade (court)
    float4x4 lightViewProj2;      // far sun cascade (stadium bowl + roof)
    float4x4 viewProjUnjit;       // current frame, no jitter
    float4x4 prevViewProj;        // previous frame, no jitter (for motion vectors)
    float4 lightDirTime;          // xyz = sun direction, w = time (s)
    float4 camPosCheer;           // xyz = camera position, w = crowd excitement 0…1
    float4 ballPosPrevTime;       // xyz = ball position, w = previous-frame time
    float4 renderSizeJitter;      // xy = render size (px), zw = texel jitter (uv units)
    float4 misc;                  // x = second cascade enabled
};
// params: x = material, y = specular strength, z = roughness, w = part id (athlete material)
struct DrawUniforms { float4x4 model; float4x4 prevModel; float4 color; float4 accent; float4 params; };
struct Spectator { float4 posYaw; float4 shirt; float4 misc; };   // xyz pos, w yaw | rgb shirt, a scale | x phase, y excite, z skin, w hair

struct VOut {
    float4 position [[position]];
    float3 normal;
    float4 color;
    float4 accent;
    float3 world;
    float4 params;
    float4 currClip;
    float4 prevClip;
    float3 objPos;
    float4 extra [[flat]];      // discrete ids (region / per-instance seeds): never interpolated
    float3 tangent;
    float4 masks;               // smooth per-vertex masks (lips, flush, brow, thin)
};

enum Material { Plain = 0, Court = 1, Grass = 2, Seats = 3, Sky = 4, Net = 5, Emissive = 6, Person = 7, AdBoard = 8, Screen = 9,
                Athlete = 11, Ball = 12, Roof = 13, Skin = 14, Eye = 15, Hair = 16, Cloth = 17 };

vertex VOut vs_main(VertexIn in [[stage_in]],
                    constant FrameUniforms &f [[buffer(1)]],
                    constant DrawUniforms &d [[buffer(2)]]) {
    VOut o;
    float4 p = float4(in.position, 1);
    float4 w = d.model * p;
    o.position = f.viewProj * w;
    o.currClip = f.viewProjUnjit * w;
    o.prevClip = f.prevViewProj * (d.prevModel * p);
    o.normal = normalize((d.model * float4(in.normal, 0)).xyz);
    o.color = d.color;
    o.accent = d.accent;
    o.world = w.xyz;
    o.params = d.params;
    o.objPos = in.position;
    o.extra = float4(0);
    o.tangent = float3(0, 1, 0);
    o.masks = float4(0);
    return o;
}


// ---- Skinned athlete (GPU skinning + facial morph targets) -------------------------------------------------------
struct SkinVertex { packed_float3 pos; packed_float3 nrm; packed_float3 tan; uchar4 joints; uchar4 region; uchar4 masks; float4 weights; };

vertex VOut vs_skinned(uint vid [[vertex_id]],
                       const device SkinVertex *verts [[buffer(0)]],
                       constant FrameUniforms &f [[buffer(1)]],
                       constant DrawUniforms &d [[buffer(2)]],
                       constant float4x4 *bones [[buffer(4)]],
                       constant float4x4 *prevBones [[buffer(5)]],
                       constant float4 &morphW [[buffer(6)]],
                       const device float4 *morphs [[buffer(7)]]) {
    SkinVertex v = verts[vid];
    float3 p = v.pos;
    uint mc = uint(d.params.w);                                   // body only: vertex count addresses the morph blocks
    if (mc > 0 && (morphW.x + morphW.y + morphW.z) > 0.001)
        p += morphs[vid].xyz * morphW.x + morphs[mc + vid].xyz * morphW.y + morphs[2 * mc + vid].xyz * morphW.z;
    uchar4 j = v.joints; float4 w = v.weights;
    float4x4 M = bones[j.x] * w.x + bones[j.y] * w.y + bones[j.z] * w.z + bones[j.w] * w.w;
    float4x4 Mp = prevBones[j.x] * w.x + prevBones[j.y] * w.y + prevBones[j.z] * w.z + prevBones[j.w] * w.w;
    float4 wpos = d.model * (M * float4(p, 1));
    VOut o;
    o.position = f.viewProj * wpos;
    o.currClip = f.viewProjUnjit * wpos;
    o.prevClip = f.prevViewProj * (d.prevModel * (Mp * float4(p, 1)));
    o.normal = normalize((d.model * float4((M * float4(float3(v.nrm), 0)).xyz, 0)).xyz);
    o.tangent = normalize((d.model * float4((M * float4(float3(v.tan), 0)).xyz, 0)).xyz);
    o.color = d.color; o.accent = d.accent;
    o.world = wpos.xyz;
    o.params = d.params;
    o.objPos = float3(v.pos);
    o.extra = float4(float(v.region.x), 0, 0, 0);
    o.masks = float4(v.masks) / 255.0;
    return o;
}

// ---- Instanced crowd ----------------------------------------------------------------------------------------
static float hash11(float n) { return fract(sin(n * 127.1) * 43758.5453); }

// Animates a spectator vertex (object space) at time t: seat bob, cheering arm raise about the shoulders and
// head yaw toward the ball. Returns the world-space position.
static float3 animateSpectator(float3 p, float3 n, Spectator s, float t, float cheer, float3 ball, thread float3 &nOut) {
    float phase = s.misc.x, excite = s.misc.y;
    float c = cheer * excite;
    float3 q = p;
    float3 nn = n;
    bool isArm = fabs(p.x) > 0.19 && p.y < 0.52;
    bool isHead = p.y > 0.56;
    if (isArm) {
        float raise = c * (2.5 + 0.35 * sin(t * 9.0 + phase * 6.28)) + 0.06 * sin(t * 1.3 + phase * 9.0);
        float cs = cos(raise), sn = sin(raise);
        float3 d = float3(0, p.y - 0.47, p.z);
        // rotate (y,z) about the shoulder so the arm swings forward (-z) and up (same convention as rotationX)
        q.y = 0.47 + d.y * cs - d.z * sn;
        q.z = d.y * sn + d.z * cs;
        q.x += sign(p.x) * 0.06 * saturate(c * 2.0);                 // splay outward when cheering
        nn = float3(n.x, n.y * cs - n.z * sn, n.y * sn + n.z * cs);
    }
    if (isHead) {
        // look toward the ball (relative to facing), clamped
        float2 toBall = ball.xz - s.posYaw.xz;
        float yawToBall = atan2(-toBall.x, -toBall.y);                // 0 = looking along -z in object space
        float rel = yawToBall - s.posYaw.w;
        rel = atan2(sin(rel), cos(rel));
        float look = clamp(rel, -1.0, 1.0) * (0.55 + 0.4 * hash11(phase * 91.0)) + 0.12 * sin(t * 0.7 + phase * 20.0) * (1.0 - c);
        float cs = cos(look), sn = sin(look);
        float3 d = q - float3(0, 0.58, 0);
        q = float3(d.x * cs + d.z * sn, d.y, -d.x * sn + d.z * cs) + float3(0, 0.58, 0);
        nn = float3(nn.x * cs + nn.z * sn, nn.y, -nn.x * sn + nn.z * cs);
    }
    float bob = 0.008 * sin(t * (1.6 + excite * 1.4) + phase * 40.0) + c * 0.07 * max(0.0, sin(t * 8.0 + phase * 30.0));
    q.y += bob;
    // object -> world: scale, yaw about Y, translate
    float scale = s.shirt.a;
    float cy = cos(s.posYaw.w), sy = sin(s.posYaw.w);
    float3 r = float3(q.x * cy + q.z * sy, q.y, -q.x * sy + q.z * cy) * scale;
    nOut = float3(nn.x * cy + nn.z * sy, nn.y, -nn.x * sy + nn.z * cy);
    return r + s.posYaw.xyz;
}

vertex VOut vs_crowd(VertexIn in [[stage_in]], uint iid [[instance_id]],
                     constant FrameUniforms &f [[buffer(1)]],
                     const device Spectator *crowd [[buffer(3)]]) {
    Spectator s = crowd[iid];
    float3 n, nPrev;
    float3 w = animateSpectator(in.position, in.normal, s, f.lightDirTime.w, f.camPosCheer.w, f.ballPosPrevTime.xyz, n);
    float3 wPrev = animateSpectator(in.position, in.normal, s, f.ballPosPrevTime.w, f.camPosCheer.w, f.ballPosPrevTime.xyz, nPrev);
    VOut o;
    o.position = f.viewProj * float4(w, 1);
    o.currClip = f.viewProjUnjit * float4(w, 1);
    o.prevClip = f.prevViewProj * float4(wPrev, 1);
    o.normal = normalize(n);
    o.color = float4(s.shirt.rgb, 1);
    o.accent = float4(1);
    o.world = w;
    o.params = float4(Person, 0.04, 0.8, 0);
    o.objPos = in.position;
    o.extra = float4(s.misc.z, s.misc.w, s.misc.x, 0);
    o.tangent = float3(0, 1, 0);
    o.masks = float4(0);
    return o;
}

// ---- Procedural helpers --------------------------------------------------------------------------------------
static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}
static float vnoise(float2 p) {
    float2 i = floor(p), fr = fract(p);
    fr = fr * fr * (3 - 2 * fr);
    return mix(mix(hash21(i), hash21(i + float2(1, 0)), fr.x),
               mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), fr.x), fr.y);
}
static float fbm(float2 p) {
    float a = 0.5, s = 0;
    for (int i = 0; i < 5; i++) { s += a * vnoise(p); p = p * 2.03 + 11.7; a *= 0.5; }
    return s;
}
static float3 aces(float3 x) { return saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14)); }

// Procedural sky radiance for a direction (also used as the environment for reflections).
static float3 skyRadiance(float3 d, float3 sunDir) {
    float h = saturate(d.y);
    float3 horizon = float3(0.62, 0.74, 0.92), zenith = float3(0.10, 0.28, 0.72);
    float3 c = mix(horizon, zenith, pow(h, 0.55));
    float sunAmt = saturate(dot(d, -sunDir));
    c += float3(1.0, 0.8, 0.6) * pow(sunAmt, 12.0) * 0.18;
    return c;
}

// PBR terms (GGX / Smith / Schlick).
static float D_GGX(float NoH, float a) { float a2 = a * a; float d = NoH * NoH * (a2 - 1) + 1; return a2 / (M_PI_F * d * d + 1e-5); }
static float V_Smith(float NoV, float NoL, float a) { float k = a * 0.5; return 0.25 / ((NoV * (1 - k) + k) * (NoL * (1 - k) + k) + 1e-5); }
static float3 F_Schlick(float3 f0, float VoH) { return f0 + (1 - f0) * pow(1 - VoH, 5.0); }

static float sampleCascade(depth2d<float> map, float3 world, float4x4 vp, float ndl, thread bool &inside, float biasScale) {
    constexpr sampler s(coord::normalized, address::clamp_to_border, border_color::opaque_white,
                        filter::linear, compare_func::less_equal);
    float4 lp = vp * float4(world, 1);
    float3 p = lp.xyz / lp.w;
    float2 uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
    inside = all(uv > 0.02) && all(uv < 0.98) && p.z < 1.0;
    float texel = 1.0 / float(map.get_width());
    float bias = (0.0006 + 0.002 * (1 - ndl)) * biasScale;
    // 12-tap rotated golden-angle disc: soft penumbra, noise hidden by MSAA / the composite
    float rot = fract(52.9829189 * fract(dot(world.xz * 37.0 + world.y * 11.0, float2(0.06711056, 0.00583715)))) * 6.2831853;
    float sum = 0;
    for (int i = 0; i < 12; i++) {
        float r = sqrt((float(i) + 0.5) / 12.0) * 2.6, a = rot + float(i) * 2.399963;
        sum += map.sample_compare(s, uv + float2(cos(a), sin(a)) * r * texel, p.z - bias);
    }
    return sum / 12.0;
}
static float shadowTerm(depth2d<float> near, depth2d<float> far, float3 world, constant FrameUniforms &f, float ndl) {
    bool inside;
    float s0 = sampleCascade(near, world, f.lightViewProj, ndl, inside, 1.0);
    if (inside || f.misc.x < 0.5) return s0;
    bool inside2;
    float s1 = sampleCascade(far, world, f.lightViewProj2, ndl, inside2, 6.0);
    return inside2 ? s1 : 1.0;
}

// Procedural eyes/brows/mouth for the athlete head (object space: neck base at origin, face toward -z).
static float3 faceAlbedo(float3 p, float3 skin, float3 hair) {
    float3 c = skin;
    if (p.z < -0.045) {
        for (int side = -1; side <= 1; side += 2) {
            float2 e = float2(p.x - 0.038 * side, p.y - 0.232);
            float r = length(e * float2(1.0, 1.25));
            if (r < 0.0175) c = mix(float3(0.92, 0.92, 0.9), c, smoothstep(0.014, 0.0175, r));   // sclera
            if (r < 0.0095) c = mix(float3(0.22, 0.13, 0.07), c, smoothstep(0.0085, 0.0095, r)); // iris
            if (r < 0.0045) c = float3(0.02);                                                     // pupil
            float brow = step(fabs(p.y - 0.262 - 0.01 * fabs(p.x) * 4.0), 0.0045) * step(fabs(p.x - 0.040 * side), 0.026);
            c = mix(c, hair * 0.7, brow);
        }
        float mouth = step(fabs(p.y - 0.163), 0.0035) * step(fabs(p.x), 0.024 - 4.0 * (p.y - 0.163) * (p.y - 0.163) * 100.0);
        c = mix(c, float3(0.50, 0.15, 0.15), mouth);
    }
    return c;
}

// Per-part colouring for the Blender-authored athlete: collars, cuffs, socks, soles, stripes, string bed.
static float3 athleteAlbedo(int part, float3 p, float3 base, float3 accent, float3 skin, float3 hair, thread float &rough, thread float &specMul) {
    float3 white = float3(0.92);
    switch (part) {
        case 10: {                                   // torso (shirt)
            float collar = smoothstep(0.545, 0.56, p.y) * step(p.z, 0.0);
            float logo = step(fabs(p.x + 0.07), 0.035) * step(fabs(p.y - 0.40), 0.014) * step(p.z, -0.05);
            float3 c = mix(base, accent, saturate(collar + logo));
            rough = 0.85; return c * (0.96 + 0.04 * vnoise(p.xy * 90.0));
        }
        case 11: rough = 0.55; return faceAlbedo(p, skin, hair);                       // head
        case 12: {                                   // hair + headband
            float band = step(fabs(p.y - 0.225), 0.014);
            rough = 0.7; return mix(hair * (0.85 + 0.3 * vnoise(p.xz * 120.0)), accent, band);
        }
        case 13: { float cuff = step(p.y, -0.215); rough = 0.85; return mix(base, accent, cuff); }       // sleeve
        case 14: { float band = step(fabs(p.y + 0.215), 0.025); rough = 0.55; return mix(skin, white, band); } // forearm + wristband
        case 15: rough = 0.55; return skin;                                            // thigh
        case 16: { float sock = smoothstep(-0.27, -0.26, p.y) < 0.5 ? 1.0 : 0.0; rough = 0.8; return mix(skin, white, sock); }
        case 17: {                                   // shoe: white upper, dark sole, accent toe stripe
            float sole = step(p.y, -0.062);
            float stripe = step(fabs(p.z + 0.12), 0.012) * (1 - sole);
            rough = 0.45; return mix(mix(white, accent, stripe), float3(0.08), sole);
        }
        case 18: {                                   // shorts: accent waistband + side stripe
            float waist = smoothstep(0.03, 0.04, p.y);
            float side = step(0.17, fabs(p.x)) * step(fabs(p.z), 0.08);
            rough = 0.8; return mix(base, accent, saturate(waist + side));
        }
        case 19: rough = 0.55; return skin;                                            // hand
        case 20: rough = 0.22; specMul = 6.0; return float3(0.05);                     // racket frame
        case 21: rough = 0.5; return float3(0.08);                                     // racket handle
        case 22: {                                   // string bed: fine grid
            float2 g = fract(p.yz * 90.0);
            float line = step(g.x, 0.12) + step(g.y, 0.12);
            rough = 0.6; return mix(float3(0.88, 0.92, 0.80), float3(0.55, 0.60, 0.50), saturate(line));
        }
    }
    return base;
}

// Shared lighting: returns linear HDR colour (fog included, no tone mapping).
static float3 shade(VOut in, constant FrameUniforms &f, depth2d<float> shadowMap, depth2d<float> shadowFar,
                    texture2d<float> board, texture2d<float> ads) {
    int mat = int(in.params.x + 0.5);
    float3 V = f.camPosCheer.xyz - in.world;
    float dist = length(V); V /= dist;
    float3 sunDir = f.lightDirTime.xyz;
    float time = f.lightDirTime.w;

    if (mat == Sky) {
        float3 d = normalize(in.world - f.camPosCheer.xyz);
        float3 c = skyRadiance(d, sunDir);
        // drifting cumulus on a projected plane, lit by the sun
        float2 cuv = d.xz / (d.y + 0.18) * 1.6 + float2(time * 0.012, time * 0.004);
        float cl = smoothstep(0.50, 0.85, fbm(cuv));
        cl *= smoothstep(0.0, 0.18, d.y);
        float sunAmt = saturate(dot(d, -sunDir));
        float3 cloudCol = mix(float3(0.80, 0.84, 0.92), float3(1.25, 1.15, 1.0), pow(sunAmt, 3.0));
        c = mix(c, cloudCol, cl * 0.85);
        c += float3(1.0, 0.9, 0.7) * pow(sunAmt, 400.0) * 12.0;      // sun disc (HDR → blooms)
        return c;
    }

    if (mat == Screen) {
        // LED scoreboard: text texture (CoreText) mapped by world position on the +z face, with scanlines and a soft glow.
        constexpr sampler bs(filter::linear, address::clamp_to_edge);
        float2 uv = float2((in.world.x + 5.0) / 10.0, 1.0 - (in.world.y - 4.3) / 2.4);
        float3 t = board.sample(bs, saturate(uv)).rgb;
        float scan = 0.85 + 0.15 * sin(in.position.y * 3.14159);
        float edge = step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0);
        return mix(float3(0.01, 0.015, 0.03), pow(t, 2.2) * 5.0 * scan, edge);
    }

    float3 albedo = pow(in.color.rgb, 2.2);
    float spec = in.params.y;
    float rough = clamp(in.params.z, 0.08, 1.0);
    float3 N = normalize(in.normal);
    float ao = 1.0;
    float wrapSkin = 0.0;
    float thin = 0.0, aniso = 0.0;
    float3 hairT = float3(0, 1, 0);

    if (mat == Court) {
        int surf = int(in.accent.w + 0.5);                       // 0 hard acrylic, 1 clay, 2 grass
        float fw = length(fwidth(in.world.xz));
        float fine = 1.0 - smoothstep(0.004, 0.02, fw);
        if (surf == 5) {
            // bounce mark: a round scuff / worn dot (hard-edged disc on a flat box, dithered rim)
            float r = length(in.objPos.xz) * 2.0;
            if (r > 1.0 - 0.25 * hash21(in.position.xy)) discard_fragment();
            albedo *= 0.95 + 0.1 * vnoise(in.world.xz * 90.0); rough = 0.95;
        } else if (surf == 3) {
            // painted / taped court line: slightly dusty, with hairline wear
            float n = mix(0.5, vnoise(in.world.xz * 60.0), fine);
            float scuff = vnoise(in.world.xz * 3.0 + 7.0);
            albedo *= 0.86 + 0.14 * n - 0.10 * smoothstep(0.55, 0.9, scuff);
            rough = 0.72;
        } else if (surf == 1) {
            // clay: coarse sandy grain, scuffed patches near the baselines, matte
            float g = mix(0.5, vnoise(in.world.xz * 70.0), fine) * 0.6 + vnoise(in.world.xz * 9.0) * 0.4;
            float scuff = vnoise(in.world.xz * 1.6 + 3.0);
            float wear = smoothstep(9.0, 11.8, fabs(in.world.z)) * 0.5;
            albedo *= 0.82 + 0.3 * g + 0.12 * (scuff - 0.5) + wear * 0.12;
            albedo = mix(albedo, float3(0.62, 0.56, 0.50) * albedo.r * 1.1, wear * (0.4 + 0.6 * scuff) * 0.3);
            float2 q = in.world.xz * 90.0;
            N = normalize(N + float3(vnoise(q) - 0.5, 0, vnoise(q + 5.3) - 0.5) * 0.18 * fine);
            rough = 0.92;
        } else if (surf == 2) {
            // grass: mowing stripes, blade grain, worn dirt at the baselines
            float stripes = step(0.5, fract(in.world.x * 0.35));
            float blades = mix(0.5, vnoise(in.world.xz * 120.0), fine) * 0.5 + vnoise(in.world.xz * 30.0) * 0.5;
            float az = fabs(in.world.z);
            float wear = smoothstep(10.6, 12.2, az) * (1.0 - smoothstep(12.6, 13.6, az)) * smoothstep(0.5, 0.85, vnoise(in.world.xz * 2.4)) * (1.0 - smoothstep(4.5, 7.0, fabs(in.world.x)));
            albedo *= 0.78 + 0.34 * blades + 0.12 * stripes;
            albedo = mix(albedo, float3(0.26, 0.22, 0.12), wear * 0.5);
            float2 q = in.world.xz * 60.0;
            N = normalize(N + float3(vnoise(q) - 0.5, 0, vnoise(q + 9.1) - 0.5) * 0.3 * fine);
            rough = 0.95;
        } else {
            float g = mix(0.5, vnoise(in.world.xz * 90.0), fine) * 0.5 + vnoise(in.world.xz * 22.0) * 0.5;
            float patches = vnoise(in.world.xz * 0.7);
            albedo *= 0.88 + 0.22 * g + 0.06 * (patches - 0.5);
            float2 q = in.world.xz * 140.0;
            float2 gr = float2(vnoise(q + float2(0.7, 0)) - vnoise(q - float2(0.7, 0)), vnoise(q + float2(0, 0.7)) - vnoise(q - float2(0, 0.7)));
            N = normalize(N + float3(gr.x, 0, gr.y) * 0.12 * fine);
            rough = mix(0.42, 0.62, vnoise(in.world.xz * 3.0));
        }
    } else if (mat == Grass) {
        float g = vnoise(in.world.xz * 40.0) * 0.5 + vnoise(in.world.xz * 6.0) * 0.5;
        float stripes = step(0.5, fract(in.world.z * 0.18));
        albedo *= 0.75 + 0.35 * g + 0.10 * stripes;
        float2 q = in.world.xz * 25.0;
        N = normalize(N + float3(vnoise(q) - 0.5, 0, vnoise(q + 9.1) - 0.5) * 0.35);
    } else if (mat == Seats) {
        // rows of seat backs along the tier + a darker gap between them
        float row = fract((in.world.x + in.world.z) * 1.8);
        float3 seatCol = mix(float3(0.10, 0.12, 0.30), float3(0.30, 0.07, 0.08), step(0.5, hash21(floor(in.world.xz * 0.45))));
        if (N.y > 0.5) albedo = mix(albedo, seatCol, 0.8) * (0.55 + 0.45 * smoothstep(0.0, 0.25, row) * (1.0 - smoothstep(0.75, 1.0, row)));
        ao = 0.75 + 0.25 * smoothstep(0.0, 0.3, fract(in.world.y));
    } else if (mat == Person) {
        float skinSeed = in.extra.x, hairSeed = in.extra.y;
        float3 skin = mix(float3(0.95, 0.76, 0.62), float3(0.36, 0.22, 0.15), skinSeed);
        float3 hairs[5] = { float3(0.04, 0.03, 0.03), float3(0.25, 0.14, 0.06), float3(0.55, 0.38, 0.14), float3(0.65, 0.65, 0.65), float3(0.35, 0.10, 0.06) };
        float3 hair = hairs[min(int(hairSeed * 5.0), 4)];
        float y = in.objPos.y;
        bool arm = fabs(in.objPos.x) > 0.19 && y < 0.52;
        float3 skinL = pow(skin, 2.2);
        if (y > 0.56) albedo = (y > 0.74 || (y > 0.66 && in.objPos.z > 0.02)) ? pow(hair, 2.2) : skinL;
        else if (arm && y < 0.18) albedo = skinL;                    // hands/forearms bare
        ao = 0.55 + 0.45 * saturate(y / 0.5 + 0.2);                  // darker toward the seat
    } else if (mat == AdBoard) {
        // LED ribbon board: sponsor strip scrolls along the board, emissive (HDR → bloom)
        constexpr sampler as(filter::linear, address::repeat);
        // text reads left-to-right as seen from the court: viewer's right = (-N) × up
        float3 rightDir = cross(-N, float3(0, 1, 0));
        float along = dot(in.world, rightDir);
        float u = along / 20.0 + time * 0.035;
        float v = 1.0 - saturate(in.world.y / 1.1);
        float3 t = ads.sample(as, float2(u, v)).rgb;
        float face = step(0.6, fabs(N.x) + fabs(N.z));
        return mix(albedo * 0.08, pow(t, 2.2) * 2.6, face * step(in.world.y, 1.08));
    } else if (mat == Net) {
        float2 uv = in.world.xy * 9.0;
        float2 g = fract(uv);
        float2 w = fwidth(uv) * 1.5;                       // keep lines at least ~1.5px wide to avoid moire
        float2 lw = max(float2(0.10), w);
        if (g.x > lw.x && g.y > lw.y) discard_fragment();
        rough = 0.9;
    } else if (mat == Athlete) {
        float3 skin = float3(0.80, 0.58, 0.44);
        float specMul = 1.0;
        float3 hair = in.color.rgb * 0.0 + float3(0.08, 0.06, 0.05);
        int part = int(in.params.w + 0.5);
        float3 baseL = in.color.rgb, accL = in.accent.rgb;
        if (part == 12) hair = baseL;                                   // hair mesh carries its own colour
        float r = rough;
        float3 c = athleteAlbedo(part, in.objPos, baseL, accL, skin, hair, r, specMul);
        albedo = pow(c, 2.2); rough = r; spec *= specMul;
        if (part == 11 || part == 14 || part == 15 || part == 16 || part == 19) wrapSkin = 1.0;
    } else if (mat == Ball) {
        // felt: optic yellow with the white seam curve
        float3 p = normalize(in.objPos);
        float seam = smoothstep(0.075, 0.05, fabs(sin(p.x * 3.0 + p.y * 2.0) * 0.5 + p.z * 0.5 - 0.0)) * 0.6 + 0.0;
        albedo = mix(albedo, float3(0.9), seam * 0.8);
        albedo *= 0.92 + 0.12 * vnoise(in.objPos.xy * 220.0);
        rough = 0.9;
    } else if (mat == Skin) {
        int region = int(in.extra.x + 0.5);
        float lips = in.masks.x, flush = in.masks.y, browM = in.masks.z;
        thin = in.masks.w;
        float3 sk = pow(in.color.rgb, 2.2);
        float3 p = in.objPos;
        float pores = vnoise(p.xy * 700.0 + p.z * 300.0) * 0.5 + vnoise(p.yz * 900.0) * 0.5;      // object-space: no texture swim
        float mottling = vnoise(p.xy * 38.0 + p.z * 21.0);
        albedo = sk * (0.93 + 0.10 * pores + 0.06 * (mottling - 0.5));
        albedo = mix(albedo, albedo * float3(1.10, 0.76, 0.72), saturate(flush));                  // blood flow: cheeks, nose, ears, hands, knees
        albedo = mix(albedo, pow(float3(0.60, 0.27, 0.29), 2.2), saturate(lips) * 0.85);           // lips
        albedo *= 1.0 - 0.38 * saturate(browM);                                                    // brow shadow
        if (region == 5) albedo = float3(0.04, 0.008, 0.008);                                      // mouth line
        rough = mix(mix(0.40, 0.58, pores), 0.33, saturate(lips));
        spec = 0.05 + ((p.y > 1.78 && p.y < 1.88 && fabs(p.x) < 0.035) ? 0.03 : 0.0);             // oily T-zone
        wrapSkin = 1.0;
    } else if (mat == Eye) {
        float3 c0 = float3(in.objPos.x > 0 ? 0.0335 : -0.0335, 1.834, -0.0775);
        float3 dl = normalize(in.objPos - c0);
        float r = acos(clamp(-dl.z, -1.0, 1.0));                                                   // angle from the optical axis
        float ang = atan2(dl.y, dl.x);
        float3 iris = pow(in.color.rgb, 2.2);
        float fibers = 0.65 + 0.35 * vnoise(float2(ang * 7.0, r * 46.0));
        float3 irisCol = iris * fibers * mix(0.5, 1.15, smoothstep(0.12, 0.42, r));
        float3 sclera = mix(float3(0.80, 0.78, 0.76), float3(0.78, 0.50, 0.46), smoothstep(0.7, 1.4, r) * vnoise(float2(ang * 9.0, r * 12.0)));
        albedo = mix(sclera, irisCol, smoothstep(0.54, 0.49, r));
        albedo = mix(albedo, albedo * 0.35, smoothstep(0.44, 0.50, r) * smoothstep(0.56, 0.50, r));  // limbal ring
        albedo = mix(albedo, float3(0.005), smoothstep(0.20, 0.165, r));                           // pupil
        rough = 0.07; spec = 0.04;
        ao = mix(0.30, 1.0, smoothstep(-0.30, 0.55, 0.45 - dl.y));                                 // upper-lid shadow
    } else if (mat == Hair) {
        int region = int(in.extra.x + 0.5);
        float3 base = pow(in.color.rgb, 2.2);
        float h = hash21(floor(in.objPos.xz * 380.0) + floor(in.objPos.y * 190.0));
        albedo = base * (0.65 + 0.7 * h);
        if (region == 21) albedo *= 0.8;                                                           // eyebrows
        if (region == 22) albedo = float3(0.012);                                                  // eyelashes
        float3 hc = float3(0.0, 1.835, 0.01);
        float t = length((in.objPos - hc) / float3(0.0795, 0.0975, 0.0995));
        ao = mix(0.30, 1.0, smoothstep(1.0, 1.45, t));                                             // darker toward the scalp
        rough = 0.5; spec = 0.03; aniso = 1.0; hairT = normalize(in.tangent);
    } else if (mat == Cloth) {
        int region = int(in.extra.x + 0.5), ct = int(in.accent.w + 0.5);        // ct: 0 shirt, 1 shorts, 2 socks, 3 shoes, 4 bands
        float3 main = pow(in.color.rgb, 2.2), acc = pow(float3(in.accent.rgb), 2.2);
        float3 p = in.objPos;
        float weave = 0.93 + 0.07 * sin(p.x * 1100.0) * sin(p.y * 1100.0 + p.z * 300.0);
        if (ct == 0 || ct == 1) albedo = (region == 1) ? main : acc;
        else if (ct == 2) albedo = float3(0.88) * (0.92 + 0.08 * sin(p.y * 900.0));
        else if (ct == 3) {
            float mesh = 0.9 + 0.1 * step(0.5, fract(p.x * 260.0)) * step(0.5, fract(p.z * 260.0));
            albedo = region == 2 ? float3(0.05) : (region == 3 ? acc : float3(0.86) * mesh);
        } else albedo = acc;
        albedo *= weave;
        rough = (ct == 3 && region == 2) ? 0.7 : 0.88; spec = 0.03;
    } else if (mat == Roof) {
        float panel = step(0.5, fract(in.world.x * 0.25)) * 0.12 + step(0.5, fract(in.world.z * 0.25)) * 0.12;
        albedo *= 0.85 + panel;
        rough = 0.5;
    }

    float3 L = -sunDir;
    float ndlRaw = dot(N, L);
    float ndl = saturate(ndlRaw);
    float sh = (ndl > 0 || wrapSkin > 0) ? shadowTerm(shadowMap, shadowFar, in.world, f, max(ndl, 0.2)) : 0;
    float3 sunCol = float3(1.0, 0.93, 0.80) * 3.0;
    // hemispheric ambient from the procedural sky and a warm bounce from the ground
    float3 skyAmb = skyRadiance(normalize(float3(N.x * 0.6, 0.8, N.z * 0.6)), sunDir) * 0.62;
    float3 groundBounce = float3(0.20, 0.19, 0.15) * (0.8 + 0.4 * saturate(dot(in.world.xz, in.world.xz) / 4000.0));
    float3 ambient = mix(groundBounce, skyAmb, N.y * 0.5 + 0.5) * 0.9;
    float diffuseTerm = ndl;
    if (wrapSkin > 0) diffuseTerm = saturate((ndlRaw + 0.45) / 1.45);   // soft skin terminator
    float3 skinTint = wrapSkin > 0 ? mix(float3(1.0), float3(1.0, 0.55, 0.42), saturate(1.0 - ndl) * 0.5) : float3(1.0);
    float3 col = albedo * (ambient * ao + sunCol * diffuseTerm * sh * skinTint);

    // Specular: GGX direct + sky/ground reflection (Fresnel weighted)
    float NoV = saturate(dot(N, V));
    float metallic = spec >= 0.4 ? 1.0 : 0.0;
    float3 f0 = mix(float3(0.02 + spec * 0.5), albedo * 0.9 + 0.08, metallic);
    float a = rough * rough;
    float3 H = normalize(L + V);
    float NoH = saturate(dot(N, H)), VoH = saturate(dot(V, H));
    float3 F = F_Schlick(f0, VoH);
    float3 direct = sunCol * D_GGX(NoH, a) * V_Smith(NoV, max(ndl, 1e-3), a) * F * ndl * sh;
    float3 R = reflect(-V, N);
    float3 envSky = skyRadiance(float3(R.x, max(R.y, 0.0), R.z), sunDir);
    float3 envGround = float3(0.10, 0.20, 0.14) * 0.6;
    float3 env = R.y > 0 ? envSky : envGround;
    float3 Fenv = F_Schlick(f0, NoV) * (1.0 - rough * 0.85);
    float envVis = saturate(0.35 + 0.65 * (N.y * 0.5 + 0.5)) * ao;
    col += direct + env * Fenv * envVis * (mat == Court ? 0.8 : 0.5);
    // soft rim from the sky: lifts silhouettes of people and the ball
    col += albedo * float3(0.30, 0.42, 0.65) * pow(1.0 - NoV, 3.0) * 0.25 * ((mat == Person || mat == Athlete || mat == Ball) ? 1.0 : 0.3);

    // Hair: Kajiya-Kay anisotropic highlights (primary white lobe + shifted tinted lobe)
    if (aniso > 0.5) {
        float3 T1 = normalize(hairT + N * 0.05), T2 = normalize(hairT + N * 0.35);
        float s1 = pow(sqrt(saturate(1.0 - pow(dot(T1, H), 2.0))), 110.0);
        float s2 = pow(sqrt(saturate(1.0 - pow(dot(T2, H), 2.0))), 28.0);
        col += sunCol * (s1 * 0.10 + s2 * 0.10 * albedo * 3.0) * sh * saturate(ndl * 2.0 + 0.15);
    }
    // Skin transmission: thin regions (ears, fingers) glow warmly when lit from behind
    if (thin > 0) col += albedo * float3(1.0, 0.32, 0.18) * thin * saturate(dot(-N, L)) * sunCol * 0.5 * sh;
    // Subtle subsurface bleed on all skin: red-shifted fill in the shadowed side
    if (wrapSkin > 0) col += albedo * float3(0.55, 0.14, 0.08) * (1.0 - ndl) * 0.10 * ao;

    if (mat == Emissive) col = pow(in.color.rgb, 2.2) * 6.0;      // HDR: floodlights and screens bloom

    if (mat == Person && in.objPos.y > 0.48) {                     // camera flashes popping in the stands
        float seed = in.extra.z * 131.0 + in.extra.x * 17.0;
        float slot = floor(time * 5.0 + seed);
        float fl = step(0.9985, hash21(float2(seed, slot))) * smoothstep(0.0, 0.2, fract(time * 5.0 + seed)) * (1.0 - smoothstep(0.2, 0.45, fract(time * 5.0 + seed)));
        col += float3(1.0, 0.97, 0.9) * fl * 14.0;
    }
    float fog = 1 - exp(-dist * 0.0016);
    return mix(col, float3(0.55, 0.68, 0.88), saturate(fog));
}

// Classic path: tone-mapped LDR straight to the (sRGB) drawable.
fragment float4 fs_main(VOut in [[stage_in]], constant FrameUniforms &f [[buffer(1)]],
                        depth2d<float> shadowMap [[texture(0)]], texture2d<float> board [[texture(1)]],
                        depth2d<float> shadowFar [[texture(2)]], texture2d<float> ads [[texture(3)]]) {
    return float4(aces(shade(in, f, shadowMap, shadowFar, board, ads)), 1);
}

// Metal 4 path: linear HDR + motion vectors for MetalFX temporal upscaling.
struct HDROut { half4 color [[color(0)]]; half2 motion [[color(1)]]; };
fragment HDROut fs_hdr(VOut in [[stage_in]], constant FrameUniforms &f [[buffer(1)]],
                       depth2d<float> shadowMap [[texture(0)]], texture2d<float> board [[texture(1)]],
                       depth2d<float> shadowFar [[texture(2)]], texture2d<float> ads [[texture(3)]]) {
    HDROut o;
    o.color = half4(half3(min(shade(in, f, shadowMap, shadowFar, board, ads), float3(60000.0))), 1);
    // Motion = previous uv − current uv, both without jitter (see Apple's MetalFX TAA sample).
    float2 uv = in.position.xy / f.renderSizeJitter.xy - f.renderSizeJitter.zw;
    float2 prevUV = in.prevClip.xy / in.prevClip.w * float2(0.5, -0.5) + 0.5;
    o.motion = half2(prevUV - uv);
    return o;
}

// ---- Post-processing (Metal 4 path) ---------------------------------------------------------------------------
struct PostVOut { float4 position [[position]]; float2 uv; };
vertex PostVOut vs_fullscreen(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    PostVOut o; o.position = float4(p * 2 - 1, 0, 1); o.uv = float2(p.x, 1 - p.y);
    return o;
}
struct PostParams {
    float4 a;   // texel.xy, threshold, knee
    float4 b;   // bloomStrength, exposure, vignette, time
    float4 c;   // focusDist, aperture, motionScale, maxBlurPx
    float4 d;   // renderSize.xy, depthA, depthB
    float4 e;   // P00, P11, aoStrength, sharpen
};

static float linearDepth(float depth, constant PostParams &p) { return p.d.w / (depth + p.d.z); }
static float3 viewPos(float2 uv, float d, constant PostParams &p) {
    float2 ndc = float2(uv.x * 2 - 1, 1 - uv.y * 2);
    return float3(ndc.x * d / p.e.x, ndc.y * d / p.e.y, -d);
}
static float ign(float2 px, float frame) { return fract(52.9829189 * fract(dot(px + frame * 5.588238, float2(0.06711056, 0.00583715)))); }

// Screen-space ambient occlusion (half render resolution): normal-oriented hemisphere samples against the depth buffer.
fragment half fs_ssao(PostVOut in [[stage_in]], depth2d<float> depth [[texture(0)]], constant PostParams &p [[buffer(0)]]) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    float2 px = 1.0 / p.d.xy;
    float d0 = linearDepth(depth.sample(s, in.uv), p);
    if (d0 > 300.0) return 1.0h;
    float3 P = viewPos(in.uv, d0, p);
    float3 pR = viewPos(in.uv + float2(px.x, 0), linearDepth(depth.sample(s, in.uv + float2(px.x, 0)), p), p);
    float3 pL = viewPos(in.uv - float2(px.x, 0), linearDepth(depth.sample(s, in.uv - float2(px.x, 0)), p), p);
    float3 pD = viewPos(in.uv + float2(0, px.y), linearDepth(depth.sample(s, in.uv + float2(0, px.y)), p), p);
    float3 pU = viewPos(in.uv - float2(0, px.y), linearDepth(depth.sample(s, in.uv - float2(0, px.y)), p), p);
    float3 dx = fabs(pR.z - P.z) < fabs(pL.z - P.z) ? pR - P : P - pL;
    float3 dy = fabs(pD.z - P.z) < fabs(pU.z - P.z) ? pD - P : P - pU;
    float3 N = normalize(-cross(dx, dy));
    if (N.z < 0) N = -N;
    float angle = ign(in.position.xy, p.b.w) * 6.2831853;
    float3 rvec = float3(cos(angle), sin(angle), 0);
    float3 T = normalize(rvec - N * dot(rvec, N));
    float3 B = cross(N, T);
    const float radius = 0.9;
    float occ = 0;
    for (int i = 0; i < 12; i++) {
        float fi = float(i);
        float3 k = float3(cos(fi * 2.399963) * sqrt((fi + 0.5) / 12.0), sin(fi * 2.399963) * sqrt((fi + 0.5) / 12.0), 0);
        k.z = sqrt(max(0.0, 1.0 - dot(k.xy, k.xy)));
        k *= mix(0.15, 1.0, (fi + 1.0) / 12.0);
        float3 S = P + (T * k.x + B * k.y + N * k.z) * radius;
        float2 suv = float2((S.x * p.e.x / -S.z) * 0.5 + 0.5, 0.5 - (S.y * p.e.y / -S.z) * 0.5);
        float ds = linearDepth(depth.sample(s, suv), p);
        float range = smoothstep(0.0, 1.0, radius / max(fabs(d0 - ds), 1e-3));
        occ += (ds < -S.z - 0.04 ? 1.0 : 0.0) * range;
    }
    return half(1.0 - occ / 12.0);
}
// Depth-aware 5×5 blur of the AO.
fragment half fs_ssao_blur(PostVOut in [[stage_in]], texture2d<float> ao [[texture(0)]], depth2d<float> depth [[texture(1)]],
                           constant PostParams &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    constexpr sampler sd(filter::nearest, address::clamp_to_edge);
    float2 texel = p.a.xy;
    float d0 = linearDepth(depth.sample(sd, in.uv), p);
    float sum = 0, wsum = 0;
    for (int y = -2; y <= 2; y++) for (int x = -2; x <= 2; x++) {
        float2 uv = in.uv + float2(x, y) * texel;
        float dd = linearDepth(depth.sample(sd, uv), p);
        float w = exp(-fabs(dd - d0) * 2.0 / max(d0 * 0.05, 0.05));
        sum += ao.sample(s, uv).r * w; wsum += w;
    }
    return half(sum / max(wsum, 1e-4));
}

// First bloom level: soft-threshold the HDR image while downsampling 2×.
fragment half4 fs_bloom_prefilter(PostVOut in [[stage_in]], texture2d<float> src [[texture(0)]], constant PostParams &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 sum = 0;
    for (int i = 0; i < 4; i++) {
        float2 o = float2(i & 1, i >> 1) * 2.0 - 1.0;
        float3 c = src.sample(s, in.uv + o * 0.5 * p.a.xy).rgb;
        float br = max(c.r, max(c.g, c.b));
        float soft = clamp(br - p.a.z + p.a.w, 0.0, 2.0 * p.a.w);
        soft = soft * soft / (4.0 * p.a.w + 1e-4);
        c *= max(soft, br - p.a.z) / max(br, 1e-4);
        sum += c;
    }
    return half4(half3(sum * 0.25), 1);
}
// Subsequent levels: 3×3 tent-filtered downsample.
fragment half4 fs_bloom_down(PostVOut in [[stage_in]], texture2d<float> src [[texture(0)]], constant PostParams &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = 0; float wsum = 0;
    for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
        float w = (2 - abs(x)) * (2 - abs(y));
        c += src.sample(s, in.uv + float2(x, y) * p.a.xy).rgb * w; wsum += w;
    }
    return half4(half3(c / wsum), 1);
}

// Composite: depth of field (gather) with stochastic per-tap motion blur, sharpen, bloom, SSAO, grade, tone map, vignette.
fragment float4 fs_composite(PostVOut in [[stage_in]], texture2d<float> scene [[texture(0)]],
                             texture2d<float> b1 [[texture(1)]], texture2d<float> b2 [[texture(2)]],
                             texture2d<float> b3 [[texture(3)]], texture2d<float> b4 [[texture(4)]],
                             depth2d<float> depth [[texture(5)]], texture2d<float> motion [[texture(6)]],
                             texture2d<float> aoTex [[texture(7)]],
                             constant PostParams &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    constexpr sampler sn(filter::nearest, address::clamp_to_edge);
    float2 outSize = float2(scene.get_width(), scene.get_height());
    float2 uv = in.uv;
    float d0 = linearDepth(depth.sample(sn, uv), p);

    // circle of confusion (pixels): sharp at the focus distance, softer in the distance, gentler in front
    float focus = p.c.x, aperture = p.c.y, maxBlur = p.c.w * outSize.y / 1080.0;
    auto cocOf = [&](float dd) {
        float rel = (dd - focus) / max(dd, 0.5);
        float amt = rel > 0 ? rel * aperture : -rel * aperture * 0.5;
        return clamp(amt, 0.0, 1.0) * maxBlur;
    };
    float coc0 = cocOf(d0);
    float2 vel = motion.sample(s, uv).rg * outSize * p.c.z;            // pixels over the shutter interval
    float vlen = length(vel);
    if (vlen > 24.0) vel *= 24.0 / vlen;

    float3 acc = scene.sample(s, uv).rgb;
    float wsum = 1.0;
    const int taps = 14;
    float rot = ign(in.position.xy, p.b.w) * 6.2831853;
    for (int i = 0; i < taps; i++) {
        float fi = (float(i) + 0.5) / float(taps);
        float r = sqrt(fi), a = rot + float(i) * 2.399963;
        float2 disc = float2(cos(a), sin(a)) * r * coc0;               // bokeh disc
        float2 mb = vel * (ign(in.position.xy + float(i) * 7.0, p.b.w) - 0.5);   // motion streak
        float2 off = (disc + mb) / outSize;
        float2 tuv = uv + off;
        float dt = linearDepth(depth.sample(sn, tuv), p);
        float cocT = cocOf(dt);
        // a tap contributes if its own blur reaches the centre (prevents sharp foreground bleeding into blur)
        float reach = length(disc) + 0.5;
        float w = saturate((max(cocT, coc0 * 0.5) - reach) * 0.5 + 1.0) * (dt < d0 - 1.0 ? saturate(cocT / max(coc0, 0.5)) : 1.0);
        acc += scene.sample(s, tuv).rgb * w; wsum += w;
    }
    float3 c = acc / wsum;
    // sharpen where in focus (TAA/upscaling leaves a slight softness)
    float3 nb = (scene.sample(s, uv + float2(1, 0) / outSize).rgb + scene.sample(s, uv - float2(1, 0) / outSize).rgb +
                 scene.sample(s, uv + float2(0, 1) / outSize).rgb + scene.sample(s, uv - float2(0, 1) / outSize).rgb) * 0.25;
    float focusMask = 1.0 - saturate(coc0 / 2.0);
    c += clamp(scene.sample(s, uv).rgb - nb, -0.5, 0.5) * p.e.w * focusMask;

    // ambient occlusion (multiplies indirect + direct; keeps the sky untouched)
    float ao = aoTex.sample(s, uv).r;
    c *= mix(1.0, ao, p.e.z * (d0 < 300.0 ? 1.0 : 0.0));

    float3 bloom = b1.sample(s, uv).rgb * 0.30 + b2.sample(s, uv).rgb * 0.30
                 + b3.sample(s, uv).rgb * 0.25 + b4.sample(s, uv).rgb * 0.25;
    c += bloom * p.b.x;
    c *= p.b.y;
    // gentle colour grade: slight warm highlights / cool shadows, a touch of saturation and contrast
    float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
    c = mix(float3(luma), c, 1.12);
    c = mix(c, c * float3(1.05, 1.0, 0.94), smoothstep(0.4, 1.5, luma));
    c = mix(c, c * float3(0.96, 1.0, 1.06), 1.0 - smoothstep(0.0, 0.4, luma));
    c = aces(c);
    c = pow(c, 1.04);                                                  // slightly deeper blacks
    // vignette + fine grain (dither also hides 8-bit banding in the sky)
    float2 q = uv - 0.5;
    c *= 1.0 - p.b.z * smoothstep(0.25, 0.85, dot(q, q) * 1.6);
    c += (hash21(in.position.xy + fract(p.b.w) * 71.0) - 0.5) * (2.2 / 255.0);
    return float4(c, 1);
}
