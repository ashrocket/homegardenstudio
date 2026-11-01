//! Deterministic native 3D primitives; plan y maps to scene z.
use crate::{catalog, geometry, model::*};
use serde::Serialize;

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Primitive {
    pub item_id: String,
    pub shape: &'static str,
    pub center: [f64; 3],
    pub size: [f64; 3],
    pub rotation_y: f64,
    pub material: &'static str,
}
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Ground {
    pub min: Pt,
    pub max: Pt,
}
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Scene {
    pub primitives: Vec<Primitive>,
    pub ground: Ground,
}

/// All actual footprints, independent of view projection.
pub fn plan_bounds(p: &Project) -> [f64; 4] {
    let mut points = Vec::new();
    if let Some(b) = &p.site.boundary {
        points.extend_from_slice(b);
    }
    for s in &p.site.structures {
        points.extend_from_slice(&s.outline);
    }
    for it in &p.items {
        points.extend(geometry::footprint(it));
    }
    if points.is_empty() {
        [0.0; 4]
    } else {
        geometry::bbox(&points)
    }
}

pub fn scene(p: &Project) -> Scene {
    let mut primitives = Vec::new();
    for s in &p.site.structures {
        let b = geometry::bbox(&s.outline);
        primitives.push(Primitive {
            item_id: s.id.clone(),
            shape: "box",
            center: [(b[0] + b[2]) / 2.0, s.height / 2.0, (b[1] + b[3]) / 2.0].map(geometry::clean),
            size: [b[2] - b[0], s.height, b[3] - b[1]].map(geometry::clean),
            rotation_y: 0.0,
            material: "structure",
        });
    }
    for it in &p.items {
        let (w, d, h) = (it.width, it.depth, it.height);
        let (sin, cos) = it.rotation.to_radians().sin_cos();
        let mut part = |shape, offset: [f64; 3], size: [f64; 3], material| {
            primitives.push(Primitive {
                item_id: it.id.clone(),
                shape,
                center: [
                    it.x + offset[0] * cos - offset[2] * sin,
                    offset[1],
                    it.y + offset[0] * sin + offset[2] * cos,
                ]
                .map(geometry::clean),
                size: size.map(geometry::clean),
                rotation_y: geometry::clean(-it.rotation),
                material,
            });
        };
        match it.kind {
            Kind::Plant => part("sphere", [0.0, h / 2.0, 0.0], [w, h, d], "foliage"),
            Kind::Tree => {
                let trunk = 0.3_f64.min(w).min(d);
                part(
                    "cylinder",
                    [0.0, h * 0.2, 0.0],
                    [trunk, h * 0.4, trunk],
                    "wood_dark",
                );
                part("sphere", [0.0, h * 0.7, 0.0], [w, h * 0.6, d], "foliage");
            }
            Kind::Pond => part("cylinder", [0.0, 0.01, 0.0], [w, 0.02, d], "water"),
            Kind::FirePit => {
                let pit = catalog::pit_diameter(it).min(w).min(d);
                part("cylinder", [0.0, 0.01, 0.0], [w, 0.02, d], "gravel");
                part("cylinder", [0.0, 0.2, 0.0], [pit, 0.4, pit], "stone");
                part(
                    "cylinder",
                    [0.0, 0.55, 0.0],
                    [pit * 0.5, 0.3, pit * 0.5],
                    "fire",
                );
            }
            Kind::Pergola => {
                let t = 0.15_f64.min(w).min(d);
                let beam = 0.15_f64.min(h * 0.75);
                let slat = 0.05_f64.min(h * 0.25);
                let post_h = (h - beam - slat).max(0.0);
                for x in [-w / 2.0 + t / 2.0, w / 2.0 - t / 2.0] {
                    for z in [-d / 2.0 + t / 2.0, d / 2.0 - t / 2.0] {
                        part("box", [x, post_h / 2.0, z], [t, post_h, t], "wood_dark");
                    }
                }
                for z in [-d / 2.0 + t / 2.0, d / 2.0 - t / 2.0] {
                    part(
                        "box",
                        [0.0, (h - slat - beam / 2.0).max(beam / 2.0), z],
                        [w, beam, t],
                        "wood_dark",
                    );
                }
                let sw = 0.06_f64.min(w);
                for n in 0..8 {
                    let x = -w / 2.0 + sw / 2.0 + (w - sw) * f64::from(n) / 7.0;
                    part("box", [x, h - slat / 2.0, 0.0], [sw, slat, d], "wood_light");
                }
            }
            Kind::BinScreen => {
                let t = catalog::wall_thickness(it).min(w / 2.0).min(d / 2.0);
                part(
                    "box",
                    [0.0, h / 2.0, -d / 2.0 + t / 2.0],
                    [w, h, t],
                    "wood_light",
                );
                part(
                    "box",
                    [-w / 2.0 + t / 2.0, h / 2.0, t / 2.0],
                    [t, h, d - t],
                    "wood_light",
                );
            }
            kind => {
                let material = match kind {
                    Kind::Sauna => "wood_dark",
                    Kind::Patio => "stone",
                    Kind::Path => "gravel",
                    Kind::Structure => "structure",
                    _ => "wood_light",
                };
                part("box", [0.0, h / 2.0, 0.0], [w, h, d], material);
            }
        }
    }
    let b = plan_bounds(p);
    Scene {
        primitives,
        ground: Ground {
            min: [b[0] - 2.0, b[1] - 2.0].map(geometry::clean),
            max: [b[2] + 2.0, b[3] + 2.0].map(geometry::clean),
        },
    }
}
