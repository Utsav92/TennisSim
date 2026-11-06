"""
Procedural, anatomy-based tennis athlete (body + face + hair + clothing) for TennisSim.
Run:  Blender --background --python Tools/blender/make_athlete.py -- <out_dir> [preview_dir]

Pipeline: muscle groups (ellipsoids / tapered capsules) -> voxel-remesh union -> smooth -> eye-socket / mouth boolean carve ->
numpy post-processing: smooth-skin weights from bone segments, region ids (lips, brows, ears…), clothing shells derived from the
body surface, hair + eyebrow + eyelash ribbons, facial morph targets -> binary "HUM1" file the game loads.
Conventions: +Y up, character faces -Z, right hand +X, metres, ground at y = 0. Arms are modelled in an A-pose (ARM_ANGLE).
"""
import bpy, bmesh, math, os, sys, json, struct, random
import numpy as np, time
from mathutils import Vector, Matrix, Euler

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = argv[0] if argv else "athlete_out"
PREVIEW = argv[1] if len(argv) > 1 else None
os.makedirs(OUT, exist_ok=True)
random.seed(7); np.random.seed(7)
ARM_ANGLE = math.radians(18)
VOXEL = float(os.environ.get('VOXEL', 0.0075))
T0 = time.time()
def log(msg): print(f"[{time.time() - T0:6.1f}s] {msg}", flush=True)

# ----------------------------------------------------------------------------------------------------------- primitives
def _sphere(bm, seg=20, rings=12):
    try: return bmesh.ops.create_uvsphere(bm, u_segments=seg, v_segments=rings, radius=1.0)
    except TypeError: return bmesh.ops.create_uvsphere(bm, u_segments=seg, v_segments=rings, diameter=1.0)

def add_ellipsoid(bm, c, r, rot=(0, 0, 0), seg=20, rings=12):
    new = _sphere(bm, seg, rings)['verts']
    m = Matrix.Translation(Vector(c)) @ Euler(rot, 'XYZ').to_matrix().to_4x4() @ Matrix.Diagonal(Vector((r[0], r[1], r[2], 1)))
    bmesh.ops.transform(bm, matrix=m, verts=new)

def add_capsule(bm, a, b, ra, rb, seg=14):
    a, b = Vector(a), Vector(b)
    d = b - a; L = d.length
    new = bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=seg, radius1=ra, radius2=rb, depth=L)['verts']
    rot = Vector((0, 0, 1)).rotation_difference(d.normalized()).to_matrix().to_4x4()
    bmesh.ops.transform(bm, matrix=Matrix.Translation((a + b) / 2) @ rot, verts=new)
    add_ellipsoid(bm, a, (ra, ra, ra), seg=seg, rings=8); add_ellipsoid(bm, b, (rb, rb, rb), seg=seg, rings=8)

def mirror(p): return (-p[0], p[1], p[2])

# ----------------------------------------------------------------------------------------------------------- skeleton (rest, A-pose)
S_R = Vector((0.235, 1.52, 0.0))
armdir = Vector((math.sin(ARM_ANGLE), -math.cos(ARM_ANGLE), 0.0))
E_R = S_R + armdir * 0.30
W_R = E_R + armdir * 0.27
H_R = W_R + armdir * 0.10
def mir(v): return Vector((-v.x, v.y, v.z))
HIP_R = Vector((0.095, 0.96, 0.0)); KNEE_R = Vector((0.095, 0.51, 0.008)); ANK_R = Vector((0.095, 0.085, 0.01)); TOE_R = Vector((0.095, 0.04, -0.16))
BONES = [  # name, segment A, segment B, joint pivot (rest), straighten rotZ (radians; rotates the rest limb to hang straight)
    ("hips", Vector((0, 0.90, 0)), Vector((0, 1.00, 0)), Vector((0, 0.98, 0)), 0),
    ("spine", Vector((0, 1.00, 0)), Vector((0, 1.52, 0)), Vector((0, 0.98, 0)), 0),
    ("head", Vector((0, 1.62, 0)), Vector((0, 1.90, 0)), Vector((0, 1.60, 0)), 0),
    ("uarmR", S_R, E_R, S_R, -ARM_ANGLE), ("farmR", E_R, W_R, E_R, -ARM_ANGLE), ("handR", W_R, H_R, W_R, -ARM_ANGLE),
    ("uarmL", mir(S_R), mir(E_R), mir(S_R), ARM_ANGLE), ("farmL", mir(E_R), mir(W_R), mir(E_R), ARM_ANGLE), ("handL", mir(W_R), mir(H_R), mir(W_R), ARM_ANGLE),
    ("thighR", HIP_R, KNEE_R, HIP_R, 0), ("calfR", KNEE_R, ANK_R, KNEE_R, 0), ("footR", ANK_R, TOE_R, ANK_R, 0),
    ("thighL", mir(HIP_R), mir(KNEE_R), mir(HIP_R), 0), ("calfL", mir(KNEE_R), mir(ANK_R), mir(KNEE_R), 0), ("footL", mir(ANK_R), mir(TOE_R), mir(ANK_R), 0),
]
EYE_C = Vector((0.0335, 1.834, -0.0775)); EYE_R = 0.0122
BONES += [("eyeR", EYE_C, EYE_C, EYE_C, 0), ("eyeL", mir(EYE_C), mir(EYE_C), mir(EYE_C), 0)]
NB = len(BONES)

