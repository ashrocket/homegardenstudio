//! Two kinds of validation. `check_project` enforces hard limits and references: a project that
//! fails it can't exist. `validate` reports layout issues: warnings and notes the user can see.

use crate::catalog;
use crate::error::{ApiError, Result};
use crate::geometry;
use crate::model::*;
use serde::Serialize;
use std::collections::HashSet;

// ---------------------------------------------------------------------------------------------
// Hard limits
// ---------------------------------------------------------------------------------------------

/// A finite number in `lo..=hi`. Non-finite is `INVALID_VALUE`; out of range is `LIMIT_EXCEEDED`.
pub fn check_num(v: f64, what: &str, lo: f64, hi: f64) -> Result<()> {
    if !v.is_finite() {
        return Err(ApiError::invalid(format!("{what} must be a finite number")));
    }
    if v < lo || v > hi {
        return Err(ApiError::limit(format!(
            "{what} must be between {lo} and {hi} (got {v})"
        )));
    }
    Ok(())
}

pub fn check_coord(v: f64, what: &str) -> Result<()> {
    check_num(v, what, -MAX_COORD, MAX_COORD)
}

pub fn check_text(s: &str, what: &str, max_chars: usize) -> Result<()> {
    if s.chars().count() > max_chars {
        return Err(ApiError::limit(format!(
            "{what} is longer than {max_chars} characters"
        )));
    }
    if s.contains('\0') {
        return Err(ApiError::invalid(format!(
            "{what} contains a NUL character"
        )));
    }
    Ok(())
}

pub fn check_url(url: &str, what: &str) -> Result<()> {
    check_text(url, what, MAX_URL)?;
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return Err(ApiError::invalid(format!(
            "{what} must start with http:// or https://"
        )));
    }
    Ok(())
}

pub fn check_id(id: &str, what: &str) -> Result<()> {
    let ok = !id.is_empty()
        && id.len() <= 80
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-');
    if ok {
        Ok(())
    } else {
        Err(ApiError::invalid(format!(
            "{what} id '{id}' must be 1 to 80 letters, digits, '-' or '_'"
        )))
    }
}

pub fn check_outline(outline: &[Pt], what: &str) -> Result<()> {
    if outline.len() < 3 {
        return Err(ApiError::invalid(format!("{what} needs at least 3 points")));
    }
    if outline.len() > MAX_OUTLINE_POINTS {
        return Err(ApiError::limit(format!(
            "{what} has more than {MAX_OUTLINE_POINTS} points"
        )));
    }
    for p in outline {
        check_coord(p[0], &format!("{what} x"))?;
        check_coord(p[1], &format!("{what} y"))?;
    }
    if geometry::signed_area(outline).abs() < 1e-6 {
        return Err(ApiError::invalid(format!("{what} has no area")));
    }
    Ok(())
}

pub fn check_product(p: &Product) -> Result<()> {
    check_text(&p.title, "product title", MAX_NAME * 2)?;
    check_url(&p.url, "product url")?;
    check_text(&p.listed_dimensions, "product listed_dimensions", MAX_NAME)
}

pub fn check_params(kind: Kind, params: &Params) -> Result<()> {
    let allowed = catalog::allowed_params(kind);
    for (key, value) in params {
        let Some((_, range)) = allowed.iter().find(|(k, _)| *k == key.as_str()) else {
            return Err(ApiError::invalid(format!(
                "{} items don't take a '{key}' parameter",
                kind.as_str()
            )));
        };
        match range {
            Some((lo, hi)) => {
                let Some(n) = value.as_f64() else {
                    return Err(ApiError::invalid(format!(
                        "parameter '{key}' must be a number"
                    )));
                };
                check_num(n, &format!("parameter '{key}'"), *lo, *hi)?;
            }
            None => {
                let Some(s) = value.as_str() else {
                    return Err(ApiError::invalid(format!(
                        "parameter '{key}' must be a string"
                    )));
                };
                check_text(s, &format!("parameter '{key}'"), MAX_NAME)?;
            }
        }
    }
    Ok(())
}

