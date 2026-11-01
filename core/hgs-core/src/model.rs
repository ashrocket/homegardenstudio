//! The serialisable project model. Field order here is the canonical key order of the saved file.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub type Pt = [f64; 2];
pub type Params = BTreeMap<String, serde_json::Value>;

pub const SCHEMA: u32 = 1;
pub const MAX_ITEMS: usize = 5000;
pub const MAX_STRUCTURES: usize = 64;
pub const MAX_SOURCES: usize = 2000;
pub const MAX_COORD: f64 = 10_000.0;
pub const MIN_DIM: f64 = 0.05;
pub const MAX_DIM: f64 = 100.0;
pub const MAX_HEIGHT: f64 = 30.0;
pub const MAX_OUTLINE_POINTS: usize = 512;
pub const MAX_NAME: usize = 200;
pub const MAX_TEXT: usize = 4000;
pub const MAX_URL: usize = 2000;
pub const MAX_ITEM_SOURCES: usize = 64;
pub const MAX_DOCUMENT_BYTES: usize = 8 * 1024 * 1024;
pub const MAX_COMMAND_BYTES: usize = 256 * 1024;
pub const MAX_QUERY_BYTES: usize = 64 * 1024;

pub const MAX_SEQ: u64 = 1_000_000_000_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Units {
    Imperial,
    Metric,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    Plant,
    Tree,
    Pond,
    FirePit,
    Pergola,
    Sauna,
    ToolShed,
    BinScreen,
    Patio,
    RaisedBed,
    Path,
    Fence,
    PrivacyScreen,
    Structure,
}

impl Kind {
    pub const ALL: [Kind; 14] = [
        Kind::Plant,
        Kind::Tree,
        Kind::Pond,
        Kind::FirePit,
        Kind::Pergola,
        Kind::Sauna,
        Kind::ToolShed,
        Kind::BinScreen,
        Kind::Patio,
        Kind::RaisedBed,
        Kind::Path,
        Kind::Fence,
        Kind::PrivacyScreen,
        Kind::Structure,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Plant => "plant",
            Kind::Tree => "tree",
            Kind::Pond => "pond",
            Kind::FirePit => "fire_pit",
            Kind::Pergola => "pergola",
            Kind::Sauna => "sauna",
            Kind::ToolShed => "tool_shed",
            Kind::BinScreen => "bin_screen",
            Kind::Patio => "patio",
            Kind::RaisedBed => "raised_bed",
            Kind::Path => "path",
            Kind::Fence => "fence",
            Kind::PrivacyScreen => "privacy_screen",
            Kind::Structure => "structure",
        }
    }
}

/// Certainty of an item's position.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PositionCertainty {
    Measured,
    Estimated,
    UnregisteredPhoto,
}

impl PositionCertainty {
    pub fn as_str(self) -> &'static str {
        match self {
            PositionCertainty::Measured => "measured",
            PositionCertainty::Estimated => "estimated",
            PositionCertainty::UnregisteredPhoto => "unregistered_photo",
        }
    }
}

/// Certainty of an item's size.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SizeCertainty {
    Measured,
    Estimated,
    ProductListing,
}

impl SizeCertainty {
    pub fn as_str(self) -> &'static str {
        match self {
            SizeCertainty::Measured => "measured",
            SizeCertainty::Estimated => "estimated",
            SizeCertainty::ProductListing => "product_listing",
        }
    }
}

/// Certainty of the site boundary or a structure outline.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Certainty {
    Measured,
    Estimated,
}

impl Certainty {
    pub fn as_str(self) -> &'static str {
        match self {
            Certainty::Measured => "measured",
            Certainty::Estimated => "estimated",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceKind {
    Photo,
    File,
    Url,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Product {
    pub title: String,
    pub url: String,
    pub listed_dimensions: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Structure {
    pub id: String,
    pub name: String,
    pub outline: Vec<Pt>,
    pub height: f64,
    pub certainty: Certainty,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Site {
    pub boundary: Option<Vec<Pt>>,
    pub boundary_certainty: Certainty,
    pub structures: Vec<Structure>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EvidenceMethod {
    FieldMeasurement,
    ProductListing,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MeasurementEvidence {
    pub method: EvidenceMethod,
    pub values: [f64; 3],
    pub note: String,
    pub source_id: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Item {
    pub id: String,
    pub kind: Kind,
    pub name: String,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub depth: f64,
    pub height: f64,
    pub rotation: f64,
    pub params: Params,
    pub position_certainty: PositionCertainty,
    pub size_certainty: SizeCertainty,
    #[serde(default)]
    pub position_evidence: Option<MeasurementEvidence>,
    #[serde(default)]
    pub size_evidence: Option<MeasurementEvidence>,
    pub source_ids: Vec<String>,
    pub product: Option<Product>,
    pub locked: bool,
    pub notes: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Registration {
    pub p1: Pt,
    pub p2: Pt,
    pub distance_m: f64,
}

impl Registration {
    pub fn pixel_distance(&self) -> f64 {
        ((self.p1[0] - self.p2[0]).powi(2) + (self.p1[1] - self.p2[1]).powi(2)).sqrt()
    }

    pub fn meters_per_pixel(&self) -> f64 {
        self.distance_m / self.pixel_distance()
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Source {
    pub id: String,
    pub kind: SourceKind,
    pub title: String,
    pub original_filename: String,
    pub sha256: String,
    pub byte_count: u64,
    pub media_type: String,
    pub url: Option<String>,
    pub pixel_width: Option<u32>,
    pub pixel_height: Option<u32>,
    pub registration: Option<Registration>,
    pub note: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Backdrop {
    pub source_id: String,
    pub x: f64,
    pub y: f64,
    pub rotation: f64,
    pub opacity: f64,
    pub meters_per_pixel: Option<f64>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Project {
    pub schema: u32,
    pub name: String,
    pub units: Units,
    pub next_seq: u64,
    pub site: Site,
    pub items: Vec<Item>,
    pub sources: Vec<Source>,
    pub backdrop: Option<Backdrop>,
}

impl Project {
    pub fn new(name: &str) -> Project {
        Project {
            schema: SCHEMA,
            name: name.to_string(),
            units: Units::Imperial,
            next_seq: 1,
            site: Site {
                boundary: None,
                boundary_certainty: Certainty::Estimated,
                structures: Vec::new(),
            },
            items: Vec::new(),
            sources: Vec::new(),
            backdrop: None,
        }
    }

    pub fn item(&self, id: &str) -> Option<&Item> {
        self.items.iter().find(|i| i.id == id)
    }

    pub fn item_index(&self, id: &str) -> Option<usize> {
        self.items.iter().position(|i| i.id == id)
    }

    pub fn source(&self, id: &str) -> Option<&Source> {
        self.sources.iter().find(|s| s.id == id)
    }

    /// Allocates the next engine id with the given prefix (`i` or `s`) and advances `next_seq`.
    pub fn alloc_id(&mut self, prefix: char) -> String {
        loop {
            let id = format!("{}{}", prefix, self.next_seq);
            self.next_seq += 1;
            let taken = self.items.iter().any(|i| i.id == id)
                || self.site.structures.iter().any(|s| s.id == id);
            if !taken {
                return id;
            }
        }
    }
}

/// Numeric suffix of an id such as `i12` or `s3` (the trailing digits), if any.
pub fn id_suffix(id: &str) -> Option<u64> {
    let digits: String = id
        .chars()
        .rev()
        .take_while(|c| c.is_ascii_digit())
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();
    if digits.is_empty() || digits.len() > 15 {
        None
    } else {
        digits.parse().ok()
    }
}
