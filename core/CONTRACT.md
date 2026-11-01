# HomeGardenStudio engine contract (v1)

The Rust engine owns the project model, geometry, validation, history and persistence. Apple UI code talks to it only through the C ABI below, passing UTF-8 JSON. The engine has no clock, no randomness, no file or network access. It is deterministic: the same commands always give the same JSON.

## Units and coordinates

- Lengths are metres (`f64`). Display units (imperial or metric) are a project preference only.
- Plan space: origin top-left, `+x` right (east), `+y` down (south). An item's `x`,`y` is its footprint centre.
- `rotation` is degrees clockwise in plan space, normalised to `[0, 360)`.
- 3D space (scene query): `y` up; plan `x` → 3D `x`, plan `y` → 3D `z`. `rotation_y` is degrees counter-clockwise about `+y` (right-handed), always `-rotation`; compound items rotate their parts about the item centre.
- Limits: item width/depth `0.05..=100`, height `0..=30`, coordinates `|v| <= 10_000`, at most 5000 items, 64 structures, 2000 sources. Non-finite numbers are rejected.

## JSON model (serde, `snake_case`, unknown fields rejected on load)

```json
{
  "schema": 1,
  "name": "Backyard plan",
  "units": "imperial",
  "next_seq": 7,
  "site": {
    "boundary": null,
    "boundary_certainty": "estimated",
    "structures": [
      {"id": "s1", "name": "House", "outline": [[0,0],[12,0],[12,9],[0,9]], "height": 6.0, "certainty": "estimated"}
    ]
  },
  "items": [
    {
      "id": "i3", "kind": "sauna", "name": "Sauna",
      "x": 14.0, "y": 6.0, "width": 2.2098, "depth": 2.0066, "height": 2.2098, "rotation": 0.0,
      "params": {},
      "position_certainty": "estimated",
      "size_certainty": "product_listing",
      "source_ids": [],
      "product": {"title": "Refugio Black Square Premium (listed 87 x 79 x 87 in)", "url": "https://refugiosaunaco.com/products/black-square-premium-thermo-spruce-outdoor-cube-sauna-4-to-6-person-capacity", "listed_dimensions": "87 in W x 79 in L x 87 in H"},
      "locked": false,
      "notes": ""
    }
  ],
  "sources": [
    {"id": "src-<sha256 first 16 hex>", "kind": "photo", "title": "Back view", "original_filename": "IMG_0001.HEIC",
     "sha256": "<64 hex>", "byte_count": 123456, "media_type": "image/heic", "url": null,
     "pixel_width": 4032, "pixel_height": 3024, "registration": null, "note": ""}
  ],
  "backdrop": null
}
```

- `kind` (enum): `plant`, `tree`, `pond`, `fire_pit`, `pergola`, `sauna`, `tool_shed`, `bin_screen`, `patio`, `raised_bed`, `path`, `fence`, `privacy_screen`, `structure`.
- Certainty enums. `position_certainty` is one of `measured`, `estimated` or `unregistered_photo`. `size_certainty` is one of `measured`, `estimated` or `product_listing`. `boundary_certainty` and a structure's `certainty` are `measured` or `estimated`.
- Source `kind` is `photo`, `file` or `url`. The host computes `id`, `sha256` and `byte_count` and stores the original bytes. The engine stores metadata only.
- `registration` (top-down photo scale calibration): `{"p1":[px,py],"p2":[px,py],"distance_m":4.0}`. Pixel points must differ by at least 10 px; `distance_m` must be in `0.1..=500`.
- `backdrop`: `{"source_id":"src-…","x":0,"y":0,"rotation":0,"opacity":0.6,"meters_per_pixel":null}`. `meters_per_pixel` is derived as `distance_m / pixel_distance` and is non-null only when the source is registered.
- `params` by kind (absent keys take defaults):
  - `fire_pit`: `pit_diameter` 1.07 and `clearance` 3.05. The item footprint is the contained gravel circle; the clearance ring is checked separately.
  - `bin_screen`: `wall_thickness` 0.05. This is an L-shaped, roofless screen with walls along the back (`-y`) and left (`-x`) edges.
  - `plant` and `tree`: `species` (string, optional).
  - `pond`: `water_depth` 0.6.

## Catalog defaults (`catalog` query returns these)

