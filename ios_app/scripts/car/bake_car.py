#!/usr/bin/env python3
"""Bake the car on the Car card: a glTF car → JarvisCopilot/Car/Camry.bin.

Source: "2025 Toyota Camry (XV80) Hybrid" by Ddiaz Design on Sketchfab (CC BY-NC-SA 4.0 —
see JarvisCopilot/Car/Camry-LICENSE.md). Download the glTF from Sketchfab (logged in), unzip it
somewhere outside the repo, then:

    python3 -m venv /tmp/carbake && /tmp/carbake/bin/pip install numpy fast-simplification
    /tmp/carbake/bin/python scripts/car/bake_car.py <unzipped>/scene.gltf JarvisCopilot/Car/Camry.bin

Every material is mapped to a SLOT (paint, glass, chrome, …); the app gives each slot its own
material, which is how the paint becomes Dark Cosmos and the lamps can glow. Textures are dropped
(the source is almost all flat PBR factors). Each slot is welded, simplified to its triangle
budget, and given crease-aware normals. The car is put in metres on the ground (y = 0), centred,
its length along Z with the front toward +Z.

Format (little-endian): "JCCR", u32 version=1, u32 slotCount, f32×3 min, f32×3 max, then per slot:
u32 slot, u32 vertexCount, u32 indexCount, f32×3 positions, f32×3 normals, u32 indices.
"""
import json
import os
import struct
import sys

import numpy as np

# Slot ids — the same order as `CarModel.Slot` in Swift.
SLOTS = ["paint", "glass", "chrome", "glossTrim", "matteTrim", "rubber", "wheel", "lampLens",
         "lampInner", "lampGlow", "tailLens", "amberLens", "interior", "brake", "mirror"]

MATERIAL_SLOT = {
    "CarPaint": "paint", "Hndle_Decal": "paint",
    "Windows": "glass", "D_glass": "glass", "Int_Glass": "glass",
    "CarP_Chrome": "chrome", "Ext_Chorme": "chrome", "CarP_Chrome_R": "chrome", "CarP_Metal": "chrome",
    "Wheel_Chrome": "chrome",
    "CarP_Plastic_S": "glossTrim", "CarP_PLastic_G_S": "glossTrim",
    "CarP_Plastic": "matteTrim", "CarP_Plastic_G_R": "matteTrim", "Black": "matteTrim",
    "Ex_Plastic": "matteTrim", "Ex_Fbric_B": "matteTrim", "Wheel_Plastic": "matteTrim", "Bolt": "matteTrim",
    "Tire": "rubber", "CarP_Rubber": "rubber",
    "Wheel_Alloy": "wheel",
    "Glass_Light": "lampLens", "Light_Frost": "lampLens", "Frost_Glass": "lampLens",
    # Ex_White / Door_Light_N are cabin trim (seat backs, door courtesy lamps): white specks in the cutaway.
    "Reflector_W": "lampInner", "Ex_White": "interior", "Door_Light_N": "interior",
    "Glow": "lampGlow", "Decal_Light": "lampGlow",
    "Red_glass": "tailLens",
    "Color_glass": "amberLens",
    "Rotor": "brake", "Caliper": "brake",
    "Mirror": "mirror",
}
# Textured decals (badges, the show plate's lettering) are flat quads without their texture.
DROP = {"Decals"}
INTERIOR_PREFIXES = ("Int_", "Dash_", "Seat", "Speaker", "Stitches", "ZIP_", "Blue", "material")

# Triangle budget per slot. The paint and the wheels keep every triangle of the source (their
# reflections show any faceting); trim and rubber keep enough for clean edges; the cabin, seen only
# from above in the lights' cut-away, stays light. (A 209 k bake looked worse and was no faster: the
# lag was the 30 fps cap and an off-screen car still drawing, not the triangles.)
BUDGET = {"paint": 140000, "chrome": 40000, "glossTrim": 32000, "matteTrim": 48000, "rubber": 40000,
          "wheel": 46000, "interior": 40000, "glass": 4000, "lampLens": 20000, "lampInner": 4000,
          "lampGlow": 2500, "tailLens": 8000, "amberLens": 1500, "brake": 3000, "mirror": 600}

CREASE_DEGREES = 50
# The source is a right-hand-drive Camry (steering wheel on the right); his US car is left-hand
# drive. The body is symmetric, so mirroring the whole car across its centreline only moves the
# cabin: the wheel ends up on the left, at +X (the car's left when facing +Z with +Y up).
LEFT_HAND_DRIVE = True
LENGTH_M = 4.915   # 2025+ Camry, bumper to bumper
WELD_M = 0.0005


