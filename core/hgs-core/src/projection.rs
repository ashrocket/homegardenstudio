//! Isometric faces for the 2.5D view.
//!
//! Plan points are rotated by the view angle (clockwise, like item rotation), then projected with
//! `sx = (x - y) * cos30`, `sy = (x + y) * sin30 - z`. The viewer looks from the `+x +y` side, so a
//! side face is visible when its outward normal satisfies `nx + ny > 0`.

use crate::geometry::{bbox, clean, rotate, signed_area};
use crate::model::{Kind, Project, Pt};
use serde::Serialize;

const COS30: f64 = 0.866_025_403_784_438_6;
const SIN30: f64 = 0.5;
/// Items shorter than this are drawn as one flat ground face.
pub const GROUND_MAX_HEIGHT: f64 = 0.03;
const SLACK: f64 = 1e-9;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    Top,
    Left,
    Right,
    Ground,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Face {
    pub item_id: String,
    pub kind: Kind,
    pub role: Role,
    pub points: Vec<Pt>,
    pub depth: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct IsoBounds {
    pub min_x: f64,
    pub min_y: f64,
    pub max_x: f64,
    pub max_y: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Isometric {
    pub faces: Vec<Face>,
    pub bounds: IsoBounds,
}

struct Prism {
    id: String,
    kind: Kind,
    outline: Vec<Pt>,
    height: f64,
}

fn project(p: Pt, z: f64) -> Pt {
    [
        clean((p[0] - p[1]) * COS30),
        clean((p[0] + p[1]) * SIN30 - z),
    ]
}

/// Faces for every structure and item, sorted back to front.
pub fn isometric(p: &Project, view_angle: f64) -> Isometric {
    let mut prisms: Vec<Prism> = Vec::new();
    for s in &p.site.structures {
        prisms.push(Prism {
            id: s.id.clone(),
            kind: Kind::Structure,
            outline: s.outline.clone(),
            height: s.height,
        });
    }
    for it in &p.items {
        prisms.push(Prism {
            id: it.id.clone(),
            kind: it.kind,
            outline: crate::geometry::footprint(it),
            height: it.height,
        });
    }

    let mut placed: Vec<(f64, Prism, Vec<Pt>)> = prisms
        .into_iter()
        .map(|pr| {
            let rotated: Vec<Pt> = pr.outline.iter().map(|q| rotate(*q, view_angle)).collect();
            let b = bbox(&rotated);
            let depth = (b[0] + b[2]) / 2.0 + (b[1] + b[3]) / 2.0;
            (depth, pr, rotated)
        })
        .collect();
    placed.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));

    let mut faces = Vec::new();
    for (depth, pr, rotated) in &placed {
        let depth = clean(*depth);
        if pr.height < GROUND_MAX_HEIGHT {
            faces.push(Face {
                item_id: pr.id.clone(),
                kind: pr.kind,
                role: Role::Ground,
                points: rotated.iter().map(|q| project(*q, 0.0)).collect(),
                depth,
            });
            continue;
        }
        let orientation = signed_area(rotated);
        let n = rotated.len();
        let mut sides: Vec<(f64, Face)> = Vec::new();
        for i in 0..n {
            let (a, b) = (rotated[i], rotated[(i + 1) % n]);
            let (dx, dy) = (b[0] - a[0], b[1] - a[1]);
            let len = (dx * dx + dy * dy).sqrt();
            if len < 1e-12 {
                continue;
            }
            // Outward normal: right of the edge for a positive area, left for a negative one.
            let (nx, ny) = if orientation > 0.0 {
                (dy / len, -dx / len)
            } else {
                (-dy / len, dx / len)
            };
            if nx + ny <= SLACK {
                continue;
            }
            let role = if ny > nx + SLACK {
                Role::Left
            } else {
                Role::Right
            };
            let mid = (a[0] + b[0]) / 2.0 + (a[1] + b[1]) / 2.0;
            sides.push((
                mid,
                Face {
                    item_id: pr.id.clone(),
                    kind: pr.kind,
                    role,
                    points: vec![
                        project(a, 0.0),
                        project(b, 0.0),
                        project(b, pr.height),
                        project(a, pr.height),
                    ],
                    depth,
                },
            ));
        }
        sides.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
        faces.extend(sides.into_iter().map(|(_, f)| f));
        faces.push(Face {
            item_id: pr.id.clone(),
            kind: pr.kind,
            role: Role::Top,
            points: rotated.iter().map(|q| project(*q, pr.height)).collect(),
            depth,
        });
    }

    let all: Vec<Pt> = faces
        .iter()
        .flat_map(|f| f.points.iter().copied())
        .collect();
    let b = bbox(&all);
    Isometric {
        faces,
        bounds: IsoBounds {
            min_x: b[0],
            min_y: b[1],
            max_x: b[2],
            max_y: b[3],
        },
    }
}