# ----------------------------------------------------------------------------------------------------------- body (muscle groups)
body = bmesh.new()
def pair(fn, *args, **kw):
    """Build a symmetric pair: fn(bm, *args) then the x-mirrored version."""
    fn(body, *args, **kw)
    margs = [mirror(a) if (isinstance(a, tuple) and len(a) == 3 and not kw.get('nomirror')) else a for a in args]
    # rotations (Euler) must be mirrored differently: flip y and z rotation signs
    if fn is add_ellipsoid and len(args) > 2:
        margs[2] = (args[2][0], -args[2][1], -args[2][2])
    fn(body, *margs, **kw)

# torso
add_ellipsoid(body, (0, 1.37, 0.0), (0.150, 0.195, 0.100))                       # ribcage
add_ellipsoid(body, (0, 1.14, -0.008), (0.122, 0.145, 0.090))                    # abdomen
add_ellipsoid(body, (0, 0.995, 0.0), (0.150, 0.105, 0.100))                      # pelvis
for sx in (-1, 1):
    add_ellipsoid(body, (0.086 * sx, 1.405, -0.070), (0.088, 0.060, 0.034), rot=(0.15, 0.0, 0.25 * -sx))   # pectorals
    add_ellipsoid(body, (0.115 * sx, 1.33, 0.03), (0.062, 0.150, 0.066))         # lats / back
    add_ellipsoid(body, (0.092 * sx, 1.555, 0.025), (0.095, 0.050, 0.062), rot=(0.0, 0.0, 0.5 * -sx))      # trapezius
    add_ellipsoid(body, (0.125 * sx, 1.14, -0.02), (0.045, 0.105, 0.072))        # obliques
    add_ellipsoid(body, (0.072 * sx, 0.925, 0.062), (0.072, 0.078, 0.072))       # glutes
    add_ellipsoid(body, (0.252 * sx, 1.495, 0.0), (0.050, 0.068, 0.056))         # deltoid
    add_ellipsoid(body, (0.247 * sx, 1.512, -0.024), (0.034, 0.042, 0.032))      # front delt
    for i in range(3):                                                           # abs
        add_ellipsoid(body, (0.034 * sx, 1.215 - 0.052 * i, -0.090), (0.030, 0.025, 0.011))
    add_capsule(body, (0.047 * sx, 1.585, -0.012), (0.020 * sx, 1.505, -0.040), 0.017, 0.013)   # sternocleidomastoid
add_capsule(body, (0, 1.545, 0.012), (0, 1.700, -0.004), 0.060, 0.052)           # neck
# arms (right then mirrored)
for sgn in (1, -1):
    S = S_R if sgn == 1 else mir(S_R); E = E_R if sgn == 1 else mir(E_R); W = W_R if sgn == 1 else mir(W_R)
    d = armdir if sgn == 1 else Vector((-armdir.x, armdir.y, armdir.z))
    add_capsule(body, S, E, 0.050, 0.041)                                        # upper arm
    add_ellipsoid(body, S + d * 0.15 + Vector((0, 0, -0.026)), (0.039, 0.095, 0.038), rot=(0, 0, -ARM_ANGLE * sgn))   # biceps
    add_ellipsoid(body, S + d * 0.14 + Vector((0, 0, 0.030)), (0.037, 0.100, 0.037), rot=(0, 0, -ARM_ANGLE * sgn))    # triceps
    add_capsule(body, E, W, 0.040, 0.026)                                        # forearm
    add_ellipsoid(body, E + d * 0.07 + Vector((0, 0, -0.008)), (0.042, 0.085, 0.040), rot=(0, 0, -ARM_ANGLE * sgn))   # forearm muscle
    add_ellipsoid(body, W + d * 0.012, (0.027, 0.020, 0.027), rot=(0, 0, -ARM_ANGLE * sgn))                           # wrist
    if sgn == 1:   # right hand: closed fist around the racket grip
        add_ellipsoid(body, W + d * 0.058 + Vector((0, 0, -0.004)), (0.040, 0.050, 0.044), rot=(0, 0, -ARM_ANGLE))
        add_capsule(body, W + d * 0.03 + Vector((0.03, 0, -0.03)), W + d * 0.085 + Vector((0.02, 0, -0.05)), 0.012, 0.010)   # thumb
    else:          # left hand: relaxed open hand
        add_ellipsoid(body, W + d * 0.05, (0.038, 0.046, 0.017), rot=(0, 0, -ARM_ANGLE * sgn))
        for i, fx in enumerate((-0.026, -0.009, 0.009, 0.026)):
            base = W + d * 0.088 + Vector((fx, 0, 0)); tip = base + d * (0.058 - 0.004 * abs(i - 1.5)) + Vector((0, 0, -0.012))
            add_capsule(body, base, tip, 0.0085, 0.0068, seg=8)
        add_capsule(body, W + d * 0.035 + Vector((0.034, 0, -0.012)), W + d * 0.085 + Vector((0.046, 0, -0.03)), 0.011, 0.009, seg=8)