def slot_for(material):
    if material in DROP:
        return None
    if material in MATERIAL_SLOT:
        return MATERIAL_SLOT[material]
    if material.startswith(INTERIOR_PREFIXES):
        return "interior"
    print(f"  unmapped material {material!r} → matteTrim", file=sys.stderr)
    return "matteTrim"


def node_matrix(n):
    if "matrix" in n:
        return np.array(n["matrix"], dtype=np.float64).reshape(4, 4).T
    t, r, s = np.eye(4), np.eye(4), np.eye(4)
    if "translation" in n:
        t[:3, 3] = n["translation"]
    if "rotation" in n:
        x, y, z, w = n["rotation"]
        r[:3, :3] = [[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]]
    if "scale" in n:
        s[0, 0], s[1, 1], s[2, 2] = n["scale"]
    return t @ r @ s


COMPONENT = {5120: np.int8, 5121: np.uint8, 5122: np.int16, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}
WIDTH = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}


def accessor(g, buffers, index):
    a = g["accessors"][index]
    view = g["bufferViews"][a["bufferView"]]
    dtype = np.dtype(COMPONENT[a["componentType"]])
    width = WIDTH[a["type"]]
    start = view.get("byteOffset", 0) + a.get("byteOffset", 0)
    stride = view.get("byteStride", dtype.itemsize * width)
    raw = buffers[view["buffer"]]
    if stride == dtype.itemsize * width:
        out = np.frombuffer(raw, dtype, a["count"] * width, start).reshape(a["count"], width)
    else:
        rows = np.frombuffer(raw, np.uint8, (a["count"] - 1) * stride + dtype.itemsize * width, start)
        out = np.lib.stride_tricks.as_strided(rows, (a["count"], dtype.itemsize * width), (stride, 1))
        out = np.ascontiguousarray(out).view(dtype).reshape(a["count"], width)
    return out.astype(np.float64) if dtype == np.float32 else out.astype(np.int64)


def gather(path):
    g = json.load(open(path))
    base = os.path.dirname(path)
    buffers = [open(os.path.join(base, b["uri"]), "rb").read() for b in g["buffers"]]
    parts = {}   # slot → list of (positions, faces)

    def walk(i, parent):
        n = g["nodes"][i]
        world = parent @ node_matrix(n)
        if "mesh" in n:
            for p in g["meshes"][n["mesh"]]["primitives"]:
                if p.get("mode", 4) != 4 or "material" not in p:
                    continue
                slot = slot_for(g["materials"][p["material"]].get("name", ""))
                if slot is None:
                    continue
                pos = accessor(g, buffers, p["attributes"]["POSITION"])
                pos = (np.c_[pos, np.ones(len(pos))] @ world.T)[:, :3]
                faces = (accessor(g, buffers, p["indices"]).reshape(-1, 3) if "indices" in p
                         else np.arange(len(pos)).reshape(-1, 3))
                if np.linalg.det(world[:3, :3]) < 0:
                    faces = faces[:, ::-1]
                parts.setdefault(slot, []).append((pos, faces))
        for c in n.get("children", []):
            walk(c, world)

    for root in g["scenes"][g.get("scene", 0)]["nodes"]:
        walk(root, np.eye(4))
    out = {}
    for s, v in parts.items():
        offsets = np.cumsum([0] + [len(p) for p, _ in v[:-1]])
        out[s] = (np.concatenate([p for p, _ in v]), np.concatenate([f + o for (_, f), o in zip(v, offsets)]))
    return out


def place(slots):
    """Metres, on the ground, centred, length along Z with the front (headlamps) toward +Z."""
    allpos = np.concatenate([p for p, _ in slots.values()])
    lo, hi = allpos.min(0), allpos.max(0)
    extent = hi - lo
    length_axis, up_axis = int(np.argmax(extent)), int(np.argmin(extent))
    side_axis = 3 - length_axis - up_axis
    # Wheels sit below the roof: if the tyres are above the middle, the up axis is flipped.
    tyres = slots["rubber"][0]
    up_sign = 1.0 if tyres[:, up_axis].mean() < (lo[up_axis] + hi[up_axis]) / 2 else -1.0
    # Headlamps lead: the lens centroid is on the front half.
    lamps = slots["lampLens"][0]
    front_sign = 1.0 if lamps[:, length_axis].mean() > (lo[length_axis] + hi[length_axis]) / 2 else -1.0
    scale = LENGTH_M / extent[length_axis]
    basis = np.zeros((3, 3))
    basis[2, length_axis], basis[1, up_axis], basis[0, side_axis] = front_sign, up_sign, 1
    # Keep it a rotation: if the axis swap mirrored the car, flip X back.
    mirror = -1.0 if np.linalg.det(basis) < 0 else 1.0
    if LEFT_HAND_DRIVE:
        mirror = -mirror
    out = {}
    for s, (p, f) in slots.items():
        q = np.empty_like(p)
        q[:, 2] = (p[:, length_axis] - (lo[length_axis] + hi[length_axis]) / 2) * front_sign
        q[:, 1] = (p[:, up_axis] - (lo[up_axis] if up_sign > 0 else hi[up_axis])) * up_sign
        q[:, 0] = (p[:, side_axis] - (lo[side_axis] + hi[side_axis]) / 2) * mirror
        # A mirror turns the faces inside out: flip their winding back.
        out[s] = (q * scale, f[:, ::-1] if LEFT_HAND_DRIVE else f)
    return out