pub fn check_registration(r: &Registration, src: &Source) -> Result<()> {
    for (label, p) in [("p1", r.p1), ("p2", r.p2)] {
        check_num(p[0], &format!("registration {label} x"), 0.0, 1e7)?;
        check_num(p[1], &format!("registration {label} y"), 0.0, 1e7)?;
        if let (Some(w), Some(h)) = (src.pixel_width, src.pixel_height) {
            if p[0] > f64::from(w) || p[1] > f64::from(h) {
                return Err(ApiError::invalid(format!(
                    "registration {label} lies outside the {w} x {h} px image"
                )));
            }
        }
    }
    if r.pixel_distance() < 10.0 {
        return Err(ApiError::invalid(
            "registration points must be at least 10 px apart",
        ));
    }
    check_num(r.distance_m, "registration distance_m", 0.1, 500.0)
}

pub fn check_item(it: &Item) -> Result<()> {
    let id = &it.id;
    check_id(id, "item")?;
    check_text(&it.name, &format!("{id} name"), MAX_NAME)?;
    check_text(&it.notes, &format!("{id} notes"), MAX_TEXT)?;
    check_coord(it.x, &format!("{id} x"))?;
    check_coord(it.y, &format!("{id} y"))?;
    check_num(it.width, &format!("{id} width"), MIN_DIM, MAX_DIM)?;
    check_num(it.depth, &format!("{id} depth"), MIN_DIM, MAX_DIM)?;
    check_num(it.height, &format!("{id} height"), 0.0, MAX_HEIGHT)?;
    if !it.rotation.is_finite() || !(0.0..360.0).contains(&it.rotation) {
        return Err(ApiError::invalid(format!(
            "{id} rotation must be in [0, 360)"
        )));
    }
    check_params(it.kind, &it.params)?;
    if it.kind == Kind::FirePit && catalog::pit_diameter(it) > it.width.min(it.depth) {
        return Err(ApiError::invalid(
            "fire pit must fit within its contained gravel circle",
        ));
    }
    if let Some(p) = &it.product {
        check_product(p)?;
    }
    if catalog::is_circle(it.kind) && it.width != it.depth {
        return Err(ApiError::invalid("circle width and depth must match"));
    }
    check_evidence(
        it,
        &it.position_evidence,
        (it.position_certainty == PositionCertainty::Measured)
            .then_some(EvidenceMethod::FieldMeasurement),
        [it.x, it.y, it.rotation],
    )?;
    let method = match it.size_certainty {
        SizeCertainty::Measured => Some(EvidenceMethod::FieldMeasurement),
        SizeCertainty::ProductListing => Some(EvidenceMethod::ProductListing),
        SizeCertainty::Estimated => None,
    };
    check_evidence(
        it,
        &it.size_evidence,
        method,
        [it.width, it.depth, it.height],
    )?;
    if it.size_certainty == SizeCertainty::ProductListing && it.product.is_none() {
        return Err(ApiError::invalid("listed size needs product metadata"));
    }
    if it.source_ids.len() > MAX_ITEM_SOURCES {
        return Err(ApiError::limit(format!(
            "{id} has more than {MAX_ITEM_SOURCES} sources"
        )));
    }
    Ok(())
}

fn check_evidence(
    it: &Item,
    evidence: &Option<MeasurementEvidence>,
    method: Option<EvidenceMethod>,
    values: [f64; 3],
) -> Result<()> {
    match (evidence, method) {
        (None, None) => Ok(()),
        (Some(e), Some(m)) if e.method == m && e.values == values => {
            check_text(&e.note, "measurement note", MAX_TEXT)?;
            if e.note.trim().is_empty() {
                return Err(ApiError::invalid("measurement note cannot be empty"));
            }
            if let Some(sid) = &e.source_id {
                if !it.source_ids.contains(sid) {
                    return Err(ApiError::invalid(
                        "measurement evidence must reference an item-linked source",
                    ));
                }
            }
            Ok(())
        }
        _ => Err(ApiError::invalid(
            "certainty requires matching field-specific measurement evidence",
        )),
    }
}

