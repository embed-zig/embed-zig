//! Compositor — Component-Based Partial Rendering
//!
//! Each component is a self-contained Zig struct that declares:
//!   - bounds(state) → Rect    — where am I? (can depend on state for sprites)
//!   - changed(state, prev) → bool — did my data change?
//!   - draw(fb, state) → void  — render myself
//!
//! The Compositor iterates components, skips unchanged ones, and only
//! redraws what actually changed. Moving sprites are handled automatically:
//! the old position is cleared before drawing at the new position.
//!
//! ## Known Limitation: Overlapping Components
//!
//! The Compositor has no Z-ordering. When a component is redrawn, its old
//! position is cleared with `bg` color, which may overwrite pixels from
//! other components that overlap that area. To avoid artifacts:
//!   - Order components bottom-to-top (background first, foreground last)
//!   - Use the component's `bg` color matching the layer beneath it
//!   - Avoid large background fills inside draw(); let `bg` handle clearing

const Rect = @import("dirty.zig").Rect;

/// Compositor: renders a set of component types with partial redraw.
///
/// `Fb` — Framebuffer type (e.g., `Framebuffer(240, 240, .rgb565)`)
/// `State` — App state struct
/// `components` — tuple of component types, each providing:
///   - `pub fn bounds(*const State) Rect`
///   - `pub fn changed(*const State, *const State) bool`
///   - `pub fn draw(*Fb, *const State) void`
///   - `const bg: u16` (optional, default 0x0000)
pub fn Compositor(comptime Fb: type, comptime State: type, comptime components: anytype) type {
    return struct {
        /// Render the scene. Only components where state changed get redrawn.
        ///
        /// For moving components (bounds depends on state), the old position
        /// is automatically cleared before drawing at the new position.
        ///
        /// `first_frame`: if true, draw all components (initial render).
        /// Returns number of components redrawn.
        pub fn render(fb: *Fb, state: *const State, prev: *const State, first_frame: bool) u8 {
            var redrawn: u8 = 0;
            inline for (components) |C| {
                if (first_frame or C.changed(state, prev)) {
                    const bg = if (@hasDecl(C, "bg")) C.bg else 0x0000;
                    const old_rect = C.bounds(prev);
                    const new_rect = C.bounds(state);

                    fb.fillRect(old_rect.x, old_rect.y, old_rect.w, old_rect.h, bg);

                    if (!old_rect.eql(new_rect)) {
                        fb.fillRect(new_rect.x, new_rect.y, new_rect.w, new_rect.h, bg);
                    }

                    C.draw(fb, state);
                    redrawn += 1;
                }
            }
            return redrawn;
        }

        pub fn count() usize {
            return components.len;
        }
    };
}

pub fn Region(comptime State: type) type {
    return struct {
        rect: Rect,
        changed: *const fn (current: *const State, prev: *const State) bool,
        draw: *const fn (fb: *anyopaque, state: *const State, bounds: Rect) void,
        clear_color: ?u16 = 0x0000,
    };
}

pub fn SceneRenderer(comptime Fb: type, comptime State: type, comptime regions: []const Region(State)) type {
    return struct {
        pub fn render(fb: *Fb, state: *const State, prev: *const State, first_frame: bool) u8 {
            var redrawn: u8 = 0;
            inline for (regions) |region| {
                if (first_frame or region.changed(state, prev)) {
                    if (region.clear_color) |bg| {
                        fb.fillRect(region.rect.x, region.rect.y, region.rect.w, region.rect.h, bg);
                    }
                    region.draw(@ptrCast(fb), state, region.rect);
                    redrawn += 1;
                }
            }
            return redrawn;
        }

        pub fn regionCount() usize {
            return regions.len;
        }

        pub fn maxDirtyBytes(comptime bpp_val: u32) u32 {
            var total: u32 = 0;
            for (regions) |region| {
                total += region.rect.area() * bpp_val;
            }
            return total;
        }

        pub fn dirtyBytes(changed_mask: u32, comptime bpp_val: u32) u32 {
            var total: u32 = 0;
            inline for (regions, 0..) |region, i| {
                if (changed_mask & (@as(u32, 1) << @intCast(i)) != 0) {
                    total += region.rect.area() * bpp_val;
                }
            }
            return total;
        }
    };
}
