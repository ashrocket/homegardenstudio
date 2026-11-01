//! Mutating commands. Each one edits a working copy of the project; the engine validates the copy
//! and only then swaps it in and records an undo step.

use crate::catalog;
use crate::error::{ApiError, ErrorCode, Result};
use crate::geometry::normalize_deg;
use crate::model::*;
use crate::persist::derive_backdrop_scale;
use crate::validate::*;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Deserializer};
use serde_json::{Map, Value};

/// What a command did, for the response and the undo label.
#[derive(Debug, Default)]
pub struct Outcome {
    pub label: String,
    pub created: Vec<String>,
    pub changed: Vec<String>,
    pub removed: Vec<String>,
}

impl Outcome {
    fn new(label: String) -> Outcome {
        Outcome {
            label,
            ..Outcome::default()
        }
    }
}

const SAME: f64 = 1e-9;

fn differs(a: f64, b: f64) -> bool {
    (a - b).abs() > SAME
}

fn parse_args<T: DeserializeOwned>(mut args: Map<String, Value>) -> Result<T> {
    args.remove("op");
    serde_json::from_value(Value::Object(args)).map_err(|e| ApiError::invalid(e.to_string()))
}

/// Distinguishes an absent key (`None`) from an explicit null (`Some(None)`).
fn double_option<'de, D, T>(d: D) -> std::result::Result<Option<Option<T>>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    Option::<T>::deserialize(d).map(Some)
}

/// A field that must be present, though its value may be null.
fn required_option<'de, D, T>(d: D) -> std::result::Result<Option<T>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    Option::<T>::deserialize(d)
}

fn item_index(p: &Project, id: &str) -> Result<usize> {
    p.item_index(id)
        .ok_or_else(|| ApiError::not_found(format!("No item {id}")))
}

fn structure_index(p: &Project, id: &str) -> Result<usize> {
    p.site
        .structures
        .iter()
        .position(|s| s.id == id)
        .ok_or_else(|| ApiError::not_found(format!("No structure {id}")))
}

fn source_index(p: &Project, id: &str) -> Result<usize> {
    p.sources
        .iter()
        .position(|s| s.id == id)
        .ok_or_else(|| ApiError::not_found(format!("No source {id}")))
}

fn locked_error(item: &Item) -> ApiError {
    ApiError::locked(format!("{} is locked. Unlock it to change it.", item.name))
}

/// Rule 3: a moved item's position is a proposal, whatever it was before.
fn downgrade_if_moved(item: &mut Item, moved: bool) {
    if moved && item.position_certainty == PositionCertainty::Measured {
        item.position_certainty = PositionCertainty::Estimated;
        item.position_evidence = None;
    }
}

fn downgrade_size(item: &mut Item) {
    item.size_certainty = SizeCertainty::Estimated;
    item.size_evidence = None;
}

fn invalidate_source(item: &mut Item, sid: &str) -> bool {
    let position = item
        .position_evidence
        .as_ref()
        .is_some_and(|e| e.source_id.as_deref() == Some(sid));
    let size = item
        .size_evidence
        .as_ref()
        .is_some_and(|e| e.source_id.as_deref() == Some(sid));
    downgrade_if_moved(item, position);
    if size {
        downgrade_size(item);
    }
    position || size
}

fn listed_evidence(w: f64, d: f64, h: f64) -> MeasurementEvidence {
    MeasurementEvidence {
        method: EvidenceMethod::ProductListing,
        values: [w, d, h],
        note: "Dimensions asserted from the attached product listing.".into(),
        source_id: None,
    }
}

/// Rule 5: circle kinds keep width and depth equal; width wins when both are given.
fn equalise_circle(kind: Kind, width: Option<f64>, depth: Option<f64>, w: &mut f64, d: &mut f64) {
    if !catalog::is_circle(kind) {
        return;
    }
    match (width, depth) {
        (Some(v), _) => {
            *w = v;
            *d = v;
        }
        (None, Some(v)) => {
            *w = v;
            *d = v;
        }
        (None, None) => {
            *d = *w;
        }
    }
}

