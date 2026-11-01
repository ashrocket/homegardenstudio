# Engine notes

Choices made where `CONTRACT.md` is silent or ambiguous. Each one takes the simplest reading. The contract's own rules win if they conflict with this file.

## Revisions, history, responses

- `revision` starts at 0 and goes up by one on every successful mutation, and on every undo and redo. Failed commands never change it.
- `undo` and `redo` answer with empty `created`, `changed` and `removed` arrays. Callers re-read the snapshot.
- `changed` lists every id the command touched, including the ids in `created`. Ids can be item ids (`i3`), structure ids (`s2`) or source ids (`src-...`).
- Labels: `set_transform` says Move when `x` or `y` changed (or nothing changed), Resize when only width or depth changed, Rotate when only the rotation changed. `set_project_meta` says "Rename plan" when a name is given, otherwise "Change units". `set_boundary` always says "Set boundary", including when it clears the boundary. `Duplicate` uses the item name for one item and `Duplicate <n> items` for more.
- History stores compact JSON snapshots with combined 200-step / 32 MiB bounds. This avoids retaining 200 expanded user-controlled object graphs. The 5000-item test exercises byte eviction with a small number of snapshots.

## Errors

- A number that is outside a limit in the contract gives `LIMIT_EXCEEDED`. A number that isn't finite, a wrong type, an unknown field, a bad reference or an empty patch gives `INVALID_VALUE`. JSON that doesn't parse gives `INVALID_JSON`.
- An unknown `op` and an unknown `q` both give `UNKNOWN_OP`. A missing or non-string `op`/`q` gives `INVALID_VALUE`.
- Commands and queries reject unknown fields, like the loader does.
- Strict checks beyond the listed limits: ids use letters, digits, `-` and `_` (at most 80 characters); names are at most 200 characters and notes 4000; outlines have at most 512 points and a non-zero area; URLs must start with `http://` or `https://`; a source id must be `src-` plus the first 16 hex characters of its lowercase `sha256`; `source_ids` can't repeat. `params` keys must belong to the kind and numbers must be in range (`pit_diameter` 0.1 to 100, `clearance` 0 to 100, `wall_thickness` 0.01 to 5, `water_depth` 0 to 30).
- Loading repairs three things instead of failing: rotations are normalised into `[0, 360)`, `next_seq` is raised above every id number, and `backdrop.meters_per_pixel` is re-derived from the source registration.

## Items

- `add_item`: the name defaults to the catalog label. If no size is given, or it equals the catalog size, the catalog `size_certainty` and the preset product apply. A different size makes `size_certainty` `estimated` and drops the preset. An explicit `product` makes it `product_listing`.
- `update_item`: `params` merges into the existing params and a `null` value removes a key. `product: null` clears the product. Geometry for the lock rule means `x`, `y`, `width`, `depth`, `height`, `rotation` and `params`. An empty patch is `INVALID_VALUE`.
- Position evidence is invalidated by a move, rotation, resize or shape-parameter edit. Size evidence is invalidated by dimensions or shape-parameter edits. Unchanged transforms preserve evidence.
- `mark_measured` defaults to position and accepts field `size` explicitly. It persists field-specific evidence. Source-linked evidence is invalidated by removing, unlinking or recalibrating that source; original source bytes remain the host's responsibility. Two-point calibration is never sufficient measurement evidence.
- `duplicate_items` appends the copies at the end of the draw order, unlocked, with `measured` positions downgraded to `estimated`.
- Resizing automatically downgrades measured/listed size to estimated. Retained product metadata is a reference, not a claim that edited dimensions match the listing. Direct certainty patches cannot fabricate evidence.

## Geometry

- Overlap rules use different predicates on purpose. `overlaps_structure` counts touching (closed sets). `overlaps_item` needs positive area, and pieces thinner than 10 micrometres count as touching. `fire_clearance` fires when the open disc reaches into a blocker, so sitting exactly at the clearance distance is fine.
- Items inside a pergola means the whole footprint of the other item lies inside the pergola footprint. A pergola placed on a patio that extends past it is still reported as an overlap, because the contract lists only plants on patios, paths and raised beds.
- `fire_clearance` blockers: site structures, and items of kind `structure`, `pergola`, `sauna`, `tool_shed`, `fence` and `privacy_screen`. One issue per blocker.
- `preview_transform` reports every overlap on the dragged item, whatever the id order, so the hot path shows conflicts for the item being moved. It fails with `LOCKED` if the item is locked and the proposed transform differs from the current one.
- `rotate_handle` returns the new absolute `rotation` (the item rotation plus the pointer delta, snapped) and also the raw `delta`.
- `resize_handle` returns an unrounded centre. Only width and depth are rounded to a millimetre. Circle kinds always resize proportionally.
- Rect corner order is top-left, top-right, bottom-right, bottom-left, which is clockwise on screen with `+y` down. The bin screen L is `(-w/2,-d/2) (w/2,-d/2) (w/2,-d/2+t) (-w/2+t,-d/2+t) (-w/2+t,d/2) (-w/2,d/2)` rotated about the item centre. Circles and ellipses start at the east point and go clockwise.
- `snapshot` accepts `"text": true` and then returns the canonical file text as a string, so a host can save the exact bytes without re-encoding.