# legs
for sgn in (1, -1):
    H = HIP_R if sgn == 1 else mir(HIP_R); K = KNEE_R if sgn == 1 else mir(KNEE_R); A = ANK_R if sgn == 1 else mir(ANK_R)
    add_capsule(body, H, K, 0.086, 0.056)                                         # thigh
    add_ellipsoid(body, (0.103 * sgn, 0.74, -0.032), (0.066, 0.175, 0.062))     # quadriceps
    add_ellipsoid(body, (0.092 * sgn, 0.74, 0.040), (0.056, 0.170, 0.050))       # hamstrings
    add_ellipsoid(body, (0.138 * sgn, 0.72, -0.004), (0.040, 0.165, 0.046))      # vastus lateralis
    add_ellipsoid(body, (0.050 * sgn, 0.80, 0.0), (0.034, 0.140, 0.044))         # adductors
    add_ellipsoid(body, K + Vector((0, 0.0, -0.006)), (0.054, 0.056, 0.054))     # knee
    add_ellipsoid(body, K + Vector((0, 0.0, -0.040)), (0.030, 0.034, 0.016))     # kneecap
    add_capsule(body, K, A, 0.053, 0.031)                                         # lower leg
    add_ellipsoid(body, (0.082 * sgn, 0.385, 0.040), (0.036, 0.092, 0.042))      # gastrocnemius medial
    add_ellipsoid(body, (0.108 * sgn, 0.390, 0.036), (0.034, 0.088, 0.040))      # gastrocnemius lateral
    add_ellipsoid(body, (0.095 * sgn, 0.34, -0.024), (0.030, 0.150, 0.026))      # tibialis
    for off in (-0.028, 0.028):
        add_ellipsoid(body, (0.095 * sgn + off, 0.095, 0.006), (0.021, 0.021, 0.021))   # ankle bones
    add_ellipsoid(body, (0.095 * sgn, 0.047, -0.062), (0.040, 0.040, 0.105))      # foot
# head and face
HEAD_C = (0, 1.835, 0.010)
add_ellipsoid(body, HEAD_C, (0.078, 0.096, 0.098), seg=28, rings=18)                                      # cranium
add_ellipsoid(body, (0, 1.768, -0.030), (0.059, 0.066, 0.068), seg=24, rings=14)                           # lower face
add_ellipsoid(body, (0, 1.716, -0.066), (0.023, 0.020, 0.022))                                             # chin
add_ellipsoid(body, (0, 1.870, -0.080), (0.056, 0.046, 0.032))                                             # forehead
add_ellipsoid(body, (0, 1.862, -0.086), (0.062, 0.012, 0.017))                                             # brow ridge
for sx in (-1, 1):
    add_ellipsoid(body, (0.054 * sx, 1.748, 0.002), (0.019, 0.026, 0.034), rot=(0, 0.3 * sx, 0))             # mandible angle
    add_ellipsoid(body, (0.050 * sx, 1.800, -0.066), (0.019, 0.015, 0.016))                                 # cheekbone
    add_ellipsoid(body, (0.038 * sx, 1.774, -0.074), (0.018, 0.016, 0.012))                                 # cheek
    add_ellipsoid(body, (0.081 * sx, 1.812, 0.012), (0.009, 0.031, 0.021))                                  # ear
    add_ellipsoid(body, (0.084 * sx, 1.818, 0.008), (0.006, 0.027, 0.017))                                  # ear helix
    add_ellipsoid(body, (0.016 * sx, 1.792, -0.106), (0.012, 0.011, 0.011))                                 # nostril wing
    add_ellipsoid(body, (0.021 * sx, 1.751, -0.092), (0.012, 0.008, 0.012))                                 # mouth corner
add_capsule(body, (0, 1.848, -0.096), (0, 1.803, -0.114), 0.0105, 0.014, seg=10)                          # nose bridge
add_ellipsoid(body, (0, 1.792, -0.120), (0.014, 0.013, 0.014))                                             # nose tip
add_ellipsoid(body, (0, 1.753, -0.101), (0.027, 0.0075, 0.011))                                            # upper lip
add_ellipsoid(body, (0, 1.738, -0.099), (0.025, 0.0095, 0.012))                                            # lower lip

mesh = bpy.data.meshes.new("body_raw"); body.to_mesh(mesh); body.free()
ob = bpy.data.objects.new("body_raw", mesh); bpy.context.scene.collection.objects.link(ob)
bpy.context.view_layer.objects.active = ob; ob.select_set(True)
def apply_mod(ob, mod):
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.modifier_apply(modifier=mod.name)
log('primitives built'); rm = ob.modifiers.new("vox", 'REMESH'); rm.mode = 'VOXEL'; rm.voxel_size = VOXEL; rm.adaptivity = 0.0; apply_mod(ob, rm)
sm = ob.modifiers.new("smooth", 'SMOOTH'); sm.factor = 0.55; sm.iterations = 12; apply_mod(ob, sm)

log('voxel remesh + smooth done'); print('verts after remesh', len(ob.data.vertices), 'dims', tuple(round(v, 3) for v in ob.dimensions), 'voxel', VOXEL, flush=True)
if os.environ.get('STOP_AFTER_REMESH'): sys.exit(0)
# carve eye sockets (lid opening) with a boolean, then smooth the cut edge a little
def boolean_diff(target, cutters):
    for c in cutters:
        m = target.modifiers.new("bool", 'BOOLEAN'); m.operation = 'DIFFERENCE'; m.solver = 'MANIFOLD'; m.object = c
        apply_mod(target, m)
cutters = []
for sx in (-1, 1):
    bm = bmesh.new(); add_ellipsoid(bm, (0.0335 * sx, 1.834, -0.080), (0.0160, 0.0082, 0.019), seg=20, rings=12)
    m = bpy.data.meshes.new("cut"); bm.to_mesh(m); bm.free()
    o = bpy.data.objects.new("cut", m); bpy.context.scene.collection.objects.link(o); cutters.append(o)
