use hgs_core::{
    brief, geometry,
    history::{History, MAX_HISTORY_BYTES},
    model::*,
    persist, scene, Engine,
};
use serde_json::{json, Value};
fn run(e: &mut Engine, v: Value) -> Value {
    serde_json::from_str(&e.command(&v.to_string())).unwrap()
}
fn ok(e: &mut Engine, v: Value) -> Value {
    let r = run(e, v);
    assert_eq!(r["ok"], true, "{r}");
    r
}
fn query(e: &Engine, v: Value) -> Value {
    let r: Value = serde_json::from_str(&e.query(&v.to_string())).unwrap();
    assert_eq!(r["ok"], true, "{r}");
    r["result"].clone()
}
fn add(e: &mut Engine, kind: &str, x: f64, y: f64) -> String {
    ok(e, json!({"op":"add_item","kind":kind,"x":x,"y":y}))["created"][0]
        .as_str()
        .unwrap()
        .into()
}
fn mark(e: &mut Engine, id: &str, field: &str, source: Option<&str>) {
    ok(
        e,
        json!({"op":"mark_measured","id":id,"evidence":"field_measurement","field":field,"note":"Tape measurement from reference corner","source_id":source}),
    );
}
fn source(e: &mut Engine) -> String {
    let hash = "a".repeat(64);
    let id = format!("src-{}", &hash[..16]);
    ok(
        e,
        json!({"op":"add_source","source":{"id":id,"kind":"photo","title":"Synthetic photo","original_filename":"synthetic.png","sha256":hash,"byte_count":20,"media_type":"image/png","url":null,"pixel_width":1000,"pixel_height":1000,"registration":null,"note":"Synthetic fixture"}}),
    );
    id
}
fn calibrate(e: &mut Engine, sid: &str, d: f64) {
    ok(
        e,
        json!({"op":"register_source","id":sid,"p1":[0,0],"p2":[100,0],"distance_m":d}),
    );
}
fn link(e: &mut Engine, id: &str, sid: &str) {
    ok(
        e,
        json!({"op":"update_item","id":id,"patch":{"source_ids":[sid]}}),
    );
}
fn unchanged_failure(e: &mut Engine, v: Value, code: &str) {
    let before = e.save();
    let history = e.query(r#"{"q":"history"}"#);
    let r = run(e, v);
    assert_eq!(r["error"]["code"], code, "{r}");
    assert_eq!(e.save(), before);
    assert_eq!(e.query(r#"{"q":"history"}"#), history);
}
#[test]
fn evidence_round_trip_and_tampering() {
    let mut e = Engine::new("Synthetic");
    let id = add(&mut e, "sauna", 2.0, 3.0);
    mark(&mut e, &id, "position", None);
    mark(&mut e, &id, "size", None);
    let text = e.save();
    assert_eq!(Engine::open(&text).unwrap().save(), text);
    let mut v: Value = serde_json::from_str(&text).unwrap();
    v["items"][0]["position_evidence"] = Value::Null;
    assert!(Engine::open(&v.to_string()).is_err());
    let mut v: Value = serde_json::from_str(&text).unwrap();
    v["items"][0]["width"] = json!(5);
    assert!(Engine::open(&v.to_string()).is_err());
    let it = &e.project().items[0];
    assert_eq!(
        it.position_evidence.as_ref().unwrap().values,
        [2.0, 3.0, 0.0]
    );
    assert_eq!(
        it.size_evidence.as_ref().unwrap().method,
        EvidenceMethod::FieldMeasurement
    );
}
#[test]
fn scale_never_establishes_coordinates_or_unrelated_evidence() {
    let mut e = Engine::new("Synthetic");
    let id = add(&mut e, "plant", 1.0, 1.0);
    let sid = source(&mut e);
    calibrate(&mut e, &sid, 4.0);
    unchanged_failure(
        &mut e,
        json!({"op":"mark_measured","id":id,"evidence":format!("registered_source:{sid}")}),
        "UNREGISTERED_SOURCE",
    );
    unchanged_failure(
        &mut e,
        json!({"op":"mark_measured","id":id,"evidence":"field_measurement","source_id":sid}),
        "INVALID_VALUE",
    );
    link(&mut e, &id, &sid);
    unchanged_failure(
        &mut e,
        json!({"op":"mark_measured","id":id,"evidence":format!("registered_source:{sid}")}),
        "UNREGISTERED_SOURCE",
    );
}
#[test]
fn source_removal_recalibration_and_unlink_invalidate_evidence() {
    for action in ["remove_source", "register_source", "unlink"] {
        let mut e = Engine::new("Synthetic");
        let id = add(&mut e, "plant", 1.0, 1.0);
        let sid = source(&mut e);
        link(&mut e, &id, &sid);
        mark(&mut e, &id, "position", Some(&sid));
        mark(&mut e, &id, "size", Some(&sid));
        if action == "register_source" {
            calibrate(&mut e, &sid, 6.0);
        } else if action == "unlink" {
            ok(
                &mut e,
                json!({"op":"update_item","id":id,"patch":{"source_ids":[]}}),
            );
        } else {
            ok(&mut e, json!({"op":action,"id":sid}));
        }
        let it = &e.project().items[0];
        assert_eq!(it.position_certainty, PositionCertainty::Estimated);
        assert_eq!(it.size_certainty, SizeCertainty::Estimated);
        assert!(it.position_evidence.is_none() && it.size_evidence.is_none());
        ok(&mut e, json!({"op":"undo"}));
        assert_eq!(
            e.project().items[0].position_certainty,
            PositionCertainty::Measured
        );
        assert_eq!(e.project().sources.len(), 1);
    }
}
#[test]
fn geometry_mutations_invalidate_only_supported_fields() {
    for patch in [
        json!({"x":4}),
        json!({"rotation":45}),
        json!({"width":4}),
        json!({"height":4}),
    ] {
        let mut e = Engine::new("Synthetic");
        let id = add(&mut e, "sauna", 1.0, 1.0);
        mark(&mut e, &id, "position", None);
        ok(&mut e, json!({"op":"update_item","id":id,"patch":patch}));
        let it = &e.project().items[0];
        assert_eq!(it.position_certainty, PositionCertainty::Estimated);
        if patch.get("width").is_some() || patch.get("height").is_some() {
            assert_eq!(it.size_certainty, SizeCertainty::Estimated);
        } else {
            assert_eq!(it.size_certainty, SizeCertainty::ProductListing);
        }
    }
    let mut e = Engine::new("Synthetic");
    let id = add(&mut e, "sauna", 1.0, 1.0);
    mark(&mut e, &id, "position", None);
    ok(
        &mut e,
        json!({"op":"set_transform","id":id,"x":1,"y":1,"width":4,"depth":4,"rotation":0}),
    );
    assert_eq!(
        e.project().items[0].size_certainty,
        SizeCertainty::Estimated
    );
    assert!(e.project().items[0].position_evidence.is_none());
}
#[test]
fn asserted_flags_cannot_forge_measurement_or_listing() {
    let mut e = Engine::new("Synthetic");
    let id = add(&mut e, "plant", 0.0, 0.0);
    for certainty in ["measured", "product_listing"] {
        unchanged_failure(
            &mut e,
            json!({"op":"update_item","id":id,"patch":{"size_certainty":certainty}}),
            "INVALID_VALUE",
        );
    }
}
#[test]
fn move_duplicate_and_undo_have_honest_provenance() {
    let mut e = Engine::new("Synthetic");
    let id = add(&mut e, "plant", 0.0, 0.0);
    mark(&mut e, &id, "position", None);
    ok(
        &mut e,
        json!({"op":"duplicate_items","ids":[id],"dx":0,"dy":0}),
    );
    assert_eq!(
        e.project().items[1].position_certainty,
        PositionCertainty::Estimated
    );
    ok(&mut e, json!({"op":"move_items","ids":[id],"dx":2,"dy":0}));
    assert!(e.project().items[0].position_evidence.is_none());
    ok(&mut e, json!({"op":"undo"}));
    assert!(e.project().items[0].position_evidence.is_some());
    ok(&mut e, json!({"op":"redo"}));
    assert!(e.project().items[0].position_evidence.is_none());
}
#[test]
fn traced_photo_links_source_and_remains_estimated_after_scale() {
    let mut e = Engine::new("Synthetic");
    let sid = source(&mut e);
    ok(&mut e, json!({"op":"set_backdrop","source_id":sid}));
    ok(
        &mut e,
        json!({"op":"add_item","kind":"plant","x":1,"y":1,"traced_from_backdrop":true}),
    );
    assert_eq!(e.project().items[0].source_ids, vec![sid.clone()]);
    assert_eq!(
        e.project().items[0].position_certainty,
        PositionCertainty::UnregisteredPhoto
    );
    calibrate(&mut e, &sid, 4.0);
    ok(
        &mut e,
        json!({"op":"add_item","kind":"plant","x":2,"y":2,"traced_from_backdrop":true}),
    );
    assert_eq!(
        e.project().items[1].position_certainty,
        PositionCertainty::Estimated
    );
    assert_eq!(
        e.project().backdrop.as_ref().unwrap().meters_per_pixel,
        Some(0.04)
    );
}
#[test]
fn invalid_commands_preserve_document_and_redo() {
    let mut e = Engine::new("Synthetic");
    let id = add(&mut e, "plant", 0.0, 0.0);
    ok(&mut e, json!({"op":"set_project_meta","name":"Next"}));
    ok(&mut e, json!({"op":"undo"}));
    unchanged_failure(
        &mut e,
        json!({"op":"move_items","ids":[id],"dx":10001,"dy":0}),
        "LIMIT_EXCEEDED",
    );
    unchanged_failure(
        &mut e,
        json!({"op":"set_project_meta","name":"x".repeat(MAX_NAME+1)}),
        "LIMIT_EXCEEDED",
    );
    unchanged_failure(
        &mut e,
        json!({"op":"update_item","id":id,"patch":{"notes":"x".repeat(MAX_COMMAND_BYTES)}}),
        "LIMIT_EXCEEDED",
    );
    unchanged_failure(
        &mut e,
        json!({"op":"set_boundary","outline":vec![[0,0];MAX_OUTLINE_POINTS+1]}),
        "LIMIT_EXCEEDED",
    );
    assert_eq!(query(&e, json!({"q":"history"}))["can_redo"], true);
}
#[test]
fn oversized_and_deep_imports_fail_before_replacing_any_state() {
    assert!(Engine::open(&" ".repeat(MAX_DOCUMENT_BYTES + 1)).is_err());
    let deep = format!("{}0{}", "[".repeat(200), "]".repeat(200));
    assert!(Engine::open(&deep).is_err());
    let mut e = Engine::new("Synthetic");
    let before = e.save();
    let r: Value = serde_json::from_str(&e.command(&deep)).unwrap();
    assert_eq!(r["ok"], false);
    assert_eq!(before, e.save());
    let r: Value = serde_json::from_str(&e.query(&" ".repeat(MAX_QUERY_BYTES + 1))).unwrap();
    assert_eq!(r["error"]["code"], "LIMIT_EXCEEDED");
}
#[test]
fn near_item_limit_roundtrip_and_history_budget() {
    let mut e = Engine::new("Synthetic");
    add(&mut e, "plant", 0.0, 0.0);
    let template = e.project().items[0].clone();
    let mut p = e.project().clone();
    p.items = (1..=MAX_ITEMS)
        .map(|n| {
            let mut it = template.clone();
            it.id = format!("i{n}");
            it
        })
        .collect();
    p.next_seq = MAX_ITEMS as u64 + 1;
    let text = persist::save(&p);
    assert!(text.len() < MAX_DOCUMENT_BYTES);
    let loaded = Engine::open(&text).unwrap();
    assert_eq!(loaded.project().items.len(), MAX_ITEMS);
    let mut h = History::new();
    for _ in 0..25 {
        h.record("Edit".into(), p.clone());
        assert!(h.storage_bytes() <= MAX_HISTORY_BYTES);
    }
    assert!(h.undo_len() < 25);
    let back = h.undo(p.clone()).unwrap();
    assert_eq!(back.items.len(), MAX_ITEMS);
    assert!(h.storage_bytes() <= MAX_HISTORY_BYTES);
    assert_eq!(h.redo(back).unwrap().items.len(), MAX_ITEMS);
}
#[test]
fn persistence_repairs_ids_and_rejects_schema_and_unknown_fields() {
    let mut e = Engine::new("Synthetic");
    add(&mut e, "plant", 0.0, 0.0);
    let mut v: Value = serde_json::from_str(&e.save()).unwrap();
    v["next_seq"] = json!(1);
    v["items"][0]["rotation"] = json!(-90);
    let opened = Engine::open(&v.to_string()).unwrap();
    assert_eq!(opened.project().next_seq, 2);
    assert_eq!(opened.project().items[0].rotation, 270.0);
    v["schema"] = json!(2);
    assert_eq!(
        Engine::open(&v.to_string()).err().unwrap().code,
        hgs_core::ErrorCode::SchemaTooNew
    );
    v["schema"] = json!(1);
    v["secret"] = json!("not allowed");
    assert!(Engine::open(&v.to_string()).is_err());
}
#[test]
fn all_catalog_items_have_nonempty_native_geometry() {
    let mut e = Engine::new("Synthetic");
    for (n, kind) in Kind::ALL.iter().enumerate() {
        add(&mut e, kind.as_str(), n as f64 * 10.0, 0.0);
    }
    let s = scene::scene(e.project());
    for it in &e.project().items {
        assert!(s.primitives.iter().any(|p| p.item_id == it.id));
    }
    for p in &s.primitives {
        assert!(p.center.iter().chain(&p.size).all(|n| n.is_finite()));
        assert!(p.size.iter().all(|n| *n >= 0.0));
    }
    assert!(s.ground.min[0] < 0.0);
    assert!(s.ground.max[0] > 130.0);
    assert_eq!(
        scene::scene(&Project::new("Empty")).ground.min,
        [-2.0, -2.0]
    );
}
#[test]
fn compound_scene_rotates_l_screen_and_pergola_parts() {
    let mut e = Engine::new("Synthetic");
    let id = add(&mut e, "bin_screen", 10.0, 20.0);
    ok(
        &mut e,
        json!({"op":"set_transform","id":id,"x":10,"y":20,"width":2,"depth":1,"rotation":90}),
    );
    let s = scene::scene(e.project());
    assert_eq!(s.primitives.len(), 2);
    assert_eq!(s.primitives[0].rotation_y, -90.0);
    assert_eq!(s.primitives[0].center, [10.475, 0.6858, 20.0]);
    assert_eq!(s.primitives[1].size, [0.05, 1.3716, 0.95]);
    let mut e = Engine::new("Synthetic");
    add(&mut e, "pergola", 0.0, 0.0);
    let s = scene::scene(e.project());
    assert_eq!(s.primitives.len(), 14);
    assert_eq!(
        s.primitives
            .iter()
            .filter(|p| p.material == "wood_light")
            .count(),
        8
    );
}
#[test]
fn render_brief_binds_precise_layout_sources_and_uncertainty() {
    let mut e = Engine::new("Synthetic");
    let id = add(&mut e, "bin_screen", 1.234567, 2.345678);
    source(&mut e);
    let b = brief::render_brief(e.project(), Some("Summer"));
    assert!(b.prompt.contains("no roof"));
    assert!(b.prompt.contains("(1.234567, 2.345678)"));
    assert!(b.prompt.contains("Synthetic photo"));
    assert!(b.prompt.contains("not a survey"));
    assert_eq!(b.items.len(), 1);
    assert_eq!(b.layout_hash.len(), 16);
    assert_eq!(
        b.layout_hash,
        brief::render_brief(e.project(), None).layout_hash
    );
    ok(
        &mut e,
        json!({"op":"move_items","ids":[id],"dx":0.001,"dy":0}),
    );
    assert_ne!(
        b.layout_hash,
        brief::render_brief(e.project(), None).layout_hash
    );
}
#[test]
fn rotated_outline_and_resize_keep_opposite_corner_fixed() {
    let mut e = Engine::new("Synthetic");
    let id = add(&mut e, "sauna", 4.0, 5.0);
    ok(
        &mut e,
        json!({"op":"set_transform","id":id,"x":4,"y":5,"width":2,"depth":1,"rotation":90}),
    );
    let points = query(&e, json!({"q":"outline","id":id}));
    assert_eq!(
        points,
        json!([[4.5, 4.0], [4.5, 6.0], [3.5, 6.0], [3.5, 4.0]])
    );
    let t = query(
        &e,
        json!({"q":"resize_handle","id":id,"handle":[1,1],"point":[2.5,7],"proportional":false}),
    );
    assert_eq!(t["width"], 3.0);
    assert_eq!(t["depth"], 2.0);
    assert_eq!(t["x"], 3.5);
    assert_eq!(t["y"], 5.5);
}
#[test]
fn concave_containment_checks_edges_not_only_vertices() {
    let boundary = vec![
        [0.0, 0.0],
        [5.0, 0.0],
        [5.0, 5.0],
        [3.0, 5.0],
        [3.0, 2.0],
        [2.0, 2.0],
        [2.0, 5.0],
        [0.0, 5.0],
    ];
    let bridge = vec![[1.0, 3.0], [4.0, 3.0], [4.0, 4.0], [1.0, 4.0]];
    assert!(!geometry::contains_polygon(&boundary, &bridge));
}
#[test]
fn overlap_touching_and_fire_clearance_have_distinct_rules() {
    let mut e = Engine::new("Synthetic");
    add(&mut e, "patio", 0.0, 0.0);
    add(&mut e, "patio", 3.6576, 0.0);
    let issues = query(&e, json!({"q":"validate"}));
    assert!(!issues
        .as_array()
        .unwrap()
        .iter()
        .any(|i| i["code"] == "overlaps_item"));
    let mut e = Engine::new("Synthetic");
    add(&mut e, "fire_pit", 0.0, 0.0);
    add(&mut e, "sauna", 3.0, 0.0);
    let issues = query(&e, json!({"q":"validate"}));
    assert!(issues
        .as_array()
        .unwrap()
        .iter()
        .any(|i| i["code"] == "fire_clearance"));
}
#[test]
fn locked_edits_and_preview_leave_history_untouched() {
    let mut e = Engine::new("Synthetic");
    let id = add(&mut e, "sauna", 0.0, 0.0);
    let before = e.save();
    let history = e.query(r#"{"q":"history"}"#);
    query(
        &e,
        json!({"q":"preview_transform","id":id,"x":2,"y":3,"width":4,"depth":5,"rotation":45}),
    );
    assert_eq!(e.save(), before);
    assert_eq!(e.query(r#"{"q":"history"}"#), history);
    ok(
        &mut e,
        json!({"op":"update_item","id":id,"patch":{"locked":true}}),
    );
    unchanged_failure(
        &mut e,
        json!({"op":"move_items","ids":[id],"dx":1,"dy":0}),
        "LOCKED",
    );
}
#[test]
fn isometric_faces_are_depth_sorted_and_finite() {
    let mut e = Engine::new("Synthetic");
    add(&mut e, "sauna", 1.0, 2.0);
    add(&mut e, "pergola", 10.0, 4.0);
    let iso = query(&e, json!({"q":"isometric","view_angle":45}));
    let faces = iso["faces"].as_array().unwrap();
    assert!(faces.len() >= 4);
    assert!(faces
        .windows(2)
        .all(|w| w[0]["depth"].as_f64().unwrap() <= w[1]["depth"].as_f64().unwrap()));
}

#[test]
fn canonical_float_roundtrip_and_undo_are_exact() {
    let mut e = Engine::new("Synthetic");
    let id = add(&mut e, "sauna", 1.2345678901234567, 9.876543210987655);
    mark(&mut e, &id, "position", None);
    let before = e.save();
    assert_eq!(Engine::open(&before).unwrap().save(), before);
    ok(&mut e, json!({"op":"move_items","ids":[id],"dx":1,"dy":1}));
    ok(&mut e, json!({"op":"undo"}));
    assert_eq!(e.save(), before);
}

#[test]
fn measured_flags_without_evidence_and_bad_references_fail_load() {
    let mut e = Engine::new("Synthetic");
    add(&mut e, "plant", 0.0, 0.0);
    let base: Value = serde_json::from_str(&e.save()).unwrap();
    for key in ["position_certainty", "size_certainty"] {
        let mut v = base.clone();
        v["items"][0][key] = json!("measured");
        assert!(Engine::open(&v.to_string()).is_err());
    }
    let mut v = base.clone();
    v["items"][0]["source_ids"] = json!(["missing"]);
    assert!(Engine::open(&v.to_string()).is_err());
    let mut v = base;
    v["items"][0]["params"] = json!({"species":["nested"]});
    assert!(Engine::open(&v.to_string()).is_err());
}