## Isometric view

- The view angle rotates plan points about the plan origin, clockwise, like item rotation. Items are sorted far to near by the rotated centre `x + y`. Within an item, side faces are sorted far to near by edge midpoint, then the top comes last.
- Every face of an item carries the item's rotated `x + y` as its `depth`, so `depth` never decreases down the list.
- A side face is visible when its outward normal has `nx + ny > 0`; `left` when `ny > nx`, otherwise `right`. A face seen exactly edge-on is dropped.
- Items shorter than 0.03 m give one `ground` face. The catalog patio is 0.05 m tall, so it draws as a box. Make a ground-level patio with `height` 0.02.
- Site structures are drawn too, as faces whose `item_id` is the structure id and whose `kind` is `structure`.

## Scene primitives

Order: site structures first, then items in project order. Sizes are `[x, y, z]` in 3D axes (plan width, height, plan depth). Part offsets rotate about the item centre.

| kind | primitives |
|---|---|
| plant | sphere `foliage`, size `[w, h, d]`, centre y `h/2` |
| tree | cylinder `wood_dark` trunk, size `[0.3, 0.4h, 0.3]`, centre y `0.2h`; sphere `foliage`, size `[w, 0.6h, d]`, centre y `0.7h` |
| pond | cylinder `water`, size `[w, 0.02, d]`, centre y 0.01 |
| fire_pit | cylinder `gravel` size `[w, 0.02, d]` centre y 0.01; cylinder `stone` size `[pit, 0.4, pit]` centre y 0.2; cylinder `fire` size `[0.5 pit, 0.3, 0.5 pit]` centre y 0.55 |
| pergola | 4 posts `wood_dark`, up to 0.15 square, local corners inset half post thickness, height `max(h-0.2, 0)`; 2 beams `wood_dark`, size `[w, 0.15, 0.15]`, at the front and back edges, centre y `h-0.125`; 8 slats `wood_light`, size `[0.06, 0.05, d]`, centre y `h-0.025`, spread evenly across the width |
| bin_screen | back wall box `wood_light` size `[w, h, t]` along the `-y` edge; left wall box size `[t, h, d-t]` along the `-x` edge, below the back wall |
| sauna | box `wood_dark` |
| tool_shed, raised_bed, fence, privacy_screen | box `wood_light` |
| patio | box `stone` |
| path | box `gravel` |
| structure (item) | box `structure` |
| site structure | box `structure` over the outline's bounding box, `item_id` = structure id, height from the structure |

Boxes use size `[w, h, d]` and centre y `h/2`. `rotation_y` is `-rotation` for every part. Ground is the bounding box of every footprint, structure outline and the boundary, grown by 2 m on each side. An empty plan gives `[-2,-2]` to `[2,2]`. All numbers go through `geometry::clean`.

## Render brief

- `items[]` has one entry per item, in project order. `label` is the item name. `dimensions_text` is `W m x D m x H m (W ft I in x D ft I in x H ft I in)`, metres to 2 decimals, inches rounded to the nearest whole inch with carry (so 11.6 in is the next foot).
- Position words come from the item centre inside a reference box: the site boundary box if there is one, otherwise the box around all items and structures. Each axis is split into thirds: north/centre/south (smaller `y` is north) and west/centre/east. Both centred reads "the centre of the plan"; otherwise "the north-east part of the plan", "the west part of the plan" and so on. A box with no extent on an axis counts as centred on it.
- Certainty words: position `measured` is "measured position", `estimated` is "estimated position", `unregistered_photo` is "position traced from an unscaled photo". Size `measured` is "measured size", `estimated` is "estimated size", `product_listing` is "size from the product listing".
- The prompt is plain English. It opens with the task and explicit layout-preservation/uncertainty rules, then optional style, plan name, coordinate convention, site geometry and numbered items with exact placement/dimensions/rotation. It includes source context and closes with uncertainty sentences. User text is descriptive data, not a permission grant for provider actions.
- `uncertainties` lists, in order: `No site boundary was drawn.` or `The site boundary is estimated.`; each structure that isn't measured (`<name>: outline is estimated.`); then per item `<name>: position is estimated.` / `<name>: position was traced from an unscaled photo and is approximate.` and `<name>: size is estimated.` / `<name>: size comes from the product listing.` Measured things add nothing.
- `layout_hash` is FNV-1a 64 over the compact snapshot JSON bytes, as 16 lowercase hex characters. The style doesn't change it.

## Verification

`CARGO_BUILD_JOBS=1 cargo test --workspace --all-targets` exercises field evidence, source invalidation, import tampering and limits, redo preservation, history byte eviction, native scenes, rendering/layout hashing, geometry/handles, layout conflicts, persistence and C ABI ownership/error paths. `cargo clippy --workspace --all-targets -- -D warnings` and `cargo fmt --all --check` are required. The native host must still verify visual interaction and RealityKit rendering separately.
