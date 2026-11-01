//! Plan geometry: footprints, containment, intersection, overlap and handle maths.
//!
//! Plan space is `+x` right, `+y` down. `rotation` is degrees clockwise on screen, which in these
//! coordinates is the ordinary rotation matrix `[cos -sin; sin cos]`.

use crate::catalog::{self, Shape};
use crate::model::{Item, Kind, Pt, MAX_DIM, MIN_DIM};

/// Distance below which two points count as touching (metres).
pub const EPS: f64 = 1e-9;
/// Inward nudge used to look at the interior side of an edge (metres).
const NUDGE: f64 = 1e-6;
/// Boundary pieces shorter than this are ignored by the overlap test (metres).
const MIN_PIECE: f64 = 1e-5;
const CIRCLE_SEGMENTS: usize = 32;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Side {
    Outside,
    Boundary,
    Inside,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Transform {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub depth: f64,
    pub rotation: f64,
}

/// Normalises degrees into `[0, 360)`. Non-finite input gives 0.
pub fn normalize_deg(a: f64) -> f64 {
    if !a.is_finite() {
        return 0.0;
    }
    let mut r = a % 360.0;
    if r < 0.0 {
        r += 360.0;
    }
    if r >= 360.0 || r == 0.0 {
        0.0
    } else {
        r
    }
}

/// Rounds to a nanometre and removes negative zero, so output JSON is stable.
pub fn clean(v: f64) -> f64 {
    let r = (v * 1e9).round() / 1e9;
    if r == 0.0 {
        0.0
    } else {
        r
    }
}

pub fn clean_pt(p: Pt) -> Pt {
    [clean(p[0]), clean(p[1])]
}

/// `(sin, cos)` of an angle in degrees, exact for multiples of 90.
pub fn sin_cos_deg(deg: f64) -> (f64, f64) {
    let n = normalize_deg(deg);
    if n == 0.0 {
        (0.0, 1.0)
    } else if n == 90.0 {
        (1.0, 0.0)
    } else if n == 180.0 {
        (0.0, -1.0)
    } else if n == 270.0 {
        (-1.0, 0.0)
    } else {
        n.to_radians().sin_cos()
    }
}

/// Rotates a point about the origin, clockwise on screen.
pub fn rotate(p: Pt, deg: f64) -> Pt {
    let (s, c) = sin_cos_deg(deg);
    [p[0] * c - p[1] * s, p[0] * s + p[1] * c]
}

fn sub(a: Pt, b: Pt) -> Pt {
    [a[0] - b[0], a[1] - b[1]]
}

fn dot(a: Pt, b: Pt) -> f64 {
    a[0] * b[0] + a[1] * b[1]
}

fn cross(a: Pt, b: Pt) -> f64 {
    a[0] * b[1] - a[1] * b[0]
}

fn len(a: Pt) -> f64 {
    dot(a, a).sqrt()
}

pub fn distance(a: Pt, b: Pt) -> f64 {
    len(sub(a, b))
}

fn place(local: &[Pt], x: f64, y: f64, rotation: f64) -> Vec<Pt> {
    let (s, c) = sin_cos_deg(rotation);
    local
        .iter()
        .map(|p| [x + p[0] * c - p[1] * s, y + p[0] * s + p[1] * c])
        .collect()
}

/// Footprint polygon of a kind at a transform. Rect: four corners clockwise from top-left.
/// Circle and ellipse: a 32-gon. L-shape: six points.
pub fn footprint_of(kind: Kind, t: &Transform, wall: f64) -> Vec<Pt> {
    let (w, d) = (t.width, t.depth);
    let local: Vec<Pt> = match catalog::shape(kind) {
        Shape::Rect => vec![
            [-w / 2.0, -d / 2.0],
            [w / 2.0, -d / 2.0],
            [w / 2.0, d / 2.0],
            [-w / 2.0, d / 2.0],
        ],
        Shape::Circle | Shape::Ellipse => (0..CIRCLE_SEGMENTS)
            .map(|i| {
                let (s, c) = sin_cos_deg(360.0 * i as f64 / CIRCLE_SEGMENTS as f64);
                [w / 2.0 * c, d / 2.0 * s]
            })
            .collect(),
        Shape::LShape => {
            let th = wall.min(w / 2.0).min(d / 2.0);
            vec![
                [-w / 2.0, -d / 2.0],
                [w / 2.0, -d / 2.0],
                [w / 2.0, -d / 2.0 + th],
                [-w / 2.0 + th, -d / 2.0 + th],
                [-w / 2.0 + th, d / 2.0],
                [-w / 2.0, d / 2.0],
            ]
        }
    };
    place(&local, t.x, t.y, t.rotation)
}

pub fn item_transform(item: &Item) -> Transform {
    Transform {
        x: item.x,
        y: item.y,
        width: item.width,
        depth: item.depth,
        rotation: item.rotation,
    }
}

pub fn footprint(item: &Item) -> Vec<Pt> {
    footprint_of(
        item.kind,
        &item_transform(item),
        catalog::wall_thickness(item),
    )
}

pub fn signed_area(poly: &[Pt]) -> f64 {
    let n = poly.len();
    let mut s = 0.0;
    for i in 0..n {
        let a = poly[i];
        let b = poly[(i + 1) % n];
        s += a[0] * b[1] - b[0] * a[1];
    }
    s / 2.0
}

pub fn polygon_area(poly: &[Pt]) -> f64 {
    signed_area(poly).abs()
}

/// `(min_x, min_y, max_x, max_y)`. Empty input gives zeros.
pub fn bbox(poly: &[Pt]) -> [f64; 4] {
    if poly.is_empty() {
        return [0.0; 4];
    }
    let mut b = [f64::MAX, f64::MAX, f64::MIN, f64::MIN];
    for p in poly {
        b[0] = b[0].min(p[0]);
        b[1] = b[1].min(p[1]);
        b[2] = b[2].max(p[0]);
        b[3] = b[3].max(p[1]);
    }
    b
}

pub fn bbox_overlap(a: &[f64; 4], b: &[f64; 4], slack: f64) -> bool {
    a[0] <= b[2] + slack && b[0] <= a[2] + slack && a[1] <= b[3] + slack && b[1] <= a[3] + slack
}

pub fn dist_point_segment(p: Pt, a: Pt, b: Pt) -> f64 {
    let ab = sub(b, a);
    let l2 = dot(ab, ab);
    if l2 < 1e-24 {
        return distance(p, a);
    }
    let t = (dot(sub(p, a), ab) / l2).clamp(0.0, 1.0);
    distance(p, [a[0] + ab[0] * t, a[1] + ab[1] * t])
}

/// Even-odd point classification. Points within [`EPS`] of an edge are on the boundary.
pub fn classify(p: Pt, poly: &[Pt]) -> Side {
    let n = poly.len();
    let mut inside = false;
    for i in 0..n {
        let a = poly[i];
        let b = poly[(i + 1) % n];
        if dist_point_segment(p, a, b) <= EPS {
            return Side::Boundary;
        }
        if (a[1] > p[1]) != (b[1] > p[1]) {
            let x_at = a[0] + (p[1] - a[1]) * (b[0] - a[0]) / (b[1] - a[1]);
            if p[0] < x_at {
                inside = !inside;
            }
        }
    }
    if inside {
        Side::Inside
    } else {
        Side::Outside
    }
}

/// Distance from a point to the region of a polygon: zero inside or on it.
pub fn dist_point_polygon(p: Pt, poly: &[Pt]) -> f64 {
    if classify(p, poly) != Side::Outside {
        return 0.0;
    }
    dist_point_boundary(p, poly)
}

pub fn dist_point_boundary(p: Pt, poly: &[Pt]) -> f64 {
    let n = poly.len();
    let mut best = f64::MAX;
    for i in 0..n {
        best = best.min(dist_point_segment(p, poly[i], poly[(i + 1) % n]));
    }
    best
}

/// Parameters `t` (0..=1) along `a0 -> a1` where it meets `b0 -> b1`. A collinear overlap yields
/// both ends of the shared stretch.
fn seg_params(a0: Pt, a1: Pt, b0: Pt, b1: Pt, out: &mut Vec<f64>) {
    let r = sub(a1, a0);
    let s = sub(b1, b0);
    let rl = len(r);
    if rl < 1e-12 {
        return;
    }
    let sl = len(s);
    let qp = sub(b0, a0);
    if sl < 1e-12 {
        if dist_point_segment(b0, a0, a1) <= EPS {
            out.push((dot(qp, r) / (rl * rl)).clamp(0.0, 1.0));
        }
        return;
    }
    let denom = cross(r, s);
    if denom.abs() > 1e-12 * rl * sl {
        let t = cross(qp, s) / denom;
        let u = cross(qp, r) / denom;
        let et = EPS / rl;
        let eu = EPS / sl;
        if t >= -et && t <= 1.0 + et && u >= -eu && u <= 1.0 + eu {
            out.push(t.clamp(0.0, 1.0));
        }
    } else if cross(qp, r).abs() / rl <= EPS {
        let t0 = dot(qp, r) / (rl * rl);
        let t1 = dot(sub(b1, a0), r) / (rl * rl);
        let lo = t0.min(t1).max(0.0);
        let hi = t0.max(t1).min(1.0);
        if lo <= hi + EPS / rl {
            out.push(lo.min(1.0));
            out.push(hi.max(0.0));
        }
    }
}

/// Sorted cut parameters of edge `a0 -> a1` against every edge of `poly`, including 0 and 1.
fn edge_cuts(a0: Pt, a1: Pt, poly: &[Pt]) -> Vec<f64> {
    let mut v = vec![0.0, 1.0];
    let n = poly.len();
    for i in 0..n {
        seg_params(a0, a1, poly[i], poly[(i + 1) % n], &mut v);
    }
    v.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    v.dedup_by(|a, b| (*a - *b).abs() < 1e-12);
    v
}

fn lerp(a: Pt, b: Pt, t: f64) -> Pt {
    [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t]
}

/// True when the two polygons share any point, including a single touching point.
pub fn intersects(a: &[Pt], b: &[Pt]) -> bool {
    if a.is_empty() || b.is_empty() {
        return false;
    }
    if !bbox_overlap(&bbox(a), &bbox(b), EPS) {
        return false;
    }
    let (na, nb) = (a.len(), b.len());
    let mut scratch = Vec::new();
    for i in 0..na {
        for j in 0..nb {
            scratch.clear();
            seg_params(a[i], a[(i + 1) % na], b[j], b[(j + 1) % nb], &mut scratch);
            if !scratch.is_empty() {
                return true;
            }
        }
    }
    classify(a[0], b) != Side::Outside || classify(b[0], a) != Side::Outside
}

/// Does some part of `a`'s boundary have `b`'s interior just inside `a`?
fn boundary_enters(a: &[Pt], b: &[Pt]) -> bool {
    let area = signed_area(a);
    if area.abs() < 1e-12 {
        return false;
    }
    let n = a.len();
    for i in 0..n {
        let p = a[i];
        let q = a[(i + 1) % n];
        let d = sub(q, p);
        let l = len(d);
        if l < MIN_PIECE {
            continue;
        }
        let inward = if area > 0.0 {
            [-d[1] / l, d[0] / l]
        } else {
            [d[1] / l, -d[0] / l]
        };
        let cuts = edge_cuts(p, q, b);
        for w in cuts.windows(2) {
            if (w[1] - w[0]) * l < MIN_PIECE {
                continue;
            }
            let m = lerp(p, q, (w[0] + w[1]) / 2.0);
            let probe = [m[0] + inward[0] * NUDGE, m[1] + inward[1] * NUDGE];
            if classify(probe, b) == Side::Inside {
                return true;
            }
        }
    }
    false
}

/// True when the interiors of two simple polygons overlap with positive area. Shared edges and
/// corners do not count.
pub fn overlaps_with_area(a: &[Pt], b: &[Pt]) -> bool {
    if a.len() < 3 || b.len() < 3 {
        return false;
    }
    if !bbox_overlap(&bbox(a), &bbox(b), -MIN_PIECE) {
        return false;
    }
    boundary_enters(a, b) || boundary_enters(b, a)
}

/// True when `inner` lies inside `outer` (even-odd, so concave notches and holes count as
/// outside). Touching the boundary from inside is allowed.
pub fn contains_polygon(outer: &[Pt], inner: &[Pt]) -> bool {
    if outer.len() < 3 || inner.is_empty() {
        return false;
    }
    let n = inner.len();
    for i in 0..n {
        let p = inner[i];
        let q = inner[(i + 1) % n];
        let cuts = edge_cuts(p, q, outer);
        if classify(p, outer) == Side::Outside {
            return false;
        }
        for w in cuts.windows(2) {
            let m = lerp(p, q, (w[0] + w[1]) / 2.0);
            if classify(m, outer) == Side::Outside {
                return false;
            }
        }
    }
    // Any stretch of the outer boundary strictly inside `inner` means a notch or hole pokes in.
    let m = outer.len();
    for i in 0..m {
        let p = outer[i];
        let q = outer[(i + 1) % m];
        if classify(p, inner) == Side::Inside {
            return false;
        }
        for w in edge_cuts(p, q, inner).windows(2) {
            if classify(lerp(p, q, (w[0] + w[1]) / 2.0), inner) == Side::Inside {
                return false;
            }
        }
    }
    true
}

/// True when the open disc of `radius` around `centre` reaches into the polygon region.
pub fn disc_reaches_polygon(centre: Pt, radius: f64, poly: &[Pt]) -> bool {
    dist_point_polygon(centre, poly) < radius - EPS
}

/// Pointer-driven resize. The corner opposite `handle` stays fixed. Width and depth are clamped to
/// the limits and rounded to a millimetre. Circles always resize proportionally.
pub fn resize_from_handle(
    item: &Item,
    handle: [f64; 2],
    point: Pt,
    proportional: bool,
) -> Transform {
    let (s, c) = sin_cos_deg(item.rotation);
    let hx = if handle[0] < 0.0 { -1.0 } else { 1.0 };
    let hy = if handle[1] < 0.0 { -1.0 } else { 1.0 };
    let (w, d) = (item.width, item.depth);
    let (ax, ay) = (-hx * w / 2.0, -hy * d / 2.0);
    let anchor = [item.x + ax * c - ay * s, item.y + ax * s + ay * c];
    let v = sub(point, anchor);
    let local = [v[0] * c + v[1] * s, -v[0] * s + v[1] * c];
    let mut nw = hx * local[0];
    let mut nd = hy * local[1];
    if proportional || catalog::is_circle(item.kind) {
        let k = (nw / w).max(nd / d);
        let k_min = (MIN_DIM / w).max(MIN_DIM / d);
        let k_max = (MAX_DIM / w).min(MAX_DIM / d);
        let k = k.clamp(k_min, k_max.max(k_min));
        nw = w * k;
        nd = d * k;
    } else {
        nw = nw.clamp(MIN_DIM, MAX_DIM);
        nd = nd.clamp(MIN_DIM, MAX_DIM);
    }
    nw = ((nw * 1000.0).round() / 1000.0).clamp(MIN_DIM, MAX_DIM);
    nd = ((nd * 1000.0).round() / 1000.0).clamp(MIN_DIM, MAX_DIM);
    if catalog::is_circle(item.kind) {
        nd = nw;
    }
    let (ox, oy) = (hx * nw / 2.0, hy * nd / 2.0);
    Transform {
        x: anchor[0] + ox * c - oy * s,
        y: anchor[1] + ox * s + oy * c,
        width: nw,
        depth: nd,
        rotation: item.rotation,
    }
}

/// Pointer-driven rotation about the item centre. Returns `(new rotation, delta)` in degrees. The
/// new rotation is snapped to 15 degrees (`snap`) or 1 degree.
pub fn rotate_from_handle(item: &Item, start: Pt, point: Pt, snap: bool) -> (f64, f64) {
    let c = [item.x, item.y];
    let (v0, v1) = (sub(start, c), sub(point, c));
    if len(v0) < 1e-9 || len(v1) < 1e-9 {
        return (normalize_deg(item.rotation), 0.0);
    }
    let a0 = v0[1].atan2(v0[0]).to_degrees();
    let a1 = v1[1].atan2(v1[0]).to_degrees();
    let mut delta = (a1 - a0) % 360.0;
    if delta > 180.0 {
        delta -= 360.0;
    } else if delta <= -180.0 {
        delta += 360.0;
    }
    let step = if snap { 15.0 } else { 1.0 };
    let raw = item.rotation + delta;
    let snapped = normalize_deg((raw / step).round() * step);
    (snapped, clean(delta))
}