fn clean_name(name: &str, fallback: &str) -> String {
    let t = name.trim();
    if t.is_empty() {
        fallback.to_string()
    } else {
        t.to_string()
    }
}

fn count_label(verb: &str, p: &Project, idxs: &[usize]) -> String {
    if idxs.len() == 1 {
        format!("{verb} {}", p.items[idxs[0]].name)
    } else {
        format!("{verb} {} items", idxs.len())
    }
}

fn resolve_ids(p: &Project, ids: &[String]) -> Result<Vec<usize>> {
    if ids.is_empty() {
        return Err(ApiError::invalid("ids must list at least one item"));
    }
    let mut idxs = Vec::new();
    for id in ids {
        let i = item_index(p, id)?;
        if !idxs.contains(&i) {
            idxs.push(i);
        }
    }
    Ok(idxs)
}

/// Runs one command against `p`. Unknown ops fail before any argument is read.
pub fn apply(p: &mut Project, op: &str, args: Map<String, Value>) -> Result<Outcome> {
    match op {
        "add_item" => add_item(p, parse_args(args)?),
        "update_item" => update_item(p, parse_args(args)?),
        "set_transform" => set_transform(p, parse_args(args)?),
        "move_items" => move_items(p, parse_args(args)?),
        "remove_items" => remove_items(p, parse_args(args)?),
        "duplicate_items" => duplicate_items(p, parse_args(args)?),
        "set_boundary" => set_boundary(p, parse_args(args)?),
        "add_structure" => add_structure(p, parse_args(args)?),
        "update_structure" => update_structure(p, parse_args(args)?),
        "remove_structure" => remove_structure(p, parse_args(args)?),
        "add_source" => add_source(p, parse_args(args)?),
        "remove_source" => remove_source(p, parse_args(args)?),
        "register_source" => register_source(p, parse_args(args)?),
        "set_backdrop" => set_backdrop(p, parse_args(args)?),
        "mark_measured" => mark_measured(p, parse_args(args)?),
        "set_project_meta" => set_project_meta(p, parse_args(args)?),
        other => Err(ApiError::new(
            ErrorCode::UnknownOp,
            format!("Unknown command '{other}'"),
        )),
    }
}

// ---------------------------------------------------------------------------------------------
// Items
// ---------------------------------------------------------------------------------------------

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AddItem {
    kind: Kind,
    name: Option<String>,
    x: f64,
    y: f64,
    width: Option<f64>,
    depth: Option<f64>,
    height: Option<f64>,
    rotation: Option<f64>,
    params: Option<Params>,
    product: Option<Product>,
    traced_from_backdrop: Option<bool>,
}