bm = bmesh.new(); add_ellipsoid(bm, (0, 1.7455, -0.1005), (0.0215, 0.0016, 0.012), seg=20, rings=8)             # mouth line
m = bpy.data.meshes.new("cut"); bm.to_mesh(m); bm.free(); o = bpy.data.objects.new("cut", m); bpy.context.scene.collection.objects.link(o); cutters.append(o)
boolean_diff(ob, cutters)
sm = ob.modifiers.new("smooth2", 'SMOOTH'); sm.factor = 0.35; sm.iterations = 2; apply_mod(ob, sm)

# ----------------------------------------------------------------------------------------------------------- numpy mesh extraction
def to_numpy(obj):
    me = obj.data
    bm = bmesh.new(); bm.from_mesh(me); bmesh.ops.triangulate(bm, faces=bm.faces[:])
    bm.verts.ensure_lookup_table()
    V = np.array([v.co[:] for v in bm.verts], dtype=np.float32)
    F = np.array([[v.index for v in f.verts] for f in bm.faces], dtype=np.int64)
    bm.free()
    return V, F

def vertex_normals(V, F):
    fn = np.cross(V[F[:, 1]] - V[F[:, 0]], V[F[:, 2]] - V[F[:, 0]])
    N = np.zeros_like(V)
    for k in range(3): np.add.at(N, F[:, k], fn)
    n = np.linalg.norm(N, axis=1, keepdims=True); n[n == 0] = 1
    return (N / n).astype(np.float32)

log('boolean carve done'); V, F = to_numpy(ob)
log(f'body verts {len(V)} tris {len(F)}')
# normalise winding so normals face outward (check against centroid)
N0 = vertex_normals(V, F)
if np.mean(np.einsum('ij,ij->i', N0, V - V.mean(0))) < 0: F = F[:, ::-1].copy()
N = vertex_normals(V, F)

# ----------------------------------------------------------------------------------------------------------- skin weights
SEG_A = np.array([b[1][:] for b in BONES], dtype=np.float32); SEG_B = np.array([b[2][:] for b in BONES], dtype=np.float32)
def seg_dist(P, A, B):
    AB = B - A; L2 = np.maximum((AB * AB).sum(1), 1e-9)
    t = np.clip(((P[:, None, :] - A[None]) * AB[None]).sum(2) / L2[None], 0, 1)
    C = A[None] + t[..., None] * AB[None]
    return np.linalg.norm(P[:, None, :] - C, axis=2), t
def skin_weights(P, exclude_eyes=True):
    D, T = seg_dist(P, SEG_A, SEG_B)
    if exclude_eyes: D[:, NB - 2:] = 1e3
    # wider falloff where limbs meet the trunk gives smooth shoulders/hips/neck; tighter elsewhere
    dmin = D.min(1, keepdims=True)
    W = np.exp(-((D - dmin) / 0.028) ** 2)
    W[D > dmin + 0.12] = 0
    idx = np.argsort(-W, axis=1)[:, :4]
    w = np.take_along_axis(W, idx, 1); w = w / np.maximum(w.sum(1, keepdims=True), 1e-9)
    return idx.astype(np.uint8), w.astype(np.float32)

J, WT = skin_weights(V); log('skin weights done')
primary = J[:, 0]
names = [b[0] for b in BONES]; bid = {n: i for i, n in enumerate(names)}

# ----------------------------------------------------------------------------------------------------------- skin regions
REG = np.zeros(len(V), dtype=np.uint8)           # discrete: 5 = mouth line (everything else uses the smooth masks below)
x, y, z = V[:, 0], V[:, 1], V[:, 2]
ax = np.abs(x)
REG[(np.abs(y - 1.748) < 0.0035) & (ax < 0.022) & (z < -0.09)] = 5
def gauss(P, c, r): return np.exp(-(np.linalg.norm((P - np.array(c)) / np.array(r), axis=1)) ** 2)
def smooth01(a, b, v): t = np.clip((v - a) / (b - a), 0, 1); return t * t * (3 - 2 * t)
# smooth skin masks (0…1, packed as bytes): lips, flush (blood flow), brow shadow, thin/translucent
hand_w = np.where(np.isin(J, [bid["handR"], bid["handL"]]), WT, 0).sum(1)
M_LIPS = gauss(V, (0, 1.746, -0.098), (0.030, 0.0155, 0.022))
M_FLUSH = np.maximum.reduce([gauss(V, (0.040 * sx, 1.776, -0.074), (0.032, 0.030, 0.030)) for sx in (-1, 1)] +
                            [gauss(V, (0, 1.795, -0.115), (0.022, 0.020, 0.022))] +
                            [gauss(V, (0.082 * sx, 1.812, 0.010), (0.034, 0.036, 0.034)) for sx in (-1, 1)] +
                            [0.45 * hand_w, 0.35 * gauss(V, (0.095, 0.51, -0.04), (0.05, 0.05, 0.05)) + 0.35 * gauss(V, (-0.095, 0.51, -0.04), (0.05, 0.05, 0.05))])
M_BROW = np.clip(np.exp(-((y - 1.858) / 0.012) ** 2) * smooth01(0.012, 0.024, ax) * (z < -0.07) * (ax < 0.075), 0, 1)
M_THIN = np.maximum.reduce([gauss(V, (0.082 * sx, 1.812, 0.010), (0.030, 0.034, 0.030)) for sx in (-1, 1)] + [0.35 * hand_w])
MASKS = np.stack([M_LIPS, M_FLUSH, M_BROW, M_THIN], axis=1)
MASKS = np.clip(MASKS * 255, 0, 255).astype(np.uint8)

