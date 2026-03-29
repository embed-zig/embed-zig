# pkg/lvgl — LVGL binding notes

This document describes the intended layering for `pkg/lvgl`.
It is not a full API reference yet. The goal is to capture how
LVGL is structured upstream, and how the Zig binding should mirror
that structure without collapsing everything into one flat wrapper.

## Current status

Today `pkg/lvgl` is past the bootstrap stage.

Implemented so far:

- LVGL `v9.5.0` sources are built by `build/pkg/lvgl.zig`
- config is handled via generated or user-provided `lv_conf.h`
- raw binding layer exists in `src/binding.c` and `src/binding.zig`
- base value layer exists for color/point/area/style/types
- core runtime layer has the first usable slice:
  - `src/Display.zig`
  - `src/Event.zig`
  - `src/Anim.zig`
  - `src/Subject.zig`
  - `src/Observer.zig`
- object layer has the first usable slice:
  - `src/object/Obj.zig`
  - `src/object/Tree.zig`
  - `src/object/Flags.zig`
  - `src/object/State.zig`
- widget layer has the first usable tranche:
  - `src/widget/Label.zig`
  - `src/widget/Button.zig`
- isolated `pkg/lvgl` tests cover the currently implemented layers

Not implemented yet:

- the rest of the object submodules (`Class`, `Scroll`, `Property`)
- broader widget layer beyond the first tranche
- broader input/layout/theme/draw wrappers
- optional integrations and drivers

So the package is no longer "binding only". It now has a real base,
runtime, object, and first-widget slice, and is ready to move into the
next object-expansion phase.

## How LVGL is layered upstream

From LVGL's `src/` tree in `v9.5.0`, the main subsystems are:

- `core/`
- `display/`
- `indev/`
- `draw/`
- `font/`
- `widgets/`
- `layouts/`
- `themes/`
- `misc/`
- `tick/`
- `osal/`
- `drivers/`
- `libs/`
- `debugging/`
- `others/`

This means LVGL is not "just widgets". Widgets sit on top of a
deeper object system plus display, input, draw, style, timer,
event, observer, and configuration layers.

## Important LVGL concepts

### Object system

The center of LVGL is `lv_obj_t`, but `lv_obj_t` itself is not enough
to represent the whole "object layer".

Upstream object behavior is split across multiple pieces, such as:

- object tree
- position and size
- scrolling
- style attachment
- draw participation
- object classes
- object events
- object properties
- group/focus behavior

So a Zig `object/` layer should not be a single flat `Obj.zig` plus
"everything else in widgets". The object layer needs its own internal
sub-structure.

### Widgets

Widgets are built on top of the object system. For example:

- `Label`
- `Button`
- `Image`
- `Slider`
- `Roller`
- `Table`

These should usually wrap an object handle and expose widget-specific
operations, instead of re-implementing the generic object API.

### Events

LVGL has a dedicated event system (`lv_event_t`, `lv_event_cb_t`,
event codes like `LV_EVENT_CLICKED`, `LV_EVENT_VALUE_CHANGED`, etc).

This is a real layer of its own, not just a helper on widgets.
In Zig it should be modeled separately from the widget wrappers,
because event callback registration, callback trampolines, event data,
and lifetime rules need careful handling.

### Animation

LVGL animation is also a subsystem of its own (`lv_anim_t`,
timelines, easing helpers, playback/repeat controls).

This should not be mixed into widget wrappers directly. Widgets may
consume animation APIs, but the animation model itself should live
in its own layer.

### Observer / Subject

LVGL has an observer/reactive subsystem (`lv_subject_t`,
`lv_observer_t`) that is independent from widgets. It is closer to a
data binding layer than to a widget layer.

This means `subject` should not be treated as "just another widget".
It should be modeled as a separate reactive layer that widgets may
subscribe to.

### Display / Input / Draw

There are also distinct runtime layers around rendering and input:

- display
- input device
- draw buffer / draw pipeline
- tick / timer
- themes
- layouts

These are foundational layers and should come before higher-level
widget wrappers.

## Proposed Zig layering

