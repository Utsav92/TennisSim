"""
Generates the tennis player's body-part meshes and racket in Blender and exports one OBJ per part.
Run:  /Applications/Blender.app/Contents/MacOS/Blender --background --python Tools/blender/make_assets.py -- <out_dir>

Conventions (identical in Blender and in the game, no axis conversion): +Y up, character faces -Z, right hand is +X.
Every part's origin is its joint pivot (limbs hang down -Y from the pivot; the racket points down -Y from the grip,
with its face in the YZ plane). Units are metres.
"""
import bpy, bmesh, math, os, sys

out_dir = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else os.path.abspath("Models")
os.makedirs(out_dir, exist_ok=True)
bpy.ops.wm.read_factory_settings(use_empty=True)

def make_object(name, bm, smooth=True):
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me); bm.free()
    for p in me.polygons: p.use_smooth = smooth
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    return ob

def lathe(name, profile, seg=20, ez=1.0, shift=(0, 0, 0)):
    """Surface of revolution about +Y from [(y, radius)...]; radius 0 collapses to a single apex vertex.
    ez scales the z extent (elliptical cross-section)."""
    bm = bmesh.new()
    rings = []
    for y, r in profile:
        if r < 1e-6:
            rings.append([bm.verts.new((shift[0], y + shift[1], shift[2]))])
        else:
            rings.append([bm.verts.new((r * math.cos(2 * math.pi * i / seg) + shift[0], y + shift[1],
                                        r * math.sin(2 * math.pi * i / seg) * ez + shift[2])) for i in range(seg)])
    for a, b in zip(rings, rings[1:]):
        for i in range(seg):
            j = (i + 1) % seg
            if len(a) == 1: bm.faces.new((a[0], b[j], b[i]))
            elif len(b) == 1: bm.faces.new((a[i], a[j], b[0]))
            else: bm.faces.new((a[i], a[j], b[j], b[i]))
    return bm

def capsule_profile(L, r0, r1, cap=0.9, steps=6):
    p = []
    for k in range(steps + 1):                       # top hemisphere (slightly flattened)
        a = (math.pi / 2) * k / steps
        p.append((r0 * cap * math.cos(a), r0 * math.sin(a) if k < steps else r0))
    p[0] = (r0 * cap, 0.0)
    p += [(-L * 0.5, (r0 + r1) / 2)]
    for k in range(steps + 1):                       # bottom hemisphere
        a = (math.pi / 2) * k / steps
        p.append((-L - r1 * cap * math.sin(a), r1 * math.cos(a) if k < steps else 0.0))
    return p

def limb(name, L, r0, r1, ez=1.0): return make_object(name, lathe(name, capsule_profile(L, r0, r1), ez=ez))

parts = []
parts.append(limb("upperArm", 0.30, 0.050, 0.042))
parts.append(limb("foreArm", 0.27, 0.042, 0.033))
parts.append(limb("thigh", 0.45, 0.085, 0.060))
parts.append(limb("calf", 0.43, 0.060, 0.040))
parts.append(make_object("hand", lathe("hand", [(0.04, 0), (0.03, 0.03), (0, 0.045), (-0.04, 0.035), (-0.06, 0)], seg=12)))

# Torso: pivot at hip-centre top, rises to the shoulders (elliptical cross-section, wider than deep).
torso = [(-0.02, 0.0), (0.0, 0.14), (0.15, 0.15), (0.32, 0.19), (0.46, 0.225), (0.56, 0.22), (0.62, 0.13), (0.66, 0.0)]
parts.append(make_object("torso", lathe("torso", torso, seg=28, ez=0.58)))
# Shorts: pelvis barrel hanging from the hip pivot.
shorts = [(0.06, 0.0), (0.04, 0.16), (-0.02, 0.19), (-0.12, 0.202), (-0.21, 0.206), (-0.225, 0.0)]
parts.append(make_object("shorts", lathe("shorts", shorts, seg=24, ez=0.78)))   # wide enough to cover both thigh tops when the hips flex
# Neck + head (pivot at the neck base). Head is an egg: ellipsoid with a slightly narrower jaw.
head = [(0.0, 0.0), (0.0, 0.048), (0.08, 0.050)]
for k in range(0, 13):
    t = -math.pi / 2 + math.pi * k / 12
    y = 0.21 + 0.125 * math.sin(t)
    r = 0.098 * math.cos(t) * (0.92 + 0.08 * math.sin(t))
    if y > 0.08 and r > 1e-4: head.append((y, r))
head.append((0.335, 0.0))
parts.append(make_object("head", lathe("head", head, seg=24, ez=1.12)))
hair = [(0.19, 0.104)]
for k in range(1, 9):
    t = math.pi / 2 * k / 8
    hair.append((0.19 + 0.150 * math.sin(t), 0.104 * math.cos(t)))
parts.append(make_object("hair", lathe("hair", hair, seg=24, ez=1.14)))

# Shoe: long axis along -Z, ankle pivot at the origin.
shoe_prof = [(0.0, 0.0), (0.012, 0.04), (0.08, 0.052), (0.20, 0.050), (0.28, 0.035), (0.31, 0.0)]
bm = lathe("shoe", shoe_prof, seg=18, ez=0.7)
for v in bm.verts:                                   # (x, y, z) -> length along -Z, height along Y
    x, y, z = v.co
    v.co = (x, z - 0.045, -y + 0.07)