# ----------------------------------------------------------------------------------------------------------- morph targets (head)
def smoothstep(a, b, v): t = np.clip((v - a) / (b - a), 0, 1); return t * t * (3 - 2 * t)
head_mask = (y > 1.66) & (np.isin(primary, [bid["head"], bid["spine"]]))
M_BLINK = np.zeros_like(V); M_SMILE = np.zeros_like(V); M_EFFORT = np.zeros_like(V)
for sx in (-1, 1):
    ec = np.array([0.0335 * sx, 1.834, -0.080]); d = np.linalg.norm((V - ec) * np.array([1, 1.3, 0.6]), axis=1)
    fall = 1 - smoothstep(0.012, 0.032, d)
    upper = (y > 1.834 - 0.001)
    M_BLINK[:, 1] += np.where(head_mask & upper, -(y - 1.8295) * 0.97 * fall, 0)       # upper lid drops onto the lower lid
    M_BLINK[:, 1] += np.where(head_mask & ~upper, 0.0030 * fall, 0)                    # lower lid rises slightly
    M_BLINK[:, 2] += np.where(head_mask, -0.0012 * fall, 0)
    mc = np.array([0.0300 * sx, 1.746, -0.094]); dm = np.linalg.norm(V - mc, axis=1)
    f2 = 1 - smoothstep(0.008, 0.050, dm)
    M_SMILE[:, 1] += np.where(head_mask, 0.0060 * f2, 0); M_SMILE[:, 0] += np.where(head_mask, 0.0050 * sx * f2, 0)
    M_SMILE[:, 1] += np.where(head_mask & (y > 1.77) & (y < 1.82) & (ax > 0.03), 0.0025 * (1 - smoothstep(0.0, 0.05, np.abs(ax - 0.045))), 0)   # cheek lift
    bc = np.array([0.040 * sx, 1.860, -0.085]); db = np.linalg.norm(V - bc, axis=1); f3 = 1 - smoothstep(0.01, 0.045, db)
    M_EFFORT[:, 1] += np.where(head_mask, -0.0055 * f3, 0); M_EFFORT[:, 0] += np.where(head_mask, -0.0030 * sx * f3, 0)   # brow down + in
    M_EFFORT[:, 1] += np.where(head_mask, -0.0035 * f2, 0); M_EFFORT[:, 0] += np.where(head_mask, 0.0035 * sx * f2, 0)    # lips pulled back/down
    nc = np.array([0.016 * sx, 1.790, -0.106]); dn = np.linalg.norm(V - nc, axis=1); f4 = 1 - smoothstep(0.004, 0.022, dn)
    M_EFFORT[:, 0] += np.where(head_mask, 0.0035 * sx * f4, 0)                                                          # nostril flare
M_EFFORT[:, 0] += np.where(head_mask & (y < 1.76) & (ax > 0.05), 0.0025 * np.sign(x), 0)                               # jaw clench
MORPHS = [M_BLINK, M_SMILE, M_EFFORT]; MORPH_NAMES = ["blink", "smile", "effort"]

# ----------------------------------------------------------------------------------------------------------- derived shells (clothing)
def shell(mask_fn, offset, wrinkle=0.0, region_fn=None, seed=0):
    keep = mask_fn(V, J, WT, N)
    F2 = F[keep[F].all(1)]
    used = np.unique(F2); remap = -np.ones(len(V), dtype=np.int64); remap[used] = np.arange(len(used))
    P = V[used] + N[used] * offset
    if wrinkle:
        P = P + N[used] * (np.sin(P[:, 1] * 38 + P[:, 0] * 11) * np.sin(P[:, 2] * 29 + P[:, 1] * 7) * wrinkle)[:, None]
    Fn = remap[F2]
    Nn = vertex_normals(P, Fn)
    Jn, Wn = J[used], WT[used]
    R = region_fn(P, Jn) if region_fn else np.zeros(len(P), dtype=np.uint8)
    return P.astype(np.float32), Nn, Fn, Jn, Wn, R

def prim(J_, n): return np.isin(J_[:, 0], [bid[k] for k in n])
def uarm_t(P, side):   # distance along the upper arm from the shoulder
    S = S_R if side == 'R' else mir(S_R); d = armdir if side == 'R' else Vector((-armdir.x, armdir.y, armdir.z))
    return ((P - np.array(S[:])) * np.array(d[:])).sum(1)
def shirt_mask(P, J_, W_, N_):
    torso = prim(J_, ["spine", "hips"]) & (P[:, 1] > 1.04) & (P[:, 1] < 1.585)
    arms = (prim(J_, ["uarmR"]) & (uarm_t(P, 'R') < 0.17)) | (prim(J_, ["uarmL"]) & (uarm_t(P, 'L') < 0.17))
    return torso | arms
def shirt_region(P, J_):
    r = np.ones(len(P), dtype=np.uint8)
    r[(P[:, 1] > 1.565)] = 2                                                     # collar
    r[(P[:, 1] < 1.075)] = 2                                                     # hem
    for s in ('R', 'L'): r[(np.abs(P[:, 0]) > 0.25) & (uarm_t(P, s) > 0.145)] = 2   # sleeve cuff
    r[(np.abs(P[:, 0] + 0.07) < 0.035) & (np.abs(P[:, 1] - 1.40) < 0.016) & (P[:, 2] < -0.06)] = 3   # chest logo
    return r