The Zig package should be layered roughly like this.

### 1. Raw binding layer

Files:

- `src/binding.c`
- `src/binding.zig`

Responsibilities:

- include `lvgl.h`
- compile the C side
- explicitly export only the C symbols we need
- keep the raw `@cImport` private once the binding grows

Other Zig files should depend on `binding.zig`, not on a raw `c`
namespace directly.

### 2. Base type layer

Files here are plain values, enums, and simple structs that are not
best modeled as heavyweight objects.

Examples:

- `src/types.zig`
- `src/Color.zig`
- `src/Point.zig`
- `src/Area.zig`
- `src/Style.zig`
- `src/Timer.zig`
- `src/Tick.zig`

Rule:

- if it is a real public type with behavior, it can get its own file
- if it is mostly enums/flags/plain structs, keep it in `types.zig`

### 3. Core runtime layer

This is the layer that models LVGL's foundational runtime pieces.

Examples:

- `src/Display.zig`
- `src/Indev.zig`
- `src/Group.zig`
- `src/Event.zig`
- `src/Subject.zig`
- `src/Observer.zig`
- `src/Anim.zig`
- `src/AnimTimeline.zig`

This layer should be usable before importing any concrete widget.

### 4. Object layer

This should be more than a single file.

Possible layout:

- `src/object/Obj.zig`
- `src/object/Class.zig`
- `src/object/Flags.zig`
- `src/object/State.zig`
- `src/object/Tree.zig`
- `src/object/Scroll.zig`
- `src/object/Property.zig`

`Obj.zig` should expose the common object-facing API:

- create
- delete
- parent/child traversal
- size/position
- flags/state
- style attach/detach
- event registration

But the supporting concepts should stay split instead of forcing all
object-related code into one file.

### 5. Widget layer

Widgets should live under their own namespace, for example:

- `src/widget/Label.zig`
- `src/widget/Button.zig`
- `src/widget/Image.zig`
- `src/widget/Slider.zig`
- `src/widget/Textarea.zig`

These should compose the object layer instead of bypassing it.

In practice many widgets can store an object handle and expose:

- widget-specific constructors
- widget-specific setters/getters
- `asObj()` or equivalent access to the base object

### 6. Optional integration layer

LVGL also ships optional libraries and integrations:

- image decoders
- FreeType
- SVG
- ffmpeg
- file explorer
- translation
- debugging helpers

These should not be mixed into the base package surface too early.
They are better added after the core object/display/widget layers
are stable.

## Layers vs phases

The layers above describe architecture.

However, implementation should not proceed by fully completing every
possible file in one layer before touching the next one. That would
lead to a lot of speculative API design.

Instead, development should move in phases:

- each phase leaves behind a small but stable slice
- each later phase pressure-tests the previous layer
- widgets should drive the expansion of the object layer, not the other
  way around

In practice this means:

- keep the architectural layers as separate namespaces
- but execute them in incremental phases
- prefer "minimum complete slice + tests" over "full theoretical layer"

## Proposed development phases

### Phase 1. Build and binding bootstrap

Goal:

- fetch/build LVGL
- provide `binding.c` and `binding.zig`
- establish config-header support

Deliverables:

- `build/pkg/lvgl.zig`
- `pkg/lvgl/config.h.in`
- `src/binding.c`
- `src/binding.zig`

### Phase 2. Base values and simple structs

Goal:

- wrap plain values and utility structs first

Deliverables:

- `src/types.zig`
- `src/Color.zig`
- `src/Point.zig`
- `src/Area.zig`
- `src/Style.zig`

### Phase 3. Core runtime slice

Goal:

- expose LVGL runtime pieces that are useful before widgets exist

Deliverables:

- `src/Display.zig`
- `src/Event.zig`
- `src/Anim.zig`
- `src/Subject.zig`
- `src/Observer.zig`

### Phase 4. Minimum object layer

Goal:

- create the smallest object layer that is real enough for widgets to
  compose on top of it

Deliverables:

