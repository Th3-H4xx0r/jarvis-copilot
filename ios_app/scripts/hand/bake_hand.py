#!/usr/bin/env python3
"""Bake the "put the ring on" hand: pose a rigged hand and write RingHand.bin.

Source: the WebXR generic hand (right.glb) from @webxr-input-profiles/assets,
MIT licensed, Copyright (c) 2019 Amazon — see RingHand-LICENSE.md. It is a
Blender-made mesh with the 25 WebXR joints; this poses those joints (index
pointing, the other fingers folded, thumb across them), skins the mesh, and
writes the result in the ring's units: the ring's seat on the index finger at
the origin, the finger running down +X, the back of the hand toward +Y, and
the finger's widest cross-section at the seat just inside the ring's bore.

    python3 scripts/hand/bake_hand.py right.glb JarvisCopilot/Ring/RingHand.bin

Format (little-endian): "JCHD", u32 version=1, u32 vertexCount, u32 indexCount,
f32×3 fingertip, then f32×3 positions, f32×3 normals, u16 indices.
"""
import json
import struct
import sys

import numpy as np

# Degrees of flexion at each joint (the joint named is the one the bone below
# it hinges on). Index held out; the rest folded into the palm.
POSE = {
    "index-finger-phalanx-proximal": 0, "index-finger-phalanx-intermediate": 0,
    "index-finger-phalanx-distal": 0,
    "middle-finger-phalanx-proximal": 82, "middle-finger-phalanx-intermediate": 100,
    "middle-finger-phalanx-distal": 55,
    "ring-finger-phalanx-proximal": 86, "ring-finger-phalanx-intermediate": 100,
    "ring-finger-phalanx-distal": 55,
    "pinky-finger-phalanx-proximal": 90, "pinky-finger-phalanx-intermediate": 100,
    "pinky-finger-phalanx-distal": 50,
}
# The thumb folds on its own axes: (joint, degrees about local X, about local Y).
THUMB = [("thumb-metacarpal", 18, 22), ("thumb-phalanx-proximal", 22, 0), ("thumb-phalanx-distal", 28, 0)]

CHAINS = [["wrist", f"{f}-metacarpal", f"{f}-phalanx-proximal", f"{f}-phalanx-intermediate",
           f"{f}-phalanx-distal", f"{f}-tip"] for f in ("index-finger", "middle-finger", "ring-finger", "pinky-finger")]
CHAINS.append(["wrist", "thumb-metacarpal", "thumb-phalanx-proximal", "thumb-phalanx-distal", "thumb-tip"])

# How far inside the ring's bore (inner radius 0.805) the finger's widest
# point at the seat sits.
FIT_RADIUS = 0.77
SEAT_ALONG = 0.42   # of the way from the knuckle to the middle joint


def load(path):
    data = open(path, "rb").read()
    jlen = struct.unpack_from("<I", data, 12)[0]
    gltf = json.loads(data[20:20 + jlen])
    blen = struct.unpack_from("<I", data, 20 + jlen)[0]
    blob = data[28 + jlen:28 + jlen + blen]
    return gltf, blob


def accessor(gltf, blob, index):
    a = gltf["accessors"][index]
    view = gltf["bufferViews"][a["bufferView"]]
    comps = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}[a["type"]]
    dtype = {5126: np.float32, 5123: np.uint16, 5121: np.uint8, 5125: np.uint32}[a["componentType"]]
    offset = view.get("byteOffset", 0) + a.get("byteOffset", 0)
    stride = view.get("byteStride")
    item = np.dtype(dtype).itemsize * comps
    if stride and stride != item:
        raw = np.frombuffer(blob, np.uint8, count=stride * a["count"], offset=offset).reshape(a["count"], stride)
        arr = raw[:, :item].copy().view(dtype).reshape(a["count"], comps)
    else:
        arr = np.frombuffer(blob, dtype, count=a["count"] * comps, offset=offset).reshape(a["count"], comps)
    if a.get("normalized") and dtype != np.float32:
        arr = arr.astype(np.float32) / np.iinfo(dtype).max
    return arr


def quat_matrix(q):
    x, y, z, w = q
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ])


def node_matrix(node):
    if "matrix" in node:
        return np.array(node["matrix"], dtype=float).reshape(4, 4).T
    m = np.eye(4)
    r = quat_matrix(node.get("rotation", [0, 0, 0, 1]))
    s = np.diag(node.get("scale", [1, 1, 1]))
    m[:3, :3] = r @ s
    m[:3, 3] = node.get("translation", [0, 0, 0])
    return m