def shorts_mask(P, J_, W_, N_):
    return prim(J_, ["hips", "thighR", "thighL", "spine"]) & (P[:, 1] > 0.62) & (P[:, 1] < 1.045) & ~((P[:, 1] > 1.0) & prim(J_, ["spine"]) & (np.abs(P[:, 0]) < 0.0))
def shorts_region(P, J_):
    r = np.ones(len(P), dtype=np.uint8); r[P[:, 1] > 1.005] = 2
    r[(np.abs(P[:, 0]) > 0.15) & (np.abs(P[:, 2]) < 0.07) & (P[:, 1] < 1.0)] = 3
    return r
def socks_mask(P, J_, W_, N_): return prim(J_, ["calfR", "calfL", "footR", "footL"]) & (P[:, 1] < 0.30)
def band_mask(P, J_, W_, N_):
    wrist = prim(J_, ["farmR", "farmL"]) & (np.abs(P[:, 1] - 0.99) < 0.11) & (np.linalg.norm(P - np.where(P[:, :1] > 0, np.array(W_R[:]), np.array(mir(W_R)[:])), axis=1) < 0.055)
    head = (P[:, 1] > 1.874) & (P[:, 1] < 1.898) & prim(J_, ["head"]) & ((P[:, 2] < 0.03) | (np.abs(P[:, 0]) > 0.05)) & (np.linalg.norm((P[:, [0, 2]] - np.array([0, 0.01])) / np.array([0.0795, 0.0995]), axis=1) > 0.80)
    return wrist | head

parts = {}
parts["shirt"] = shell(shirt_mask, 0.0065, 0.0016, shirt_region)
parts["shorts"] = shell(shorts_mask, 0.0085, 0.0014, shorts_region)
parts["socks"] = shell(socks_mask, 0.0035, 0.0, None)
parts["bands"] = shell(band_mask, 0.0085, 0.0, None)

# ----------------------------------------------------------------------------------------------------------- shoes (own mesh, bound to the feet)
shoe = bmesh.new()
for sgn in (1, -1):
    cx = 0.095 * sgn
    add_ellipsoid(shoe, (cx, 0.060, -0.058), (0.0475, 0.050, 0.125), seg=20, rings=12)       # upper
    add_ellipsoid(shoe, (cx, 0.040, -0.150), (0.042, 0.034, 0.062))                           # toe box
    add_ellipsoid(shoe, (cx, 0.012, -0.062), (0.050, 0.014, 0.140), seg=20, rings=10)         # sole
    add_ellipsoid(shoe, (cx, 0.105, 0.030), (0.036, 0.030, 0.040))                            # collar / heel counter
me = bpy.data.meshes.new("shoe"); shoe.to_mesh(me); shoe.free()
sob = bpy.data.objects.new("shoe", me); bpy.context.scene.collection.objects.link(sob)
r2 = sob.modifiers.new("vox", 'REMESH'); r2.mode = 'VOXEL'; r2.voxel_size = 0.0045; apply_mod(sob, r2)
s2 = sob.modifiers.new("sm", 'SMOOTH'); s2.factor = 0.5; s2.iterations = 4; apply_mod(sob, s2)
SV, SF = to_numpy(sob)
if np.mean(np.einsum('ij,ij->i', vertex_normals(SV, SF), SV - SV.mean(0))) < 0: SF = SF[:, ::-1].copy()
SN = vertex_normals(SV, SF)
SJ, SW = skin_weights(SV)
SJ[:] = 0; SW[:] = 0
SJ[:, 0] = np.where(SV[:, 0] > 0, bid["footR"], bid["footL"]); SW[:, 0] = 1
SR = np.ones(len(SV), dtype=np.uint8); SR[SV[:, 1] < 0.026] = 2; SR[(np.abs(SV[:, 2] + 0.115) < 0.006) & (SV[:, 1] > 0.026)] = 3
parts["shoes"] = (SV.astype(np.float32), SN, SF, SJ, SW, SR)

# ----------------------------------------------------------------------------------------------------------- eyes
eyes = bmesh.new()
for sx in (-1, 1): add_ellipsoid(eyes, (EYE_C.x * sx, EYE_C.y, EYE_C.z), (EYE_R, EYE_R, EYE_R), seg=24, rings=16)
me = bpy.data.meshes.new("eyes"); eyes.to_mesh(me); eyes.free()
eob = bpy.data.objects.new("eyes", me); bpy.context.scene.collection.objects.link(eob)
EV, EF = to_numpy(eob)
if np.mean(np.einsum('ij,ij->i', vertex_normals(EV, EF), EV - EV.mean(0))) < 0: EF = EF[:, ::-1].copy()
EN = vertex_normals(EV, EF)
EJ = np.zeros((len(EV), 4), dtype=np.uint8); EW = np.zeros((len(EV), 4), dtype=np.float32)
EJ[:, 0] = np.where(EV[:, 0] > 0, bid["eyeR"], bid["eyeL"]); EW[:, 0] = 1
parts["eyes"] = (EV.astype(np.float32), EN, EF, EJ, EW, np.zeros(len(EV), dtype=np.uint8))