parts.append(make_object("shoe", bm))

# Racket: handle + throat (lathe), oval frame (swept tube), string bed (thin disc). Face in the YZ plane.
handle = [(0.03, 0.0), (0.025, 0.018), (0.0, 0.019), (-0.17, 0.019), (-0.175, 0.016), (-0.19, 0.011), (-0.27, 0.008), (-0.275, 0.0)]
parts.append(make_object("racketHandle", lathe("racketHandle", handle, seg=12)))

head_cy, head_a, head_b = -0.27 - 0.19, 0.19, 0.15   # centre y; semi-axes along Y and Z
bm = bmesh.new(); N, M, tube = 40, 8, 0.011
rings = []
for i in range(N):
    u = 2 * math.pi * i / N
    cy, cz = head_cy + head_a * math.cos(u), head_b * math.sin(u)
    ty, tz = -head_a * math.sin(u), head_b * math.cos(u)       # tangent in YZ plane
    n = math.hypot(ty, tz); ty, tz = ty / n, tz / n
    ny, nz = -tz, ty                                           # in-plane normal
    ring = []
    for k in range(M):
        w = 2 * math.pi * k / M
        ring.append(bm.verts.new((tube * math.sin(w), cy + tube * math.cos(w) * ny, cz + tube * math.cos(w) * nz)))
    rings.append(ring)
for i in range(N):
    for k in range(M):
        a, b = rings[i], rings[(i + 1) % N]
        bm.faces.new((a[k], a[(k + 1) % M], b[(k + 1) % M], b[k]))
parts.append(make_object("racketFrame", bm))

bm = bmesh.new(); N = 36; t = 0.0035
cf, cb = bm.verts.new((t, head_cy, 0)), bm.verts.new((-t, head_cy, 0))
f, b = [], []
for i in range(N):
    u = 2 * math.pi * i / N
    y, z = head_cy + (head_a - tube * 0.5) * math.cos(u), (head_b - tube * 0.5) * math.sin(u)
    f.append(bm.verts.new((t, y, z))); b.append(bm.verts.new((-t, y, z)))
for i in range(N):
    j = (i + 1) % N
    bm.faces.new((cf, f[i], f[j])); bm.faces.new((cb, b[j], b[i])); bm.faces.new((f[i], b[i], b[j], f[j]))
parts.append(make_object("racketStrings", bm, smooth=False))

for ob in parts:
    bpy.ops.object.select_all(action='DESELECT')
    ob.select_set(True); bpy.context.view_layer.objects.active = ob
    bpy.ops.wm.obj_export(filepath=os.path.join(out_dir, ob.name + ".obj"), export_selected_objects=True,
                          export_uv=False, export_materials=False, export_normals=True,
                          forward_axis='Y', up_axis='Z', apply_modifiers=True)

# ---------------------------------------------------------------------------------------------------------------
# Spectator: one merged low-poly seated figure (torso + head + two arms) used for GPU-instanced crowds.
# Origin = seat centre, +Y up, faces -Z. The game's vertex shader animates it: head yaw (watches the ball), body bob,
# and arm raise about the shoulders at (±0.24, 0.47, 0) for cheering. Regions the shader/fragment shader rely on:
#   arms: |x| > 0.19 and y < 0.52; head: y > 0.56; hair: y > 0.74 or (y > 0.66 and z > 0.02).
# ---------------------------------------------------------------------------------------------------------------
sp = []
sp.append(make_object("sp_torso", lathe("sp_torso", [(0.0, 0.0), (0.0, 0.15), (0.10, 0.17), (0.28, 0.19), (0.42, 0.21), (0.50, 0.19), (0.54, 0.09), (0.56, 0.0)], seg=12, ez=0.62)))
sp.append(make_object("sp_neck", lathe("sp_neck", [(0.54, 0.0), (0.54, 0.05), (0.62, 0.05), (0.63, 0.0)], seg=8)))
hd = [(0.60, 0.0)]
for k in range(1, 8):
    t = -math.pi / 2 + math.pi * k / 7
    hd.append((0.72 + 0.115 * math.sin(t), 0.095 * math.cos(t)))
hd.append((0.835, 0.0))
sp.append(make_object("sp_head", lathe("sp_head", [h for h in hd if h[1] > 1e-4 or h in (hd[0], hd[-1])], seg=12, ez=1.1)))
for sx in (-1, 1):
    sp.append(make_object("sp_arm%d" % sx, lathe("sp_arm", capsule_profile(0.44, 0.05, 0.042, steps=3), seg=8, shift=(0.24 * sx, 0.47, 0.0))))
bpy.ops.object.select_all(action='DESELECT')
for ob in sp: ob.select_set(True)
bpy.context.view_layer.objects.active = sp[0]
bpy.ops.object.join()
spectator = bpy.context.view_layer.objects.active
spectator.name = "spectator"
bpy.ops.wm.obj_export(filepath=os.path.join(out_dir, "spectator.obj"), export_selected_objects=True, export_uv=False,
                      export_materials=False, export_normals=True, forward_axis='Y', up_axis='Z', apply_modifiers=True)
print("spectator tris:", sum(len(p.vertices) - 2 for p in spectator.data.polygons))

bpy.ops.wm.save_as_mainfile(filepath=os.path.join(os.path.dirname(os.path.abspath(__file__)), "tennis_assets.blend"))
print("EXPORTED", [ob.name for ob in parts])