| kind | shape | width × depth × height (m) | size_certainty default |
|---|---|---|---|
| plant | circle | 0.6 × 0.6 × 0.6 | estimated |
| tree | circle | 3.0 × 3.0 × 5.0 | estimated |
| pond | ellipse | 2.4384 × 1.8288 × 0.0 | estimated |
| fire_pit | circle | 4.2672 × 4.2672 × 0.4 | estimated |
| pergola | rect | 3.6068 × 2.9972 × 2.2035 (product preset "Aurora pergola, listed 142 x 118 x 86.75 in", url https://www.wayfair.com/home/pdp/-eevb1318.html) | product_listing |
| sauna | rect | 2.2098 × 2.0066 × 2.2098 (product preset above) | product_listing |
| tool_shed | rect | 1.8288 × 1.2192 × 2.1336 | estimated |
| bin_screen | l_shape | 1.8288 × 0.9144 × 1.3716 | estimated |
| patio | rect | 3.6576 × 3.6576 × 0.05 | estimated |
| raised_bed | rect | 2.4384 × 1.2192 × 0.3 | estimated |
| path | rect | 3.0 × 0.9 × 0.02 | estimated |
| fence | rect | 3.6576 × 0.05 × 1.8288 | estimated |
| privacy_screen | rect | 3.6576 × 0.3 × 1.8288 | estimated |
| structure | rect | 6.0 × 4.0 × 3.0 | estimated |

A catalog entry is `{"kind","label","category","shape","width","depth","height","size_certainty","description","product":null|{...}}`. The categories are `plants`, `water`, `fire`, `structures`, `hardscape` and `screens`.

## Commands (`hgs_engine_command`), tagged by `"op"`

Every successful mutating command creates exactly one undo step labelled as listed. The engine assigns IDs: items `i<n>` and structures `s<n>`, using `next_seq`.

| op | fields | undo label |
|---|---|---|
| `add_item` | `kind`, optional `name`, `x`, `y`, optional `width`/`depth`/`height`/`rotation`/`params`/`product`, optional `traced_from_backdrop` (bool) | `Add <label>` |
| `update_item` | `id`, `patch` {any of `name`,`x`,`y`,`width`,`depth`,`height`,`rotation`,`params`,`notes`,`locked`,`source_ids`,`product`,`size_certainty`} | `Edit <name>` |
| `set_transform` | `id`, `x`,`y`,`width`,`depth`,`rotation` (commit of a drag, resize or rotate) | `Move <name>` / `Resize <name>` / `Rotate <name>` (pick by which fields changed; position wins ties) |
| `move_items` | `ids`, `dx`, `dy` | `Move <n> items` (or `Move <name>` for one) |
| `remove_items` | `ids` | `Delete <n> items` / `Delete <name>` |
| `duplicate_items` | `ids`, `dx`, `dy` | `Duplicate …` |
| `set_boundary` | `outline` (array of ≥3 points, or null), `certainty` | `Set boundary` |
| `add_structure` | `name`, `outline`, `height`, `certainty` | `Add <name>` |
| `update_structure` | `id`, `patch` {`name`,`outline`,`height`,`certainty`} | `Edit <name>` |
| `remove_structure` | `id` | `Delete <name>` |
| `add_source` | `source` (full Source object; `registration` must be null) | `Import <title>` |
| `remove_source` | `id` (also removes it from items' `source_ids` and clears backdrop if used) | `Remove <title>` |
| `register_source` | `id`, `p1`, `p2`, `distance_m` (photo sources only) | `Calibrate <title>` |
| `set_backdrop` | `source_id`, `x`, `y`, `rotation`, `opacity` (or `{"op":"set_backdrop","clear":true}`) | `Set backdrop` / `Clear backdrop` |
| `mark_measured` | `id`, `evidence`: `"field_measurement"` or `"registered_source:<source id>"` | `Mark <name> measured` |
| `set_project_meta` | optional `name`, `units` | `Rename plan` / `Change units` |
| `undo` / `redo` | — | (not recorded) |

Rules:
1. Items locked with `locked: true` reject `set_transform`, `move_items` and geometry patches (`LOCKED`). An unlock patch (`{"locked": false}`) is allowed.
2. `traced_from_backdrop: true` sets `position_certainty` to `unregistered_photo` when the current backdrop source is unregistered, and to `estimated` otherwise.
3. Any move of an item whose `position_certainty` is `measured` downgrades it to `estimated` (a moved item is a proposal).
4. `mark_measured` with `registered_source:<id>` fails `UNREGISTERED_SOURCE` if that source has no registration, and `NOT_FOUND` if it doesn't exist. **An unregistered photo can never establish measured coordinates.**
5. `width`/`depth` changes on `circle` kinds keep them equal (the last provided value wins; `width` if both differ).
6. Mutations validate limits before applying. On error the project is unchanged and no undo step is recorded.
7. History stores whole-project snapshots, capped at 200 undo steps. A new mutation clears the redo stack.

Command response: `{"ok":true,"revision":12,"created":["i8"],"changed":["i8"],"removed":[],"history":{"can_undo":true,"can_redo":false,"undo_label":"Add Sauna","redo_label":null}}`.
Error response: `{"ok":false,"error":{"code":"NOT_FOUND","message":"No item i99"}}`.
Error codes: `INVALID_JSON`, `UNKNOWN_OP`, `NOT_FOUND`, `INVALID_VALUE`, `LOCKED`, `UNREGISTERED_SOURCE`, `SCHEMA_TOO_NEW`, `LIMIT_EXCEEDED`, `NOTHING_TO_UNDO`, `NOTHING_TO_REDO`, `INTERNAL`.

## Queries (`hgs_engine_query`), tagged by `"q"`, never mutate

| q | fields | result (`{"ok":true,"result":…}`) |
|---|---|---|
| `snapshot` | — | full project JSON (same as saved file) |
| `history` | — | `{"revision","can_undo","can_redo","undo_label","redo_label"}` |
| `catalog` | — | array of catalog entries |
| `validate` | — | array of issues |
| `outline` | `id` | footprint polygon `[[x,y],…]` in plan metres (circle and ellipse as a 32-gon, L-shape as 6 points, rect as 4 corners clockwise from top-left) |
| `preview_transform` | `id`, `x`,`y`,`width`,`depth`,`rotation` | `{"outline":[…],"issues":[…]}` for the proposed transform without mutating (the drag hot path; returns only that item's issues) |
| `resize_handle` | `id`, `handle` [sx,sy] each ±1, `point` [x,y], `proportional` bool | `{"x","y","width","depth","rotation"}`. The opposite corner stays fixed. Clamp width and depth to `0.05..=100`, round to 1 mm. With `proportional`, scale both by the larger factor. |
| `rotate_handle` | `id`, `start` [x,y], `point` [x,y], `snap` bool | `{"rotation"}`: the angle delta about the item centre; snap rounds to 15°, otherwise to 1°. |
| `hit_test` | `point` [x,y], `tolerance` | topmost item id or null (reverse draw order) |
| `isometric` | `view_angle` deg | `{"faces":[{"item_id","kind","role":"top"|"left"|"right"|"ground","points":[[sx,sy],…],"depth"}],"bounds":{"min_x","min_y","max_x","max_y"}}`. Faces are sorted back to front. The projection rotates plan points by `view_angle`, then `sx = (x - y) * cos30°`, `sy = (x + y) * sin30° - z`. |
| `scene` | — | `{"primitives":[{"item_id","shape":"box"|"cylinder"|"sphere","center":[x,y,z],"size":[sx,sy,sz],"rotation_y":deg,"material":…}],"ground":{"min":[x,z],"max":[x,z]}}`. Materials: `wood_dark`, `wood_light`, `stone`, `gravel`, `water`, `foliage`, `metal`, `fabric`, `structure`, `fire`. |
| `render_brief` | optional `style` string | `{"prompt":string,"items":[{"id","label","dimensions_text","position_certainty","size_certainty"}],"uncertainties":[string],"layout_hash":hex}` (deterministic; `layout_hash` is FNV-1a 64-bit of the compact snapshot JSON, 16 lowercase hex) |
| `stats` | — | `{"item_count","by_kind":{kind:count},"area_m2_by_kind":{…}}` |

Issue: `{"item_id":"i3"|null,"code":…,"severity":"warning"|"info","message":…}`. Codes:
- `outside_boundary`: the footprint isn't contained in the site boundary. Use even-odd containment, including concave notches.
- `overlaps_structure`: the footprint touches or overlaps a structure outline.
- `overlaps_item`: two footprints overlap with positive area. This is reported once per pair, on the lower id. `plant` overlapping `patio`, `path` or `raised_bed`, and anything inside a `pergola`, is allowed.
- `fire_clearance`: the circle of radius `pit_diameter/2 + clearance` around the fire-pit centre intersects any structure, pergola, sauna, tool shed, fence or privacy screen.
- `unregistered_position` (info): the item's position came from an unregistered photo.
- `no_boundary` (info, `item_id` null): there is no site boundary, so containment wasn't checked.

Messages are plain and never claim survey accuracy: "Not a survey: based on the boundary you drew."

## Persistence

`snapshot` output is the file format: pretty-printed JSON with stable key order (struct field order as above) and the `schema` field. `hgs_engine_open` accepts schema `1`. A newer schema gives `SCHEMA_TOO_NEW`; schema 0 or missing gives `INVALID_VALUE`. Loading re-validates every limit, unique ids, that `source_ids` references exist, and that `backdrop.source_id` exists. `next_seq` must exceed every numeric id suffix (it is repaired upward if not). A round trip (open, then snapshot) is byte-identical for a canonical file.

## C ABI (`core/hgs-ffi/include/hgs.h`)

```c
typedef struct HgsEngine HgsEngine;
const char *hgs_version(void);                          /* static, do not free */
HgsEngine *hgs_engine_new(const char *name_utf8);       /* empty project; NULL name -> "Untitled plan" */
HgsEngine *hgs_engine_open(const char *project_json, char **error_out); /* NULL on failure; *error_out = error JSON (free it) */
void hgs_engine_free(HgsEngine *engine);                /* NULL-safe */
char *hgs_engine_command(HgsEngine *engine, const char *command_json); /* never NULL */
char *hgs_engine_query(HgsEngine *engine, const char *query_json);     /* never NULL */
void hgs_string_free(char *s);                          /* NULL-safe; frees every char* returned above */
```

Every entry point catches panics (`catch_unwind`) and returns an `INTERNAL` error JSON instead of unwinding across FFI. NULL engine or NULL JSON gives `INVALID_VALUE`. The engine isn't thread-safe; the Swift wrapper serialises access on the main actor. The static library is built for `aarch64-apple-darwin`, `x86_64-apple-darwin` (lipo'd universal), `aarch64-apple-ios` and `aarch64-apple-ios-sim`, then packaged as `HgsCore.xcframework` by `scripts/build-core-xcframework.sh`.