def weld(p, f):
    key = np.round(p / WELD_M).astype(np.int64)
    _, first, inverse = np.unique(key, axis=0, return_index=True, return_inverse=True)
    f = inverse.reshape(-1)[f]
    f = f[(f[:, 0] != f[:, 1]) & (f[:, 1] != f[:, 2]) & (f[:, 0] != f[:, 2])]
    return p[first], f


def simplify(p, f, budget):
    import fast_simplification
    if len(f) <= budget:
        return p, f
    reduction = 1 - budget / len(f)
    p2, f2 = fast_simplification.simplify(p.astype(np.float32), f.astype(np.int32), target_reduction=reduction, agg=7)
    return p2.astype(np.float64), f2.astype(np.int64)


def crease_normals(p, f):
    """One vertex per (position, smoothing group): corners average the faces around them that
    bend less than CREASE_DEGREES from their own face — panel gaps stay sharp, curves stay smooth."""
    a, b, c = p[f[:, 0]], p[f[:, 1]], p[f[:, 2]]
    fn = np.cross(b - a, c - a)                     # area-weighted
    unit = fn / np.maximum(np.linalg.norm(fn, axis=1, keepdims=True), 1e-20)
    corner_v = f.reshape(-1)
    corner_f = np.repeat(np.arange(len(f)), 3)
    order = np.argsort(corner_v, kind="stable")
    v_sorted = corner_v[order]
    f_sorted = corner_f[order]
    starts = np.r_[0, np.flatnonzero(np.diff(v_sorted)) + 1]
    sizes = np.diff(np.r_[starts, len(v_sorted)])
    group_size = np.repeat(sizes, sizes)                      # per sorted corner
    group_start = np.repeat(starts, sizes)
    me = np.repeat(np.arange(len(v_sorted)), group_size)      # each corner × its group
    offs = np.arange(len(me)) - np.repeat(np.cumsum(group_size) - group_size, group_size)
    other = group_start[me] + offs
    fm, fo = f_sorted[me], f_sorted[other]
    keep = np.einsum("ij,ij->i", unit[fm], unit[fo]) > np.cos(np.radians(CREASE_DEGREES))
    normals_sorted = np.zeros((len(v_sorted), 3))
    np.add.at(normals_sorted, me[keep], fn[fo[keep]])
    normals_sorted /= np.maximum(np.linalg.norm(normals_sorted, axis=1, keepdims=True), 1e-20)
    normals = np.empty_like(normals_sorted)
    normals[order] = normals_sorted
    # Share a vertex between corners with the same position and (nearly) the same normal.
    key = np.c_[corner_v, np.round(normals * 64).astype(np.int64)]
    _, first, inverse = np.unique(key, axis=0, return_index=True, return_inverse=True)
    return p[corner_v[first]], normals[first], inverse.reshape(-1, 3)


def main(src, dst):
    slots = place(gather(src))
    total_in = sum(len(f) for _, f in slots.values())
    blobs, lo, hi, total_out = [], np.full(3, np.inf), np.full(3, -np.inf), 0
    for name in SLOTS:
        if name not in slots:
            continue
        p, f = weld(*slots[name])
        p, f = simplify(p, f, BUDGET[name])
        p, n, f = crease_normals(p, f)
        lo, hi = np.minimum(lo, p.min(0)), np.maximum(hi, p.max(0))
        total_out += len(f)
        print(f"  {name:10s} {len(f):7d} tris {len(p):7d} verts")
        blobs.append(struct.pack("<3I", SLOTS.index(name), len(p), f.size)
                     + p.astype("<f4").tobytes() + n.astype("<f4").tobytes() + f.astype("<u4").tobytes())
    header = b"JCCR" + struct.pack("<2I", 1, len(blobs)) + lo.astype("<f4").tobytes() + hi.astype("<f4").tobytes()
    with open(dst, "wb") as out:
        out.write(header + b"".join(blobs))
    print(f"{total_in} → {total_out} triangles; size {np.round(hi - lo, 3)} m; {os.path.getsize(dst) / 1e6:.1f} MB")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
