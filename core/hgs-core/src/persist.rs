//! Loading and saving. Saving is canonical: pretty-printed, declared key order, sorted params.

use crate::error::{ApiError, ErrorCode, Result};
use crate::geometry::normalize_deg;
use crate::model::*;
use crate::validate::check_project;

/// Canonical file text for a project.
pub fn save(p: &Project) -> String {
    serde_json::to_string_pretty(p).unwrap_or_else(|_| "{}".to_string())
}

/// Compact JSON, used for the layout hash.
pub fn compact(p: &Project) -> String {
    serde_json::to_string(p).unwrap_or_else(|_| "{}".to_string())
}

fn json_error(e: &serde_json::Error) -> ApiError {
    use serde_json::error::Category;
    match e.classify() {
        Category::Data => ApiError::new(ErrorCode::InvalidValue, e.to_string()),
        _ => ApiError::new(ErrorCode::InvalidJson, e.to_string()),
    }
}

/// Repairs what can be repaired without guessing: rotations are normalised, `next_seq` is moved
/// above every id number, and the backdrop scale is re-derived from its source.
pub fn repair(p: &mut Project) {
    for it in &mut p.items {
        it.rotation = normalize_deg(it.rotation);
    }
    let max_suffix = p
        .items
        .iter()
        .map(|i| i.id.as_str())
        .chain(p.site.structures.iter().map(|s| s.id.as_str()))
        .filter_map(id_suffix)
        .max()
        .unwrap_or(0);
    if p.next_seq <= max_suffix {
        p.next_seq = max_suffix + 1;
    }
    if p.next_seq == 0 {
        p.next_seq = 1;
    }
    derive_backdrop_scale(p);
}

/// Sets `backdrop.meters_per_pixel` from the source registration (null when unregistered).
pub fn derive_backdrop_scale(p: &mut Project) {
    let Some(b) = &p.backdrop else { return };
    let scale = p
        .sources
        .iter()
        .find(|s| s.id == b.source_id)
        .and_then(|s| s.registration.as_ref())
        .map(|r| r.meters_per_pixel());
    if let Some(b) = &mut p.backdrop {
        b.rotation = normalize_deg(b.rotation);
        b.meters_per_pixel = scale;
    }
}

/// Parses and validates a project file.
pub fn load(json: &str) -> Result<Project> {
    check_bytes(json, MAX_DOCUMENT_BYTES)?;
    let value: serde_json::Value = serde_json::from_str(json).map_err(|e| json_error(&e))?;
    let schema = match value.get("schema") {
        Some(s) => s.as_u64(),
        None => None,
    };
    match schema {
        None | Some(0) => {
            return Err(ApiError::invalid(
                "the project file has a missing or invalid schema",
            ))
        }
        Some(s) if s > u64::from(SCHEMA) => {
            return Err(ApiError::new(
                ErrorCode::SchemaTooNew,
                format!(
                    "this project uses schema {s}, but this version of the app reads schema {SCHEMA}. Update the app to open it."
                ),
            ))
        }
        Some(_) => {}
    }
    let mut project: Project = serde_json::from_value(value).map_err(|e| json_error(&e))?;
    repair(&mut project);
    check_project(&project)?;
    check_bytes(&save(&project), MAX_DOCUMENT_BYTES)?;
    Ok(project)
}

/// Reject inputs before JSON parsing/allocation.
pub fn check_bytes(input: &str, limit: usize) -> Result<()> {
    if input.len() > limit {
        Err(ApiError::limit(format!(
            "input exceeds {limit} UTF-8 bytes"
        )))
    } else {
        Ok(())
    }
}