pub fn check_structure(s: &Structure) -> Result<()> {
    check_id(&s.id, "structure")?;
    check_text(&s.name, &format!("{} name", s.id), MAX_NAME)?;
    check_outline(&s.outline, &format!("{} outline", s.id))?;
    check_num(s.height, &format!("{} height", s.id), 0.0, MAX_HEIGHT)
}

pub fn check_source(s: &Source) -> Result<()> {
    check_id(&s.id, "source")?;
    check_text(&s.title, &format!("{} title", s.id), MAX_NAME * 2)?;
    check_text(
        &s.original_filename,
        &format!("{} filename", s.id),
        MAX_NAME * 2,
    )?;
    check_text(&s.media_type, &format!("{} media_type", s.id), MAX_NAME)?;
    check_text(&s.note, &format!("{} note", s.id), MAX_TEXT)?;
    let hex_ok = s.sha256.len() == 64
        && s.sha256
            .chars()
            .all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c));
    if !hex_ok {
        return Err(ApiError::invalid(format!(
            "{} sha256 must be 64 lowercase hex characters",
            s.id
        )));
    }
    if s.id != format!("src-{}", &s.sha256[..16]) {
        return Err(ApiError::invalid(format!(
            "source id {} must be src- plus the first 16 hex characters of its sha256",
            s.id
        )));
    }
    if s.byte_count > 1_000_000_000_000_000 {
        return Err(ApiError::limit(format!("{} byte_count is too large", s.id)));
    }
    if let Some(u) = &s.url {
        check_url(u, &format!("{} url", s.id))?;
    }
    for (label, v) in [
        ("pixel_width", s.pixel_width),
        ("pixel_height", s.pixel_height),
    ] {
        if let Some(v) = v {
            if v == 0 || v > 1_000_000 {
                return Err(ApiError::limit(format!(
                    "{} {label} must be between 1 and 1000000",
                    s.id
                )));
            }
        }
    }
    if let Some(r) = &s.registration {
        if s.kind != SourceKind::Photo {
            return Err(ApiError::invalid(format!(
                "{} is not a photo, so it can't be registered",
                s.id
            )));
        }
        check_registration(r, s)?;
    }
    Ok(())
}