def rot(axis, degrees):
    a = np.radians(degrees)
    c, s = np.cos(a), np.sin(a)
    m = np.eye(4)
    if axis == "x":
        m[1:3, 1:3] = [[c, -s], [s, c]]
    else:
        m[0, 0], m[0, 2], m[2, 0], m[2, 2] = c, s, -s, c
    return m


def weld(p, idx, eps=1e-6):
    """Merge vertices that share a position (the mesh splits them at UV seams)."""
    keys = np.round(p / eps).astype(np.int64)
    _, first, inverse = np.unique(keys, axis=0, return_index=True, return_inverse=True)
    tris = inverse.reshape(-1)[idx].reshape(-1, 3)
    tris = tris[(tris[:, 0] != tris[:, 1]) & (tris[:, 1] != tris[:, 2]) & (tris[:, 0] != tris[:, 2])]
    return p[first], tris.reshape(-1)


def loop_subdivide(p, idx):
    """One step of Loop subdivision on a closed-or-open triangle mesh."""
    tris = idx.reshape(-1, 3)
    edges = np.sort(np.concatenate([tris[:, [0, 1]], tris[:, [1, 2]], tris[:, [2, 0]]]), axis=1)
    unique, inverse, counts = np.unique(edges, axis=0, return_inverse=True, return_counts=True)
    inverse = inverse.reshape(-1)
    nt = len(tris)
    # Opposite vertices of each edge, for the 3/8–1/8 edge rule.
    opposite = np.concatenate([tris[:, 2], tris[:, 0], tris[:, 1]])
    opp_sum = np.zeros((len(unique), 3))
    np.add.at(opp_sum, inverse, p[opposite])
    ends = p[unique[:, 0]] + p[unique[:, 1]]
    interior = counts == 2
    edge_pts = np.where(interior[:, None], 3 / 8 * ends + 1 / 8 * opp_sum, ends / 2)

    # Move the old vertices toward their neighbours (boundary vertices stay).
    nv = len(p)
    neighbour_sum = np.zeros((nv, 3))
    valence = np.zeros(nv)
    np.add.at(neighbour_sum, unique[:, 0], p[unique[:, 1]])
    np.add.at(neighbour_sum, unique[:, 1], p[unique[:, 0]])
    np.add.at(valence, unique[:, 0], 1)
    np.add.at(valence, unique[:, 1], 1)
    boundary = np.zeros(nv, bool)
    boundary[unique[~interior].reshape(-1)] = True
    k = np.maximum(valence, 1)
    beta = np.where(k > 3, 3 / (8 * k), 3 / 16)
    moved = (1 - k * beta)[:, None] * p + beta[:, None] * neighbour_sum
    moved[boundary] = p[boundary]

    points = np.concatenate([moved, edge_pts])
    e = inverse.reshape(3, nt).T + nv          # edge points for (01, 12, 20)
    a, b, c = tris[:, 0], tris[:, 1], tris[:, 2]
    e01, e12, e20 = e[:, 0], e[:, 1], e[:, 2]
    new = np.stack([
        np.stack([a, e01, e20], 1), np.stack([b, e12, e01], 1),
        np.stack([c, e20, e12], 1), np.stack([e01, e12, e20], 1)], 1).reshape(-1, 3)
    return points, new.reshape(-1)


def smooth_normals(p, idx):
    tris = idx.reshape(-1, 3)
    face = np.cross(p[tris[:, 1]] - p[tris[:, 0]], p[tris[:, 2]] - p[tris[:, 0]])
    n = np.zeros_like(p)
    for corner in range(3):
        np.add.at(n, tris[:, corner], face)
    return n / np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-12)