# ----------------------------------------------------------------------------------------------------------- hair / brows / lashes (ribbons)
def ribbons(roots, dirs, normals, length, width, curl, jitter_len=0.25, seed=0, segs=4):
    rng = np.random.default_rng(seed)
    Ps, Ns, Ts, Fs = [], [], [], []
    base = 0
    for r, d, n in zip(roots, dirs, normals):
        L = length * (1 - jitter_len + jitter_len * 2 * rng.random())
        pts = []; cur = np.array(r, dtype=np.float32); dd = d / np.linalg.norm(d)
        for s in range(segs + 1):
            pts.append(cur.copy())
            dd = dd + curl * np.array([0, -1, 0]) + rng.normal(0, 0.02, 3); dd /= np.linalg.norm(dd)
            cur = cur + dd * (L / segs)
        pts = np.array(pts)
        tang = np.diff(pts, axis=0); tang = np.vstack([tang, tang[-1:]]); tang /= np.linalg.norm(tang, axis=1, keepdims=True)
        side = np.cross(tang, n); side /= np.maximum(np.linalg.norm(side, axis=1, keepdims=True), 1e-6)
        for s in range(segs + 1):
            w = width * (1 - 0.8 * s / segs)
            Ps += [pts[s] - side[s] * w, pts[s] + side[s] * w]; Ts += [tang[s], tang[s]]
            nn = np.cross(side[s], tang[s]); Ns += [nn, nn]
        for s in range(segs):
            a = base + 2 * s
            Fs += [[a, a + 1, a + 2], [a + 1, a + 3, a + 2]]
        base += 2 * (segs + 1)
    return np.array(Ps, np.float32), np.array(Ns, np.float32), np.array(Ts, np.float32), np.array(Fs, np.int64)

def head_weights(P):
    j = np.zeros((len(P), 4), np.uint8); w = np.zeros((len(P), 4), np.float32); j[:, 0] = bid["head"]; w[:, 0] = 1; return j, w
# scalp roots: random points on the *actual* head surface (so nothing is buried), above a natural hairline
rng = np.random.default_rng(3)
head_surf = np.isin(primary, [bid["head"]]) & (y > 1.80)
ears = np.zeros(len(V), bool)
for sx in (-1, 1): ears |= np.linalg.norm((V - np.array([0.082 * sx, 1.812, 0.010])) / np.array([0.03, 0.04, 0.035]), axis=1) < 1.0
front_ok = (y > 1.896) | ((np.abs(x) > 0.058) & (y > 1.86) & (z > -0.07))                      # forehead hairline + temples
back_ok = (z > -0.02) & (y > 1.80) & ~ears & ((y > 1.835) | (z > 0.045))                       # sides and back, down the nape
hair_mask = head_surf & ~ears & np.where(z < -0.02, front_ok, back_ok)
cand = np.where(hair_mask)[0]
pick = rng.choice(cand, size=4800, replace=True)
roots, dirs, nrm = [], [], []
for vi in pick:
    p0 = V[vi] + rng.normal(0, 0.0015, 3); n = N[vi]
    d = n * 0.50 + np.array([0, -0.30, -0.12 if z[vi] < -0.02 else 0.0])
    if y[vi] > 1.915: d = n * 0.35 + np.array([0, -0.10, -0.30])                               # crown sweeps forward
    roots.append(p0 - n * 0.002); dirs.append(d); nrm.append(n)
HP, HN, HT, HF = ribbons(roots, dirs, nrm, 0.030, 0.0032, 0.12, jitter_len=0.2, seed=5)
hj, hw = head_weights(HP)
parts["hair"] = (HP, HN, HF, hj, hw, np.full(len(HP), 20, np.uint8), HT)
# eyebrows: rooted on the brow-mask surface, combed outward and slightly up
br_roots, br_dirs, br_n = [], [], []
bcand = np.where((M_BROW > 0.45) & (z < -0.07))[0]
for vi in rng.choice(bcand, size=90, replace=True):
    sx = 1 if x[vi] > 0 else -1; t = (abs(x[vi]) - 0.012) / 0.06
    br_roots.append(V[vi] + rng.normal(0, 0.0008, 3) - N[vi] * 0.0008)
    br_dirs.append(np.array([sx * 0.85, 0.22 * (1 - t) - 0.05, -0.15]) + N[vi] * 0.25); br_n.append(N[vi])
BP, BN, BT, BF = ribbons(br_roots, br_dirs, br_n, 0.009, 0.0009, 0.0, jitter_len=0.2, seed=9, segs=2)
bj, bw = head_weights(BP)
parts["brows"] = (BP, BN, BF, bj, bw, np.full(len(BP), 21, np.uint8), BT)
# eyelashes (upper lids)
ls_roots, ls_dirs, ls_n = [], [], []
for sx in (-1, 1):
    ec = np.array([0.0335 * sx, 1.834, -0.083])
    for i in range(26):
        a = math.pi * (0.1 + 0.8 * i / 25)
        ls_roots.append(ec + np.array([math.cos(a) * 0.0152 * sx, 0.0074 * math.sin(a), -0.0165 * math.sin(a) * 0.45 - 0.002]))
        ls_dirs.append(np.array([math.cos(a) * 0.5 * sx, 0.7, -0.6])); ls_n.append(np.array([0, 0.4, -1.0]))
LP, LN, LT, LF = ribbons(ls_roots, ls_dirs, ls_n, 0.007, 0.0006, -0.1, jitter_len=0.2, seed=11, segs=2)
lj, lw = head_weights(LP)
parts["lashes"] = (LP, LN, LF, lj, lw, np.full(len(LP), 22, np.uint8), LT)

