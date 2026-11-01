//! Catalog defaults and per-kind parameter helpers.

use crate::model::{Item, Kind, Product, SizeCertainty};
use serde::Serialize;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Shape {
    Circle,
    Ellipse,
    Rect,
    LShape,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct CatalogEntry {
    pub kind: Kind,
    pub label: &'static str,
    pub category: &'static str,
    pub shape: Shape,
    pub width: f64,
    pub depth: f64,
    pub height: f64,
    pub size_certainty: SizeCertainty,
    pub description: &'static str,
    pub product: Option<Product>,
}

pub const DEFAULT_PIT_DIAMETER: f64 = 1.07;
pub const DEFAULT_FIRE_CLEARANCE: f64 = 3.05;
pub const DEFAULT_WALL_THICKNESS: f64 = 0.05;
pub const DEFAULT_WATER_DEPTH: f64 = 0.6;

pub fn shape(kind: Kind) -> Shape {
    match kind {
        Kind::Plant | Kind::Tree | Kind::FirePit => Shape::Circle,
        Kind::Pond => Shape::Ellipse,
        Kind::BinScreen => Shape::LShape,
        _ => Shape::Rect,
    }
}

pub fn is_circle(kind: Kind) -> bool {
    shape(kind) == Shape::Circle
}

pub fn label(kind: Kind) -> &'static str {
    match kind {
        Kind::Plant => "Plant",
        Kind::Tree => "Tree",
        Kind::Pond => "Pond",
        Kind::FirePit => "Fire pit",
        Kind::Pergola => "Pergola",
        Kind::Sauna => "Sauna",
        Kind::ToolShed => "Tool shed",
        Kind::BinScreen => "Bin screen",
        Kind::Patio => "Patio",
        Kind::RaisedBed => "Raised bed",
        Kind::Path => "Path",
        Kind::Fence => "Fence",
        Kind::PrivacyScreen => "Privacy screen",
        Kind::Structure => "Structure",
    }
}

fn category(kind: Kind) -> &'static str {
    match kind {
        Kind::Plant | Kind::Tree | Kind::RaisedBed => "plants",
        Kind::Pond => "water",
        Kind::FirePit => "fire",
        Kind::Pergola | Kind::Sauna | Kind::ToolShed | Kind::Structure => "structures",
        Kind::Patio | Kind::Path => "hardscape",
        Kind::BinScreen | Kind::Fence | Kind::PrivacyScreen => "screens",
    }
}

fn description(kind: Kind) -> &'static str {
    match kind {
        Kind::Plant => "A shrub or flowering plant.",
        Kind::Tree => "A tree with a trunk and canopy.",
        Kind::Pond => "A small pond with a flat water surface.",
        Kind::FirePit => "A fire pit on a gravel pad. Checked for clearance from buildings.",
        Kind::Pergola => "A freestanding pergola with a slatted roof.",
        Kind::Sauna => "An outdoor cube sauna.",
        Kind::ToolShed => "A small tool shed.",
        Kind::BinScreen => "An L-shaped, roofless screen for bins.",
        Kind::Patio => "A paved patio.",
        Kind::RaisedBed => "A raised planting bed.",
        Kind::Path => "A garden path.",
        Kind::Fence => "A straight fence section.",
        Kind::PrivacyScreen => "A solid privacy screen.",
        Kind::Structure => "A generic building or outbuilding.",
    }
}

pub fn default_size(kind: Kind) -> (f64, f64, f64) {
    match kind {
        Kind::Plant => (0.6, 0.6, 0.6),
        Kind::Tree => (3.0, 3.0, 5.0),
        Kind::Pond => (2.4384, 1.8288, 0.0),
        Kind::FirePit => (4.2672, 4.2672, 0.4),
        Kind::Pergola => (3.6068, 2.9972, 2.2035),
        Kind::Sauna => (2.2098, 2.0066, 2.2098),
        Kind::ToolShed => (1.8288, 1.2192, 2.1336),
        Kind::BinScreen => (1.8288, 0.9144, 1.3716),
        Kind::Patio => (3.6576, 3.6576, 0.05),
        Kind::RaisedBed => (2.4384, 1.2192, 0.3),
        Kind::Path => (3.0, 0.9, 0.02),
        Kind::Fence => (3.6576, 0.05, 1.8288),
        Kind::PrivacyScreen => (3.6576, 0.3, 1.8288),
        Kind::Structure => (6.0, 4.0, 3.0),
    }
}

pub fn default_size_certainty(kind: Kind) -> SizeCertainty {
    match kind {
        Kind::Pergola | Kind::Sauna => SizeCertainty::ProductListing,
        _ => SizeCertainty::Estimated,
    }
}

pub fn preset_product(kind: Kind) -> Option<Product> {
    match kind {
        Kind::Pergola => Some(Product {
            title: "Aurora pergola, listed 142 x 118 x 86.75 in".to_string(),
            url: "https://www.wayfair.com/home/pdp/-eevb1318.html".to_string(),
            listed_dimensions: "142 in W x 118 in L x 86.75 in H".to_string(),
        }),
        Kind::Sauna => Some(Product {
            title: "Refugio Black Square Premium (listed 87 x 79 x 87 in)".to_string(),
            url: "https://refugiosaunaco.com/products/black-square-premium-thermo-spruce-outdoor-cube-sauna-4-to-6-person-capacity".to_string(),
            listed_dimensions: "87 in W x 79 in L x 87 in H".to_string(),
        }),
        _ => None,
    }
}

pub fn entry(kind: Kind) -> CatalogEntry {
    let (width, depth, height) = default_size(kind);
    CatalogEntry {
        kind,
        label: label(kind),
        category: category(kind),
        shape: shape(kind),
        width,
        depth,
        height,
        size_certainty: default_size_certainty(kind),
        description: description(kind),
        product: preset_product(kind),
    }
}

pub fn all() -> Vec<CatalogEntry> {
    Kind::ALL.iter().map(|k| entry(*k)).collect()
}

fn param_f64(item: &Item, key: &str, default: f64) -> f64 {
    item.params
        .get(key)
        .and_then(|v| v.as_f64())
        .unwrap_or(default)
}

pub fn pit_diameter(item: &Item) -> f64 {
    param_f64(item, "pit_diameter", DEFAULT_PIT_DIAMETER)
}

pub fn fire_clearance(item: &Item) -> f64 {
    param_f64(item, "clearance", DEFAULT_FIRE_CLEARANCE)
}

pub fn wall_thickness(item: &Item) -> f64 {
    param_f64(item, "wall_thickness", DEFAULT_WALL_THICKNESS)
}

/// Parameter keys a kind accepts, with the numeric range each must fall in (`None` for strings).
pub fn allowed_params(kind: Kind) -> &'static [(&'static str, Option<(f64, f64)>)] {
    match kind {
        Kind::FirePit => &[
            ("pit_diameter", Some((0.1, 100.0))),
            ("clearance", Some((0.0, 100.0))),
        ],
        Kind::BinScreen => &[("wall_thickness", Some((0.01, 5.0)))],
        Kind::Plant | Kind::Tree => &[("species", None)],
        Kind::Pond => &[("water_depth", Some((0.0, 30.0)))],
        _ => &[],
    }
}