fn add_item(p: &mut Project, a: AddItem) -> Result<Outcome> {
    if p.items.len() >= MAX_ITEMS {
        return Err(ApiError::limit(format!(
            "A plan holds at most {MAX_ITEMS} items"
        )));
    }
    let (dw, dd, dh) = catalog::default_size(a.kind);
    let (mut w, mut d) = (a.width.unwrap_or(dw), a.depth.unwrap_or(dd));
    if catalog::is_circle(a.kind) {
        match (a.width, a.depth) {
            (Some(v), _) | (None, Some(v)) => {
                w = v;
                d = v;
            }
            (None, None) => {}
        }
    }
    let h = a.height.unwrap_or(dh);
    let custom_size = differs(w, dw) || differs(d, dd) || differs(h, dh);
    let size_certainty = if a.product.is_some() {
        SizeCertainty::ProductListing
    } else if custom_size {
        SizeCertainty::Estimated
    } else {
        catalog::default_size_certainty(a.kind)
    };
    let product = match a.product {
        Some(prod) => Some(prod),
        None if !custom_size => catalog::preset_product(a.kind),
        None => None,
    };
    let position_certainty = match (a.traced_from_backdrop.unwrap_or(false), &p.backdrop) {
        (true, Some(b)) => {
            let registered = p
                .source(&b.source_id)
                .map(|s| s.registration.is_some())
                .unwrap_or(false);
            if registered {
                PositionCertainty::Estimated
            } else {
                PositionCertainty::UnregisteredPhoto
            }
        }
        _ => PositionCertainty::Estimated,
    };
    let label = catalog::label(a.kind);
    let name = clean_name(a.name.as_deref().unwrap_or(""), label);
    let rotation = match a.rotation {
        Some(r) if !r.is_finite() => {
            return Err(ApiError::invalid("rotation must be a finite number"))
        }
        Some(r) => normalize_deg(r),
        None => 0.0,
    };
    let id = p.alloc_id('i');
    let item = Item {
        id: id.clone(),
        kind: a.kind,
        name,
        x: a.x,
        y: a.y,
        width: w,
        depth: d,
        height: h,
        rotation,
        params: a.params.unwrap_or_default(),
        position_certainty,
        size_certainty,
        position_evidence: None,
        size_evidence: (size_certainty == SizeCertainty::ProductListing)
            .then(|| listed_evidence(w, d, h)),
        source_ids: if a.traced_from_backdrop == Some(true) {
            p.backdrop
                .as_ref()
                .map(|b| vec![b.source_id.clone()])
                .unwrap_or_default()
        } else {
            Vec::new()
        },
        product,
        locked: false,
        notes: String::new(),
    };
    check_item(&item)?;
    p.items.push(item);
    let mut out = Outcome::new(format!("Add {label}"));
    out.created.push(id.clone());
    out.changed.push(id);
    Ok(out)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ItemPatch {
    name: Option<String>,
    x: Option<f64>,
    y: Option<f64>,
    width: Option<f64>,
    depth: Option<f64>,
    height: Option<f64>,
    rotation: Option<f64>,
    params: Option<Params>,
    notes: Option<String>,
    locked: Option<bool>,
    source_ids: Option<Vec<String>>,
    #[serde(default, deserialize_with = "double_option")]
    product: Option<Option<Product>>,
    size_certainty: Option<SizeCertainty>,
}

impl ItemPatch {
    fn touches_geometry(&self) -> bool {
        self.x.is_some()
            || self.y.is_some()
            || self.width.is_some()
            || self.depth.is_some()
            || self.height.is_some()
            || self.rotation.is_some()
            || self.params.is_some()
    }

    fn is_empty(&self) -> bool {
        !self.touches_geometry()
            && self.name.is_none()
            && self.notes.is_none()
            && self.locked.is_none()
            && self.source_ids.is_none()
            && self.product.is_none()
            && self.size_certainty.is_none()
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UpdateItem {
    id: String,
    patch: ItemPatch,
}

fn update_item(p: &mut Project, a: UpdateItem) -> Result<Outcome> {
    let idx = item_index(p, &a.id)?;
    let patch = a.patch;
    if patch.is_empty() {
        return Err(ApiError::invalid("patch has no fields"));
    }
    if p.items[idx].locked && patch.touches_geometry() {
        return Err(locked_error(&p.items[idx]));
    }
    if let Some(ids) = &patch.source_ids {
        for sid in ids {
            source_index(p, sid)?;
        }
    }
    let it = &mut p.items[idx];
    let old = it.clone();
    if let Some(name) = patch.name {
        if name.trim().is_empty() {
            return Err(ApiError::invalid("name can't be empty"));
        }
        it.name = name.trim().to_string();
    }
    let moved =
        patch.x.is_some_and(|v| differs(v, it.x)) || patch.y.is_some_and(|v| differs(v, it.y));
    if let Some(v) = patch.x {
        it.x = v;
    }
    if let Some(v) = patch.y {
        it.y = v;
    }
    let (mut w, mut d) = (
        patch.width.unwrap_or(it.width),
        patch.depth.unwrap_or(it.depth),
    );
    if patch.width.is_some() || patch.depth.is_some() {
        equalise_circle(it.kind, patch.width, patch.depth, &mut w, &mut d);
    }
    it.width = w;
    it.depth = d;
    if let Some(v) = patch.height {
        it.height = v;
    }
    if let Some(r) = patch.rotation {
        if !r.is_finite() {
            return Err(ApiError::invalid("rotation must be a finite number"));
        }
        it.rotation = normalize_deg(r);
    }
    if let Some(params) = patch.params {
        for (k, v) in params {
            if v.is_null() {
                it.params.remove(&k);
            } else {
                it.params.insert(k, v);
            }
        }
    }
    if let Some(n) = patch.notes {
        it.notes = n;
    }
    if let Some(l) = patch.locked {
        it.locked = l;
    }
    if let Some(ids) = patch.source_ids {
        it.source_ids = ids;
    }
    if let Some(prod) = patch.product {
        it.product = prod;
        downgrade_size(it);
    }
    if let Some(sc) = patch.size_certainty {
        it.size_certainty = sc;
    }
    let resized = it.width != old.width
        || it.depth != old.depth
        || it.height != old.height
        || it.params != old.params;
    downgrade_if_moved(it, moved || resized || it.rotation != old.rotation);
    if resized {
        downgrade_size(it);
    }
    if it.size_certainty == SizeCertainty::Estimated {
        it.size_evidence = None;
    }
    for sid in old
        .source_ids
        .iter()
        .filter(|sid| !it.source_ids.contains(sid))
        .cloned()
        .collect::<Vec<_>>()
    {
        invalidate_source(it, &sid);
    }
    check_item(it)?;
    let mut out = Outcome::new(format!("Edit {}", it.name));
    out.changed.push(it.id.clone());
    Ok(out)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SetTransform {
    id: String,
    x: f64,
    y: f64,
    width: f64,
    depth: f64,
    rotation: f64,
}

fn set_transform(p: &mut Project, a: SetTransform) -> Result<Outcome> {
    let idx = item_index(p, &a.id)?;
    if p.items[idx].locked {
        return Err(locked_error(&p.items[idx]));
    }
    if !a.rotation.is_finite() {
        return Err(ApiError::invalid("rotation must be a finite number"));
    }
    let it = &mut p.items[idx];
    let (w, mut d) = (a.width, a.depth);
    if catalog::is_circle(it.kind) {
        d = w;
    }
    let rotation = normalize_deg(a.rotation);
    let moved = differs(a.x, it.x) || differs(a.y, it.y);
    let resized = differs(w, it.width) || differs(d, it.depth);
    let rotated = differs(rotation, it.rotation);
    let verb = if moved || (!resized && !rotated) {
        "Move"
    } else if resized {
        "Resize"
    } else {
        "Rotate"
    };
    it.x = a.x;
    it.y = a.y;
    it.width = w;
    it.depth = d;
    it.rotation = rotation;
    downgrade_if_moved(it, moved || resized || rotated);
    if resized {
        downgrade_size(it);
    }
    check_item(it)?;
    let mut out = Outcome::new(format!("{verb} {}", it.name));
    out.changed.push(it.id.clone());
    Ok(out)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct MoveItems {
    ids: Vec<String>,
    dx: f64,
    dy: f64,
}

fn move_items(p: &mut Project, a: MoveItems) -> Result<Outcome> {
    let idxs = resolve_ids(p, &a.ids)?;
    if !a.dx.is_finite() || !a.dy.is_finite() {
        return Err(ApiError::invalid("dx and dy must be finite numbers"));
    }
    for &i in &idxs {
        if p.items[i].locked {
            return Err(locked_error(&p.items[i]));
        }
    }
    let moved = differs(a.dx, 0.0) || differs(a.dy, 0.0);
    let label = count_label("Move", p, &idxs);
    let mut out = Outcome::new(label);
    for &i in &idxs {
        let it = &mut p.items[i];
        it.x += a.dx;
        it.y += a.dy;
        downgrade_if_moved(it, moved);
        check_item(it)?;
        out.changed.push(it.id.clone());
    }
    Ok(out)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Ids {
    ids: Vec<String>,
}

fn remove_items(p: &mut Project, a: Ids) -> Result<Outcome> {
    let idxs = resolve_ids(p, &a.ids)?;
    let label = count_label("Delete", p, &idxs);
    let mut out = Outcome::new(label);
    out.removed = idxs.iter().map(|&i| p.items[i].id.clone()).collect();
    let mut keep = Vec::with_capacity(p.items.len());
    for (i, it) in p.items.drain(..).enumerate() {
        if !idxs.contains(&i) {
            keep.push(it);
        }
    }
    p.items = keep;
    Ok(out)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DuplicateItems {
    ids: Vec<String>,
    dx: f64,
    dy: f64,
}

fn duplicate_items(p: &mut Project, a: DuplicateItems) -> Result<Outcome> {
    let idxs = resolve_ids(p, &a.ids)?;
    if !a.dx.is_finite() || !a.dy.is_finite() {
        return Err(ApiError::invalid("dx and dy must be finite numbers"));
    }
    if p.items.len() + idxs.len() > MAX_ITEMS {
        return Err(ApiError::limit(format!(
            "A plan holds at most {MAX_ITEMS} items"
        )));
    }
    let label = count_label("Duplicate", p, &idxs);
    let mut out = Outcome::new(label);
    for &i in &idxs {
        let mut copy = p.items[i].clone();
        copy.id = p.alloc_id('i');
        copy.x += a.dx;
        copy.y += a.dy;
        copy.locked = false;
        downgrade_if_moved(&mut copy, true);
        check_item(&copy)?;
        out.created.push(copy.id.clone());
        out.changed.push(copy.id.clone());
        p.items.push(copy);
    }
    Ok(out)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct MarkMeasured {
    id: String,
    evidence: String,
    field: Option<String>,
    note: Option<String>,
    source_id: Option<String>,
}

fn mark_measured(p: &mut Project, a: MarkMeasured) -> Result<Outcome> {
    let idx = item_index(p, &a.id)?;
    if a.evidence != "field_measurement" {
        if let Some(sid) = a.evidence.strip_prefix("registered_source:") {
            source_index(p, sid)?;
            return Err(ApiError::new(ErrorCode::UnregisteredSource,
                "Photo scale calibration cannot establish measured site coordinates. Use an explicit field measurement."));
        }
        return Err(ApiError::invalid("evidence must be 'field_measurement'"));
    }
    if let Some(sid) = &a.source_id {
        source_index(p, sid)?;
        if !p.items[idx].source_ids.contains(sid) {
            return Err(ApiError::invalid(
                "measurement source must be linked to the item",
            ));
        }
    }
    let it = &mut p.items[idx];
    let field = a.field.as_deref().unwrap_or("position");
    let values = match field {
        "position" => [it.x, it.y, it.rotation],
        "size" => [it.width, it.depth, it.height],
        _ => return Err(ApiError::invalid("field must be position or size")),
    };
    let evidence = MeasurementEvidence {
        method: EvidenceMethod::FieldMeasurement,
        values,
        note: a
            .note
            .unwrap_or_else(|| "User asserted field measurement.".into()),
        source_id: a.source_id,
    };
    if field == "position" {
        it.position_certainty = PositionCertainty::Measured;
        it.position_evidence = Some(evidence);
    } else {
        it.size_certainty = SizeCertainty::Measured;
        it.size_evidence = Some(evidence);
    }
    let mut out = Outcome::new(format!("Mark {} measured", it.name));
    out.changed.push(it.id.clone());
    Ok(out)
}

// ---------------------------------------------------------------------------------------------
// Site
// ---------------------------------------------------------------------------------------------

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SetBoundary {
    #[serde(deserialize_with = "required_option")]
    outline: Option<Vec<Pt>>,
    certainty: Option<Certainty>,
}

fn set_boundary(p: &mut Project, a: SetBoundary) -> Result<Outcome> {
    if let Some(o) = &a.outline {
        check_outline(o, "boundary")?;
    }
    p.site.boundary = a.outline;
    if let Some(c) = a.certainty {
        p.site.boundary_certainty = c;
    }
    Ok(Outcome::new("Set boundary".to_string()))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AddStructure {
    name: String,
    outline: Vec<Pt>,
    height: f64,
    certainty: Option<Certainty>,
}

fn add_structure(p: &mut Project, a: AddStructure) -> Result<Outcome> {
    if p.site.structures.len() >= MAX_STRUCTURES {
        return Err(ApiError::limit(format!(
            "A plan holds at most {MAX_STRUCTURES} structures"
        )));
    }
    let name = clean_name(&a.name, "Structure");
    let id = p.alloc_id('s');
    let s = Structure {
        id: id.clone(),
        name: name.clone(),
        outline: a.outline,
        height: a.height,
        certainty: a.certainty.unwrap_or(Certainty::Estimated),
    };
    check_structure(&s)?;
    p.site.structures.push(s);
    let mut out = Outcome::new(format!("Add {name}"));
    out.created.push(id.clone());
    out.changed.push(id);
    Ok(out)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct StructurePatch {
    name: Option<String>,
    outline: Option<Vec<Pt>>,
    height: Option<f64>,
    certainty: Option<Certainty>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UpdateStructure {
    id: String,
    patch: StructurePatch,
}

fn update_structure(p: &mut Project, a: UpdateStructure) -> Result<Outcome> {
    let idx = structure_index(p, &a.id)?;
    let patch = a.patch;
    if patch.name.is_none()
        && patch.outline.is_none()
        && patch.height.is_none()
        && patch.certainty.is_none()
    {
        return Err(ApiError::invalid("patch has no fields"));
    }
    let s = &mut p.site.structures[idx];
    if let Some(n) = patch.name {
        if n.trim().is_empty() {
            return Err(ApiError::invalid("name can't be empty"));
        }
        s.name = n.trim().to_string();
    }
    if let Some(o) = patch.outline {
        s.outline = o;
    }
    if let Some(h) = patch.height {
        s.height = h;
    }
    if let Some(c) = patch.certainty {
        s.certainty = c;
    }
    check_structure(s)?;
    let mut out = Outcome::new(format!("Edit {}", s.name));
    out.changed.push(s.id.clone());
    Ok(out)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct IdArg {
    id: String,
}

fn remove_structure(p: &mut Project, a: IdArg) -> Result<Outcome> {
    let idx = structure_index(p, &a.id)?;
    let s = p.site.structures.remove(idx);
    let mut out = Outcome::new(format!("Delete {}", s.name));
    out.removed.push(s.id);
    Ok(out)
}

// ---------------------------------------------------------------------------------------------
// Sources and backdrop
// ---------------------------------------------------------------------------------------------

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AddSource {
    source: Source,
}

fn add_source(p: &mut Project, a: AddSource) -> Result<Outcome> {
    let s = a.source;
    if s.registration.is_some() {
        return Err(ApiError::invalid(
            "a new source can't arrive registered. Import it, then calibrate it.",
        ));
    }
    if p.sources.len() >= MAX_SOURCES {
        return Err(ApiError::limit(format!(
            "A plan holds at most {MAX_SOURCES} sources"
        )));
    }
    if p.source(&s.id).is_some() {
        return Err(ApiError::invalid(format!(
            "Source {} is already in this plan",
            s.id
        )));
    }
    check_source(&s)?;
    let mut out = Outcome::new(format!("Import {}", s.title));
    out.created.push(s.id.clone());
    out.changed.push(s.id.clone());
    p.sources.push(s);
    Ok(out)
}

fn remove_source(p: &mut Project, a: IdArg) -> Result<Outcome> {
    let idx = source_index(p, &a.id)?;
    let s = p.sources.remove(idx);
    let mut out = Outcome::new(format!("Remove {}", s.title));
    for it in &mut p.items {
        let before = it.source_ids.len();
        it.source_ids.retain(|sid| *sid != s.id);
        let invalidated = invalidate_source(it, &s.id);
        if it.source_ids.len() != before || invalidated {
            out.changed.push(it.id.clone());
        }
    }
    if p.backdrop.as_ref().is_some_and(|b| b.source_id == s.id) {
        p.backdrop = None;
    }
    out.removed.push(s.id);
    Ok(out)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RegisterSource {
    id: String,
    p1: Pt,
    p2: Pt,
    distance_m: f64,
}

fn register_source(p: &mut Project, a: RegisterSource) -> Result<Outcome> {
    let idx = source_index(p, &a.id)?;
    let src = &mut p.sources[idx];
    if src.kind != SourceKind::Photo {
        return Err(ApiError::invalid(format!(
            "{} is not a photo, so it can't be calibrated",
            src.title
        )));
    }
    let reg = Registration {
        p1: a.p1,
        p2: a.p2,
        distance_m: a.distance_m,
    };
    check_registration(&reg, src)?;
    src.registration = Some(reg);
    let mut out = Outcome::new(format!("Calibrate {}", src.title));
    out.changed.push(src.id.clone());
    for it in &mut p.items {
        if invalidate_source(it, &a.id) {
            out.changed.push(it.id.clone());
        }
    }
    derive_backdrop_scale(p);
    Ok(out)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SetBackdrop {
    source_id: Option<String>,
    x: Option<f64>,
    y: Option<f64>,
    rotation: Option<f64>,
    opacity: Option<f64>,
    clear: Option<bool>,
}

fn set_backdrop(p: &mut Project, a: SetBackdrop) -> Result<Outcome> {
    if a.clear == Some(true) {
        if a.source_id.is_some()
            || a.x.is_some()
            || a.y.is_some()
            || a.rotation.is_some()
            || a.opacity.is_some()
        {
            return Err(ApiError::invalid(
                "clear can't be combined with other fields",
            ));
        }
        p.backdrop = None;
        return Ok(Outcome::new("Clear backdrop".to_string()));
    }
    let Some(sid) = a.source_id else {
        return Err(ApiError::invalid(
            "set_backdrop needs a source_id, or clear",
        ));
    };
    source_index(p, &sid)?;
    let rotation = a.rotation.unwrap_or(0.0);
    if !rotation.is_finite() {
        return Err(ApiError::invalid("rotation must be a finite number"));
    }
    p.backdrop = Some(Backdrop {
        source_id: sid,
        x: a.x.unwrap_or(0.0),
        y: a.y.unwrap_or(0.0),
        rotation: normalize_deg(rotation),
        opacity: a.opacity.unwrap_or(0.6),
        meters_per_pixel: None,
    });
    derive_backdrop_scale(p);
    Ok(Outcome::new("Set backdrop".to_string()))
}

// ---------------------------------------------------------------------------------------------
// Project
// ---------------------------------------------------------------------------------------------

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SetProjectMeta {
    name: Option<String>,
    units: Option<Units>,
}

fn set_project_meta(p: &mut Project, a: SetProjectMeta) -> Result<Outcome> {
    if a.name.is_none() && a.units.is_none() {
        return Err(ApiError::invalid("set_project_meta needs a name or units"));
    }
    let label = if a.name.is_some() {
        "Rename plan"
    } else {
        "Change units"
    };
    if let Some(n) = a.name {
        if n.trim().is_empty() {
            return Err(ApiError::invalid("name can't be empty"));
        }
        p.name = n.trim().to_string();
    }
    if let Some(u) = a.units {
        p.units = u;
    }
    Ok(Outcome::new(label.to_string()))
}