log('clothing + hair done')
# ----------------------------------------------------------------------------------------------------------- export
parts["body"] = (V.astype(np.float32), N, F, J, WT, REG)
BODY_MASKS = MASKS
order = ["body", "eyes", "hair", "brows", "lashes", "shirt", "shorts", "socks", "shoes", "bands"]
blob = bytearray(); meta = {"bones": [], "parts": [], "morphs": MORPH_NAMES}
for b in BONES:
    meta["bones"].append({"name": b[0], "joint": [float(b[3].x), float(b[3].y), float(b[3].z)], "rotZ": float(b[4])})
for name in order:
    tup = parts[name]; P_, N_, F_, J_, W_, R_ = tup[:6]
    T_ = tup[6] if len(tup) > 6 else np.zeros_like(P_)
    n = len(P_)
    vb = bytearray()
    for i in range(n):
        mk = BODY_MASKS[i] if name == 'body' else (0, 0, 0, 0)
        vb += struct.pack('<3f3f3f4B4B4B4f', *P_[i], *N_[i], *T_[i], *[int(q) for q in J_[i]], int(R_[i]), 0, 0, 0, *[int(q) for q in mk], *W_[i])
    ib = np.asarray(F_, dtype=np.uint32).tobytes()
    entry = {"name": name, "vertexCount": n, "indexCount": int(F_.size), "vertexOffset": len(blob)}
    blob += vb; entry["indexOffset"] = len(blob); blob += ib
    if name == "body":
        entry["morphOffset"] = len(blob)
        for m in MORPHS:
            mm = np.zeros((n, 4), np.float32); mm[:, :3] = m; blob += mm.tobytes()
    meta["parts"].append(entry)
    print(f"{name}: {n} verts, {F_.shape[0]} tris")
hdr = json.dumps(meta).encode()
with open(os.path.join(OUT, "athlete.hum"), "wb") as f:
    f.write(b"HUM1"); f.write(struct.pack("<I", len(hdr))); f.write(hdr)
    pad = (-(8 + len(hdr))) % 16; f.write(b"\0" * pad); f.write(bytes(blob))
print("EXPORTED athlete.hum", os.path.getsize(os.path.join(OUT, "athlete.hum")) // 1024, "KB")

# ----------------------------------------------------------------------------------------------------------- previews (Blender Workbench)
if PREVIEW:
    os.makedirs(PREVIEW, exist_ok=True)
    def mesh_obj(name, P_, F_, color):
        me = bpy.data.meshes.new(name); me.from_pydata([(float(p[0]), float(-p[2]), float(p[1])) for p in P_], [], [tuple(int(i) for i in f) for f in F_]); me.update()
        for p in me.polygons: p.use_smooth = True
        o = bpy.data.objects.new(name, me); bpy.context.scene.collection.objects.link(o)
        mat = bpy.data.materials.new(name); mat.diffuse_color = color; o.data.materials.append(mat); return o
    for o in list(bpy.data.objects): bpy.data.objects.remove(o)
    mesh_obj("body", V, F, (0.85, 0.62, 0.5, 1))
    for nm, col in (("shirt", (0.95, 0.95, 0.95, 1)), ("shorts", (0.1, 0.15, 0.45, 1)), ("socks", (0.95, 0.95, 0.95, 1)), ("shoes", (0.9, 0.9, 0.92, 1)), ("bands", (0.1, 0.25, 0.8, 1))):
        t = parts[nm]; mesh_obj(nm, t[0], t[2], col)
    t = parts["eyes"]; mesh_obj("eyes", t[0], t[2], (0.95, 0.95, 0.95, 1))
    t = parts["hair"]; mesh_obj("hair", t[0], t[2], (0.08, 0.05, 0.03, 1))
    t = parts["brows"]; mesh_obj("brows", t[0], t[2], (0.05, 0.03, 0.02, 1))
    sc = bpy.context.scene; sc.render.engine = 'BLENDER_WORKBENCH'
    sc.display.shading.light = 'STUDIO'; sc.display.shading.color_type = 'MATERIAL'
    sc.render.film_transparent = False
    sc.world = bpy.data.worlds.new("w"); sc.world.color = (0.55, 0.62, 0.7)
    def shot(name, loc, target, ortho_scale, res=(640, 960)):
        cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam")); bpy.context.scene.collection.objects.link(cam)
        cam.data.type = 'ORTHO'; cam.data.ortho_scale = ortho_scale
        cam.location = loc
        d = Vector(target) - Vector(loc); cam.rotation_euler = d.to_track_quat('-Z', 'Y').to_euler()
        sc.camera = cam; sc.render.resolution_x, sc.render.resolution_y = res
        sc.render.filepath = os.path.join(PREVIEW, name + ".png"); bpy.ops.render.render(write_still=True)
        bpy.data.objects.remove(cam)
    # model space (x, y, z) -> preview space (x, -z, y): up is +Z, the character faces +Y
    shot("front", (0, 5, 1.0), (0, 0, 1.0), 2.2)
    shot("side", (5, 0, 1.0), (0, 0, 1.0), 2.2)
    shot("face", (0, 3, 1.82), (0, 0, 1.82), 0.34, res=(640, 640))
    shot("face3q", (1.2, 2.6, 1.9), (0, 0, 1.82), 0.34, res=(640, 640))
    print("PREVIEWS DONE")
