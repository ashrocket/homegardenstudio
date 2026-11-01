//! Read-only queries. Every query returns `{"ok":true,"result":...}` or an error envelope.

use crate::catalog;
use crate::engine::Engine;
use crate::error::{ApiError, ErrorCode, Result};
use crate::geometry::{self, clean, clean_pt, Transform};
use crate::model::*;
use crate::validate::{self, Layout};
use crate::{brief, persist, projection, scene};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;

#[derive(Serialize)]
struct Envelope<'a, T: Serialize> {
    ok: bool,
    result: &'a T,
}

fn ok<T: Serialize>(result: &T) -> Result<String> {
    serde_json::to_string(&Envelope { ok: true, result })
        .map_err(|e| ApiError::new(ErrorCode::Internal, e.to_string()))
}

fn parse_args<T: DeserializeOwned>(mut args: Map<String, Value>) -> Result<T> {
    args.remove("q");
    serde_json::from_value(Value::Object(args)).map_err(|e| ApiError::invalid(e.to_string()))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct NoArgs {}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SnapshotArgs {
    text: Option<bool>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct IdArgs {
    id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PreviewArgs {
    id: String,
    x: f64,
    y: f64,
    width: f64,
    depth: f64,
    rotation: f64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ResizeArgs {
    id: String,
    handle: [f64; 2],
    point: Pt,
    proportional: Option<bool>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RotateArgs {
    id: String,
    start: Pt,
    point: Pt,
    snap: Option<bool>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct HitArgs {
    point: Pt,
    tolerance: Option<f64>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct IsoArgs {
    view_angle: f64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BriefArgs {
    style: Option<String>,
}

fn item<'a>(p: &'a Project, id: &str) -> Result<&'a Item> {
    p.item(id)
        .ok_or_else(|| ApiError::not_found(format!("No item {id}")))
}

fn finite_pt(p: Pt, what: &str) -> Result<()> {
    validate::check_coord(p[0], &format!("{what} x"))?;
    validate::check_coord(p[1], &format!("{what} y"))
}

fn check_handle(h: [f64; 2]) -> Result<()> {
    if h.iter().all(|v| *v == 1.0 || *v == -1.0) {
        Ok(())
    } else {
        Err(ApiError::invalid(
            "handle must be [sx, sy] with each value 1 or -1",
        ))
    }
}

pub fn run(engine: &Engine, json: &str) -> String {
    match dispatch(engine, json) {
        Ok(s) => s,
        Err(e) => e.to_json(),
    }
}

fn dispatch(engine: &Engine, json: &str) -> Result<String> {
    persist::check_bytes(json, MAX_QUERY_BYTES)?;
    let value: Value = serde_json::from_str(json)
        .map_err(|e| ApiError::new(ErrorCode::InvalidJson, e.to_string()))?;
    let Value::Object(map) = value else {
        return Err(ApiError::invalid("a query must be a JSON object"));
    };
    let q = match map.get("q") {
        Some(Value::String(s)) => s.clone(),
        _ => return Err(ApiError::invalid("a query needs a 'q' string")),
    };
    let p = &engine.project;
    match q.as_str() {
        "snapshot" => {
            let a: SnapshotArgs = parse_args(map)?;
            if a.text == Some(true) {
                ok(&persist::save(p))
            } else {
                ok(p)
            }
        }
        "history" => {
            parse_args::<NoArgs>(map)?;
            let (can_undo, can_redo, undo_label, redo_label) = engine.history_info();
            ok(&json!({
                "revision": engine.revision,
                "can_undo": can_undo,
                "can_redo": can_redo,
                "undo_label": undo_label,
                "redo_label": redo_label,
            }))
        }
        "catalog" => {
            parse_args::<NoArgs>(map)?;
            ok(&catalog::all())
        }
        "validate" => {
            parse_args::<NoArgs>(map)?;
            ok(&validate::validate(p))
        }
        "outline" => {
            let a: IdArgs = parse_args(map)?;
            let it = item(p, &a.id)?;
            ok(&clean_outline(&geometry::footprint(it)))
        }
        "preview_transform" => preview_transform(p, parse_args(map)?),
        "resize_handle" => {
            let a: ResizeArgs = parse_args(map)?;
            check_handle(a.handle)?;
            finite_pt(a.point, "point")?;
            let it = item(p, &a.id)?;
            let t = geometry::resize_from_handle(
                it,
                a.handle,
                a.point,
                a.proportional.unwrap_or(false),
            );
            ok(&json!({
                "x": clean(t.x),
                "y": clean(t.y),
                "width": t.width,
                "depth": t.depth,
                "rotation": t.rotation,
            }))
        }
        "rotate_handle" => {
            let a: RotateArgs = parse_args(map)?;
            finite_pt(a.start, "start")?;
            finite_pt(a.point, "point")?;
            let it = item(p, &a.id)?;
            let (rotation, delta) =
                geometry::rotate_from_handle(it, a.start, a.point, a.snap.unwrap_or(false));
            ok(&json!({ "rotation": rotation, "delta": delta }))
        }
        "hit_test" => {
            let a: HitArgs = parse_args(map)?;
            finite_pt(a.point, "point")?;
            let tol = a.tolerance.unwrap_or(0.0);
            if !tol.is_finite() || !(0.0..=MAX_DIM).contains(&tol) {
                return Err(ApiError::invalid("tolerance must be between 0 and 100"));
            }
            ok(&hit_test(p, a.point, tol))
        }
        "isometric" => {
            let a: IsoArgs = parse_args(map)?;
            if !a.view_angle.is_finite() {
                return Err(ApiError::invalid("view_angle must be a finite number"));
            }
            ok(&projection::isometric(p, a.view_angle))
        }
        "scene" => {
            parse_args::<NoArgs>(map)?;
            ok(&scene::scene(p))
        }
        "render_brief" => {
            let a: BriefArgs = parse_args(map)?;
            if let Some(style) = &a.style {
                validate::check_text(style, "style", MAX_TEXT)?;
            }
            ok(&brief::render_brief(p, a.style.as_deref()))
        }
        "stats" => {
            parse_args::<NoArgs>(map)?;
            ok(&stats(p))
        }
        other => Err(ApiError::new(
            ErrorCode::UnknownOp,
            format!("Unknown query '{other}'"),
        )),
    }
}

fn clean_outline(poly: &[Pt]) -> Vec<Pt> {
    poly.iter().map(|p| clean_pt(*p)).collect()
}

fn hit_test(p: &Project, at: Pt, tolerance: f64) -> Option<String> {
    p.items.iter().rev().find_map(|it| {
        let fp = geometry::footprint(it);
        let hit = geometry::classify(at, &fp) != geometry::Side::Outside
            || (tolerance > 0.0 && geometry::dist_point_boundary(at, &fp) <= tolerance);
        hit.then(|| it.id.clone())
    })
}

#[derive(Serialize)]
struct Preview {
    outline: Vec<Pt>,
    issues: Vec<validate::Issue>,
}

fn preview_transform(p: &Project, a: PreviewArgs) -> Result<String> {
    let idx = p
        .item_index(&a.id)
        .ok_or_else(|| ApiError::not_found(format!("No item {}", a.id)))?;
    let mut proposed = p.items[idx].clone();
    let (w, mut d) = (a.width, a.depth);
    if catalog::is_circle(proposed.kind) {
        d = w;
    }
    let rotation = geometry::normalize_deg(a.rotation);
    if !a.rotation.is_finite() {
        return Err(ApiError::invalid("rotation must be a finite number"));
    }
    let moved = geometry::item_transform(&proposed)
        != Transform {
            x: a.x,
            y: a.y,
            width: w,
            depth: d,
            rotation,
        };
    if proposed.locked && moved {
        return Err(ApiError::locked(format!(
            "{} is locked. Unlock it to change it.",
            proposed.name
        )));
    }
    proposed.x = a.x;
    proposed.y = a.y;
    proposed.width = w;
    proposed.depth = d;
    proposed.rotation = rotation;
    proposed.position_certainty = PositionCertainty::Estimated;
    proposed.position_evidence = None;
    proposed.size_certainty = SizeCertainty::Estimated;
    proposed.size_evidence = None;
    validate::check_item(&proposed)?;
    let mut layout = Layout::new(p);
    layout.footprints[idx] = geometry::footprint(&proposed);
    layout.boxes[idx] = geometry::bbox(&layout.footprints[idx]);
    let issues = validate::issues_for(p, &layout, idx, &proposed, true);
    ok(&Preview {
        outline: clean_outline(&layout.footprints[idx]),
        issues,
    })
}

fn stats(p: &Project) -> Value {
    let mut by_kind: BTreeMap<&str, u64> = BTreeMap::new();
    let mut area: BTreeMap<&str, f64> = BTreeMap::new();
    for it in &p.items {
        *by_kind.entry(it.kind.as_str()).or_insert(0) += 1;
        *area.entry(it.kind.as_str()).or_insert(0.0) +=
            geometry::polygon_area(&geometry::footprint(it));
    }
    let area: BTreeMap<&str, f64> = area
        .into_iter()
        .map(|(k, v)| (k, (v * 1e6).round() / 1e6))
        .collect();
    json!({
        "item_count": p.items.len(),
        "by_kind": by_kind,
        "area_m2_by_kind": area,
    })
}