- `src/object/Obj.zig`
- `src/object/Tree.zig`
- `src/object/Flags.zig`
- `src/object/State.zig`

Required behavior:

- create/delete
- parent/child traversal
- size/position
- flags/state
- style attach/detach
- raw event registration

This phase should stop once the object layer is usable, not once every
possible object-related wrapper is implemented.

### Phase 5. First widget tranche

Goal:

- pressure-test the object layer with real widgets

Suggested order:

- `src/widget/Label.zig`
- `src/widget/Button.zig`

Rules:

- widgets should compose `Obj`
- widgets should expose `asObj()` or equivalent
- widget tests should validate that object-layer boundaries feel right

This phase is complete once `Label` and `Button` exist as real widget
wrappers and their tests validate that the object layer composes well.

### Phase 6. Object layer expansion

Goal:

- fill in the remaining object submodules based on real widget pressure

Likely files:

- `src/object/Class.zig`
- `src/object/Scroll.zig`
- `src/object/Property.zig`

This is intentionally after the first widgets, so these wrappers are
shaped by actual needs instead of guesswork.

### Phase 7. Broader widget layer

Goal:

- add more concrete widgets once the first widget tranche has validated
  the object design

Examples:

- `Image`
- `Slider`
- `Textarea`
- `Roller`

### Phase 8. Optional integrations and drivers

Goal:

- add LVGL optional libs and platform-specific integrations only after
  the base package surface is stable

Examples:

- image/font/libs integrations
- OS integration
- drivers
- debugging helpers

## Why not put everything in one `object/` directory?

Because LVGL's "object" concept already spans multiple subsystems:

- tree
- geometry
- scrolling
- properties
- events
- styles
- drawing hooks
- class metadata

If Zig mirrors LVGL too loosely, the package becomes a giant bag of
methods on `Obj` and loses the structure that exists upstream.

So the right model is:

- one object layer
- but the object layer itself is internally split

This is different from the widget layer, and also different from the
observer/event/animation layers.

## Configuration model

LVGL is heavily configured at compile time.

The main configuration entry point is `lv_conf.h`.

The inclusion logic is controlled by `lv_conf_internal.h`, which:

- checks for `lv_conf.h`
- supports `LV_CONF_PATH`
- supports `LV_CONF_INCLUDE_SIMPLE`
- falls back to `../../lv_conf.h`
- or uses internal defaults when `LV_CONF_SKIP=1`

In other words: yes, LVGL is designed to be overridden by a config
header.

### What `lv_conf.h` controls

A non-exhaustive list:

- OS integration
- stdlib backend
- memory pool settings
- color depth
- draw backends
- fonts
- widgets and optional features
- observer support
- float support
- image/font/lib integrations
- debugging and profiling

Examples visible in `lv_conf_internal.h`:

- `LV_OS_NONE`
- `LV_OS_PTHREAD`
- `LV_OS_FREERTOS`
- `LV_OS_WINDOWS`
- `LV_USE_STDLIB_MALLOC`
- `LV_USE_STDLIB_STRING`
- `LV_COLOR_DEPTH`

So the Zig package should treat configuration as a first-class build
concern, not as an afterthought.

## Proposed config strategy for this repo

Short term:

- keep the curated `lv_conf.h` generation model
- keep the supported config surface explicit
- get the binding and basic Zig layers compiling first

Medium term:

- expose a curated set of build options in `build/pkg/lvgl.zig`
- generate or provide a controlled `lv_conf.h`
- avoid forcing users to hand-edit upstream LVGL headers

Examples of good future build options:

- color depth
- OS backend
- stdlib backend
- float support
- observer enable/disable
- selected optional libs

The important rule is the same as in the other packages:

- do not expose every upstream macro immediately
- expose an explicit supported set
- validate unsupported options early

## Recommended next step

The current package is at the end of Phase 5.

So the next recommended work is:

1. start Phase 6
2. implement `src/object/Class.zig`
3. implement `src/object/Scroll.zig`
4. implement `src/object/Property.zig`
5. let real widget use continue to refine these wrappers

After that, continue with Phase 7 and broaden the widget surface.
