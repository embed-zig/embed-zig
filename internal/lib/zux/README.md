# lib/zux - Snapshot-driven state runtime for embed-zig

`zux` is a small Flux-style state runtime for `embed-zig`.

It is not a React-specific library and it is not a UI framework. The
goal is to provide a deterministic event -> reducer -> state pipeline
with:

- explicit event dispatch
- reducer-based state updates
- per-tick read-only snapshots
- dirty tracking
- prefix-based subscriptions
- adapter VTables for external inputs

The intended use case is application state that needs stable reads,
incremental updates, and backend-agnostic integration with timers,
networking, Bluetooth, UI callbacks, or other event sources.

This package is currently design-first. The API described here is the
target direction and may still change as the implementation lands.

## Table of Contents

- [Design goals](#design-goals)
- [Core model](#core-model)
- [State layout](#state-layout)
- [Dirty tracking and subscriptions](#dirty-tracking-and-subscriptions)
- [Inputs and reducers](#inputs-and-reducers)
- [Tick lifecycle](#tick-lifecycle)
- [Package structure](#package-structure)
- [Naming](#naming)

## Design goals

1. Deterministic state transitions. External inputs are converted into
   events, events are reduced in order, and state becomes visible only at
   tick commit boundaries.

2. Stable reads. Readers always observe a single read-only snapshot for
   the duration of a tick. No reader should ever see half-applied state.

3. Incremental notification. State changes should not force a global
   rerender. Subscribers are notified only when one of their watched
   prefixes becomes dirty.

4. Backend-agnostic integration. External systems push events through
   callback VTables or expose derived read-only state through state input
   VTables.

5. Simple mental model. Reducers read from the last committed snapshot
   and write only into the current working state.

## Core model

`zux` is centered around three state views:

- `snapshot_ro` - the current committed read-only snapshot visible to
  readers
- `working_rw` - the mutable working state for the current tick
- `dirty_set` - the set of paths or prefixes modified during the tick

The rules are:

- readers only read `snapshot_ro`
- reducers only write `working_rw`
- events are processed in order
- visibility changes only happen at `commit`
- subscriptions are matched against the final dirty set

This gives `zux` a model closer to snapshot isolation plus Flux-style
event reduction than to immediate-mode reactive mutation.

## State layout

State is intended to be organized by path-like prefixes:

```text
ui/theme/mode
session/user/id
session/user/name
bt/device/001/rssi
```

This naming scheme gives the runtime a simple and uniform way to:

- store state
- mark regions dirty
- match subscriptions
- partition the state tree later if needed

The runtime should present each tick as a full read-only snapshot, but
the implementation does not need to deep-copy the whole tree every time.
The preferred direction is copy-on-write or shard-level replacement so
the public model stays simple while the implementation remains efficient.

## Dirty tracking and subscriptions

Dirty tracking is path-based, not frame-based.

If a reducer updates:

```text
session/user/name
```

then the dirty set should include both the exact path and its parent
prefixes:

```text
session/user/name
session/user/
session/
/
```

This allows a subscriber to watch a narrow path or a broad subtree.

Two subscription modes are expected:

- exact subscription to one path
- prefix subscription to a subtree such as `session/` or `ui/`

At commit time, the runtime should:

1. freeze `working_rw` into a new snapshot
2. collect all affected subscriptions from the dirty set
3. deduplicate subscribers
4. notify them that a newer snapshot generation is available

Subscribers should generally re-read the new snapshot instead of relying
on copied payloads from the notification itself.

## Inputs and reducers

`zux` separates event production from state mutation.

### Event bus

The event bus owns queued events and dispatch order. It does not own
application state.

Responsibilities:

- accept published events
- preserve deterministic ordering
- drain events during a tick
- allow reducers to emit follow-up events without recursive reentry

### Reducer registry

Reducers are registered by event kind and are responsible for updating
the working state.

Expected reducer properties:

- may read the current committed snapshot
- may write only to the working state
- may emit new events
- may mark dirty paths
- should avoid direct external side effects

### Callback input VTable

Callback inputs are push-based adapters for external systems.

Examples:

- UI callbacks
- timer interrupts
- socket readiness callbacks
- Bluetooth notifications

Their job is to translate outside activity into `zux` events.

### State input VTable

State inputs are pull-based read-only adapters.

They are useful for:

- exposing derived read-only state
- projecting state into another subsystem
- providing typed reads over path-based storage

## Tick lifecycle

The expected runtime flow for one tick is:

1. external inputs publish events into the bus
2. the runtime begins a tick
3. queued events are drained in order
4. matching reducers run against `working_rw`
5. reducers record dirty paths and may emit more events
6. when the queue is stable, the runtime commits
7. a new `snapshot_ro` becomes visible
8. prefix and exact subscriptions are matched
9. subscribers are notified once per tick

This ensures that observers never see a partially updated state graph.

## Package structure

The likely package shape is:

```text
lib/zux.zig
lib/zux/
  README.md
  Event.zig
  Bus.zig
  Reducer.zig
  Registry.zig
  store.zig
  Snapshot.zig
  DirtySet.zig
  Subscription.zig
  Runtime.zig
  StoreObject.zig
  input/
    Callback.zig
    State.zig
```

Suggested responsibilities:

- `Event.zig` - event definitions and tags
- `Bus.zig` - queueing and dispatch order
- `Reducer.zig` - reducer function contracts
- `Registry.zig` - event-to-reducer registration
- `store.zig` - store namespace and Builder-based store construction surface
- `Snapshot.zig` - read-only committed view
- `DirtySet.zig` - path and prefix dirtiness tracking
- `Subscription.zig` - exact and prefix subscriptions
- `Runtime.zig` - tick orchestration
- `input/Callback.zig` - push adapters
- `input/State.zig` - pull adapters

## Current Board Spec

The staged integration fixtures currently model board specs as tagged entries:

```json
{
  "kind": "Component/ui/flow",
  "spec": {
    "label": "pairing",
    "id": 61,
    "flow": {
      "initial": "idle",
      "nodes": ["idle", "searching", "confirming", "done"],
      "edges": [
        { "from": "idle", "to": "searching", "event": "start" }
      ]
    }
  }
}
```

For `Component/ui/flow`, the `spec` object now carries a nested `flow` object.
That `flow` object requires `initial`, `nodes`, and `edges`; `initial` must name
one of the declared nodes, and every edge `from` / `to` must reference a known
node.

## Naming

The name `zux` is intentionally short and project-specific.

It signals:

- a Zig-oriented module
- a reducer-driven state system
- a Flux/Redux-style lineage without depending on React

The internal type names should still stay plain and descriptive:

- `Event`
- `Bus`
- `Reducer`
- `Store`
- `Snapshot`
- `DirtySet`
- `Subscription`
- `Runtime`