def main(src, out, flex_sign=None):
    gltf, blob = load(src)
    nodes = gltf["nodes"]
    names = {n.get("name"): i for i, n in enumerate(nodes)}
    skin = gltf["skins"][0]
    joints = skin["joints"]
    ibm = accessor(gltf, blob, skin["inverseBindMatrices"]).reshape(-1, 4, 4).transpose(0, 2, 1)

    # Global rest transforms: joints hang flat under the armature.
    parent = {c: i for i, n in enumerate(nodes) for c in n.get("children", [])}

    def global_rest(i):
        m = node_matrix(nodes[i])
        while i in parent:
            i = parent[i]
            m = node_matrix(nodes[i]) @ m
        return m

    rest = {nodes[j]["name"]: global_rest(j) for j in joints}

    def flex_for(sign):
        posed = {"wrist": rest["wrist"]}
        for chain in CHAINS:
            for parent_name, name in zip(chain, chain[1:]):
                local = np.linalg.inv(rest[parent_name]) @ rest[name]
                bend = np.eye(4)
                if name in POSE:
                    bend = rot("x", sign * POSE[name])
                for joint, bx, by in THUMB:
                    if joint == name:
                        bend = rot("x", sign * bx) @ rot("y", by)
                posed[name] = posed[parent_name] @ local @ bend
        return posed

    # Which way is "toward the palm" depends on the rig's axes: pick the sign
    # that brings the curled middle fingertip closer to the wrist.
    def tip_to_wrist(posed):
        return np.linalg.norm(posed["middle-finger-tip"][:3, 3] - posed["wrist"][:3, 3])
    if flex_sign is None:
        flex_sign = min((1, -1), key=lambda s: tip_to_wrist(flex_for(s)))
    posed = flex_for(flex_sign)
    print("flex sign", flex_sign)

    prim = gltf["meshes"][0]["primitives"][0]
    pos = accessor(gltf, blob, prim["attributes"]["POSITION"]).astype(float)
    nrm = accessor(gltf, blob, prim["attributes"]["NORMAL"]).astype(float)
    jnt = accessor(gltf, blob, prim["attributes"]["JOINTS_0"]).astype(int)
    wts = accessor(gltf, blob, prim["attributes"]["WEIGHTS_0"]).astype(float)
    idx = accessor(gltf, blob, prim["indices"]).reshape(-1).astype(np.uint32)

    skin_m = np.array([posed[nodes[j]["name"]] @ ibm[k] for k, j in enumerate(joints)])
    rest_m = np.array([rest[nodes[j]["name"]] @ ibm[k] for k, j in enumerate(joints)])
    print("rest skin ≈ identity:", np.allclose(rest_m, np.eye(4), atol=1e-4))

    blend = np.einsum("vk,vkij->vij", wts / wts.sum(1, keepdims=True), skin_m[jnt])
    p = np.einsum("vij,vj->vi", blend[:, :3, :3], pos) + blend[:, :3, 3]
    n = np.einsum("vij,vj->vi", blend[:, :3, :3], nrm)
    n /= np.linalg.norm(n, axis=1, keepdims=True)

    # The ring's frame: seat at the origin, finger down +X, back of hand +Y.
    knuckle = posed["index-finger-phalanx-proximal"][:3, 3]
    middle_joint = posed["index-finger-phalanx-intermediate"][:3, 3]
    x = middle_joint - knuckle
    x /= np.linalg.norm(x)
    seat = knuckle + (middle_joint - knuckle) * SEAT_ALONG
    # Back of the hand: away from where the folded fingers went.
    folded = posed["middle-finger-tip"][:3, 3] - seat
    y = -(folded - x * folded.dot(x))
    y /= np.linalg.norm(y)
    z = np.cross(x, y)
    basis = np.stack([x, y, z])
    p = (p - seat) @ basis.T
    n = n @ basis.T

    # Scale so the finger's widest point at the seat sits just inside the bore.
    # Only skin that belongs to that bone: its heaviest joint is the proximal
    # phalanx, so webbing and the neighbouring finger stay out of the sample.
    owner = jnt[np.arange(len(jnt)), wts.argmax(1)]
    bone = joints.index(names["index-finger-phalanx-proximal"])
    near = (np.abs(p[:, 0]) < 0.004) & (owner == bone)
    # The bone runs nearer the palm than the middle of the finger: centre the
    # ring on the flesh, not the joint axis.
    section = p[near][:, 1:]
    centre = (section.min(0) + section.max(0)) / 2
    p[:, 1:] -= centre
    ring_dist = np.linalg.norm(section - centre, axis=1)
    print("seat sample", near.sum(), "radii mm", np.round(np.percentile(ring_dist, [10, 50, 90, 100]) * 1000, 1))
    radius = ring_dist.max()
    scale = FIT_RADIUS / radius
    p *= scale
    print(f"finger radius at seat {radius * 1000:.1f} mm -> scale {scale:.1f}; {len(p)} verts, {len(idx) // 3} tris")

    # Game-weight mesh: weld its UV seams, subdivide once (Loop) and light it
    # with fresh smooth normals, so the finger reads as skin, not facets.
    p, idx = weld(p, idx)
    p, idx = loop_subdivide(p, idx)
    n = smooth_normals(p, idx)

    tip = ((posed["index-finger-tip"][:3, 3] - seat) @ basis.T)
    tip[1:] -= centre
    tip *= scale
    with open(out, "wb") as f:
        f.write(b"JCHD")
        f.write(struct.pack("<III", 1, len(p), len(idx)))
        f.write(struct.pack("<3f", *tip))
        f.write(p.astype("<f4").tobytes())
        f.write(n.astype("<f4").tobytes())
        f.write(idx.astype("<u2").tobytes())
    assert len(p) < 65536, "indices are 16-bit"
    print("wrote", out, "tip", np.round(tip, 2), f"{len(p)} verts after subdivision")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
