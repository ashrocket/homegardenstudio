//! Layout-bound rendering instructions and deterministic provenance summary.
use crate::{catalog, geometry, model::*, persist, scene};
use serde::Serialize;

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct BriefItem {
    pub id: String,
    pub label: String,
    pub dimensions_text: String,
    pub position_certainty: String,
    pub size_certainty: String,
}
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Brief {
    pub prompt: String,
    pub items: Vec<BriefItem>,
    pub uncertainties: Vec<String>,
    pub layout_hash: String,
}
fn feet(m: f64) -> String {
    let inches = (m / 0.0254).round() as u64;
    format!("{} ft {} in", inches / 12, inches % 12)
}
fn location(it: &Item, b: [f64; 4]) -> String {
    let third = |v: f64, lo: f64, hi: f64| {
        if hi - lo < 1e-9 {
            1
        } else if v < lo + (hi - lo) / 3.0 {
            0
        } else if v > lo + 2.0 * (hi - lo) / 3.0 {
            2
        } else {
            1
        }
    };
    let x = ["west", "", "east"][third(it.x, b[0], b[2])];
    let y = ["north", "", "south"][third(it.y, b[1], b[3])];
    let direction = match (x, y) {
        ("", "") => return "the centre of the plan".into(),
        (x, "") => x.into(),
        ("", y) => y.into(),
        (x, y) => format!("{y}-{x}"),
    };
    format!("the {direction} part of the plan")
}
pub fn render_brief(p: &Project, style: Option<&str>) -> Brief {
    let mut uncertainties = Vec::new();
    match (&p.site.boundary, p.site.boundary_certainty) {
        (None, _) => uncertainties.push("No site boundary was drawn.".into()),
        (Some(_), Certainty::Estimated) => {
            uncertainties.push("The site boundary is estimated.".into())
        }
        _ => {}
    }
    for s in &p.site.structures {
        if s.certainty == Certainty::Estimated {
            uncertainties.push(format!("{}: outline is estimated.", s.name));
        }
    }
    let bounds = p
        .site
        .boundary
        .as_ref()
        .map(|b| geometry::bbox(b))
        .unwrap_or_else(|| scene::plan_bounds(p));
    let mut prompt=String::from("Create a photorealistic garden visualization from this plan and its supplied source context.\nPreserve every item's specified position, dimensions, orientation and footprint.\nDo not add, remove or relocate items, buildings, fences or boundaries.\nKeep uncertain geometry visibly identified; this plan is not a survey.\n");
    if let Some(style) = style.filter(|s| !s.trim().is_empty()) {
        prompt.push_str(&format!("Style: {style}.\n"));
    }
    prompt.push_str(&format!(
        "Plan: {}. Coordinates are metres: x east, y south; rotations clockwise.\n",
        p.name
    ));
    if let Some(b) = &p.site.boundary {
        prompt.push_str(&format!("Boundary vertices (x,y): {}.\n", points(b)));
    }
    for s in &p.site.structures {
        prompt.push_str(&format!(
            "Existing {} [{}]: outline {}; height {:.3} m; {} outline. Preserve it.\n",
            s.name,
            s.id,
            points(&s.outline),
            s.height,
            s.certainty.as_str()
        ));
    }
    let mut items = Vec::new();
    for (n, it) in p.items.iter().enumerate() {
        let dimensions_text = format!(
            "{:.2} m x {:.2} m x {:.2} m ({} x {} x {})",
            it.width,
            it.depth,
            it.height,
            feet(it.width),
            feet(it.depth),
            feet(it.height)
        );
        let position = match it.position_certainty {
            PositionCertainty::Measured => "measured position (user field assertion)",
            PositionCertainty::Estimated => {
                uncertainties.push(format!("{}: position is estimated.", it.name));
                "estimated position"
            }
            PositionCertainty::UnregisteredPhoto => {
                uncertainties.push(format!(
                    "{}: position was traced from an unscaled photo and is approximate.",
                    it.name
                ));
                "position traced from an unscaled photo"
            }
        };
        let size = match it.size_certainty {
            SizeCertainty::Measured => "measured size (user field assertion)",
            SizeCertainty::Estimated => {
                uncertainties.push(format!("{}: size is estimated.", it.name));
                "estimated size"
            }
            SizeCertainty::ProductListing => {
                uncertainties.push(format!("{}: size comes from the product listing.", it.name));
                "size from the product listing"
            }
        };
        prompt.push_str(&format!("{}. {} [{}], {}: {}; in {}; exact centre ({:.6}, {:.6}) m, width {:.6} m, depth {:.6} m, height {:.6} m, rotation {:.6} degrees; {}; {}.\n", n+1,it.name,it.id,catalog::label(it.kind),dimensions_text,location(it,bounds),it.x,it.y,it.width,it.depth,it.height,it.rotation,position,size));
        if it.kind == Kind::BinScreen {
            prompt.push_str("Use two walls along the back and left edges, forming an L; no roof or front wall.\n");
        }
        if it.kind == Kind::FirePit {
            prompt.push_str(&format!(
                "Contained gravel circle; pit diameter {:.3} m, required clearance {:.3} m.\n",
                catalog::pit_diameter(it),
                catalog::fire_clearance(it)
            ));
        }
        if !it.params.is_empty() {
            for (k, v) in &it.params {
                prompt.push_str(&format!("Parameter {k}: {v}.\n"));
            }
        }
        if !it.source_ids.is_empty() {
            prompt.push_str(&format!(
                "Supporting source IDs: {}.\n",
                it.source_ids.join(", ")
            ));
        }
        items.push(BriefItem {
            id: it.id.clone(),
            label: it.name.clone(),
            dimensions_text,
            position_certainty: it.position_certainty.as_str().into(),
            size_certainty: it.size_certainty.as_str().into(),
        });
    }
    for source in &p.sources {
        prompt.push_str(&format!(
            "Source {}: {} ({:?}); original SHA-256 {}. {}\n",
            source.id,
            source.title,
            source.kind,
            source.sha256,
            if source.registration.is_some() {
                "Two-point scale is approximate and does not establish measured site coordinates."
            } else {
                "No measured coordinate registration."
            }
        ));
    }
    if let Some(b) = &p.backdrop {
        prompt.push_str(&format!("Backdrop {}: origin ({:.6},{:.6}) m, rotation {:.6} degrees; preserve source context.\n",b.source_id,b.x,b.y,b.rotation));
    }
    for u in &uncertainties {
        prompt.push_str(u);
        prompt.push('\n');
    }
    let hash = persist::compact(p)
        .bytes()
        .fold(0xcbf29ce484222325u64, |h, b| {
            (h ^ u64::from(b)).wrapping_mul(0x100000001b3)
        });
    Brief {
        prompt,
        items,
        uncertainties,
        layout_hash: format!("{hash:016x}"),
    }
}
fn points(p: &[Pt]) -> String {
    p.iter()
        .map(|v| format!("({:.6},{:.6})", v[0], v[1]))
        .collect::<Vec<_>>()
        .join(", ")
}