/// Checks every invariant of a project: limits, unique ids, references, derived fields.
pub fn check_project(p: &Project) -> Result<()> {
    if p.schema != SCHEMA {
        return Err(ApiError::invalid(format!(
            "unsupported schema {}",
            p.schema
        )));
    }
    check_text(&p.name, "project name", MAX_NAME)?;
    if p.items.len() > MAX_ITEMS {
        return Err(ApiError::limit(format!("more than {MAX_ITEMS} items")));
    }
    if p.site.structures.len() > MAX_STRUCTURES {
        return Err(ApiError::limit(format!(
            "more than {MAX_STRUCTURES} structures"
        )));
    }
    if p.sources.len() > MAX_SOURCES {
        return Err(ApiError::limit(format!("more than {MAX_SOURCES} sources")));
    }
    if p.next_seq > MAX_SEQ {
        return Err(ApiError::limit("next_seq is too large"));
    }
    if let Some(b) = &p.site.boundary {
        check_outline(b, "boundary")?;
    }

    let mut source_ids = HashSet::new();
    for s in &p.sources {
        check_source(s)?;
        if !source_ids.insert(s.id.as_str()) {
            return Err(ApiError::invalid(format!("duplicate source id {}", s.id)));
        }
    }

    let mut seen = HashSet::new();
    let mut max_suffix = 0;
    for s in &p.site.structures {
        check_structure(s)?;
        if !seen.insert(s.id.as_str()) {
            return Err(ApiError::invalid(format!("duplicate id {}", s.id)));
        }
        max_suffix = max_suffix.max(id_suffix(&s.id).unwrap_or(0));
    }
    for it in &p.items {
        check_item(it)?;
        if !seen.insert(it.id.as_str()) {
            return Err(ApiError::invalid(format!("duplicate id {}", it.id)));
        }
        max_suffix = max_suffix.max(id_suffix(&it.id).unwrap_or(0));
        let mut own = HashSet::new();
        for sid in &it.source_ids {
            if !source_ids.contains(sid.as_str()) {
                return Err(ApiError::invalid(format!(
                    "{} refers to missing source {sid}",
                    it.id
                )));
            }
            if !own.insert(sid.as_str()) {
                return Err(ApiError::invalid(format!(
                    "{} lists source {sid} twice",
                    it.id
                )));
            }
        }
    }
    if p.next_seq <= max_suffix {
        return Err(ApiError::invalid(format!(
            "next_seq {} must exceed the highest id number {max_suffix}",
            p.next_seq
        )));
    }

    if let Some(b) = &p.backdrop {
        let Some(src) = p.source(&b.source_id) else {
            return Err(ApiError::invalid(format!(
                "backdrop refers to missing source {}",
                b.source_id
            )));
        };
        check_coord(b.x, "backdrop x")?;
        check_coord(b.y, "backdrop y")?;
        if !b.rotation.is_finite() || !(0.0..360.0).contains(&b.rotation) {
            return Err(ApiError::invalid("backdrop rotation must be in [0, 360)"));
        }
        if !b.opacity.is_finite() || !(0.0..=1.0).contains(&b.opacity) {
            return Err(ApiError::invalid(
                "backdrop opacity must be between 0 and 1",
            ));
        }
        let expected = src.registration.as_ref().map(|r| r.meters_per_pixel());
        if b.meters_per_pixel != expected {
            return Err(ApiError::invalid(
                "backdrop meters_per_pixel must match the source registration",
            ));
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------------------------
// Layout issues
// ---------------------------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum IssueCode {
    OutsideBoundary,
    OverlapsStructure,
    OverlapsItem,
    FireClearance,
    UnregisteredPosition,
    NoBoundary,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Severity {
    Warning,
    Info,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Issue {
    pub item_id: Option<String>,
    pub code: IssueCode,
    pub severity: Severity,
    pub message: String,
}

/// Item footprints and bounding boxes, computed once per validation pass.
pub struct Layout {
    pub footprints: Vec<Vec<Pt>>,
    pub boxes: Vec<[f64; 4]>,
}

impl Layout {
    pub fn new(p: &Project) -> Layout {
        let footprints: Vec<Vec<Pt>> = p.items.iter().map(geometry::footprint).collect();
        let boxes = footprints.iter().map(|f| geometry::bbox(f)).collect();
        Layout { footprints, boxes }
    }
}

fn id_order(a: &str, b: &str) -> std::cmp::Ordering {
    match (id_suffix(a), id_suffix(b)) {
        (Some(x), Some(y)) if x != y => x.cmp(&y),
        _ => a.cmp(b),
    }
}

fn plant_pair_allowed(a: Kind, b: Kind) -> bool {
    let soft = |k: Kind| matches!(k, Kind::Patio | Kind::Path | Kind::RaisedBed);
    (a == Kind::Plant && soft(b)) || (b == Kind::Plant && soft(a))
}

fn blocks_fire(kind: Kind) -> bool {
    matches!(
        kind,
        Kind::Structure
            | Kind::Pergola
            | Kind::Sauna
            | Kind::ToolShed
            | Kind::Fence
            | Kind::PrivacyScreen
    )
}

fn warn(item: &Item, code: IssueCode, message: String) -> Issue {
    Issue {
        item_id: Some(item.id.clone()),
        code,
        severity: Severity::Warning,
        message,
    }
}

/// Issues for one item. `item` is `p.items[idx]` or a proposed replacement for it, and
/// `layout` must hold the footprint to check at `idx`. With `all_pairs`, overlaps with every other
/// item are reported on this item (the drag preview); otherwise a pair is reported only on the
/// lower id.
pub fn issues_for(
    p: &Project,
    layout: &Layout,
    idx: usize,
    item: &Item,
    all_pairs: bool,
) -> Vec<Issue> {
    let fp = &layout.footprints[idx];
    let mut out = Vec::new();

    if let Some(boundary) = &p.site.boundary {
        if !geometry::contains_polygon(boundary, fp) {
            out.push(warn(
                item,
                IssueCode::OutsideBoundary,
                format!(
                    "{} reaches outside the site boundary. Not a survey: based on the boundary you drew.",
                    item.name
                ),
            ));
        }
    }

    for s in &p.site.structures {
        if geometry::intersects(fp, &s.outline) {
            out.push(warn(
                item,
                IssueCode::OverlapsStructure,
                format!(
                    "{} touches or overlaps {}. Not a survey: based on the outline you drew.",
                    item.name, s.name
                ),
            ));
        }
    }

    for (j, other) in p.items.iter().enumerate() {
        if j == idx {
            continue;
        }
        if !all_pairs && id_order(&item.id, &other.id) != std::cmp::Ordering::Less {
            continue;
        }
        if !geometry::bbox_overlap(&layout.boxes[idx], &layout.boxes[j], 0.0) {
            continue;
        }
        let ofp = &layout.footprints[j];
        if !geometry::overlaps_with_area(fp, ofp) {
            continue;
        }
        if plant_pair_allowed(item.kind, other.kind) {
            continue;
        }
        let inside_pergola = (other.kind == Kind::Pergola && geometry::contains_polygon(ofp, fp))
            || (item.kind == Kind::Pergola && geometry::contains_polygon(fp, ofp));
        if inside_pergola {
            continue;
        }
        out.push(warn(
            item,
            IssueCode::OverlapsItem,
            format!("{} overlaps {}.", item.name, other.name),
        ));
    }

    if item.kind == Kind::FirePit {
        let radius = catalog::pit_diameter(item) / 2.0 + catalog::fire_clearance(item);
        let centre = [item.x, item.y];
        for s in &p.site.structures {
            if geometry::disc_reaches_polygon(centre, radius, &s.outline) {
                out.push(warn(
                    item,
                    IssueCode::FireClearance,
                    fire_message(item, &s.name),
                ));
            }
        }
        for (j, other) in p.items.iter().enumerate() {
            if j != idx
                && blocks_fire(other.kind)
                && geometry::disc_reaches_polygon(centre, radius, &layout.footprints[j])
            {
                out.push(warn(
                    item,
                    IssueCode::FireClearance,
                    fire_message(item, &other.name),
                ));
            }
        }
    }

    if item.position_certainty == PositionCertainty::UnregisteredPhoto {
        out.push(Issue {
            item_id: Some(item.id.clone()),
            code: IssueCode::UnregisteredPosition,
            severity: Severity::Info,
            message: format!(
                "{} was placed by tracing an unscaled photo, so its position is approximate.",
                item.name
            ),
        });
    }
    out
}

fn fire_message(pit: &Item, blocker: &str) -> String {
    format!(
        "{} is closer than its {:.1} m clearance to {}.",
        pit.name,
        catalog::fire_clearance(pit),
        blocker
    )
}

pub fn no_boundary_issue() -> Issue {
    Issue {
        item_id: None,
        code: IssueCode::NoBoundary,
        severity: Severity::Info,
        message: "No site boundary has been drawn, so items weren't checked against the property edge. Not a survey.".to_string(),
    }
}

/// All layout issues, in item order, with the boundary note first.
pub fn validate(p: &Project) -> Vec<Issue> {
    let layout = Layout::new(p);
    let mut out = Vec::new();
    if p.site.boundary.is_none() {
        out.push(no_boundary_issue());
    }
    for idx in 0..p.items.len() {
        out.extend(issues_for(p, &layout, idx, &p.items[idx], false));
    }
    out
}
