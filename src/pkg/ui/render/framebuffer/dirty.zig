//! Dirty Rectangle Tracker
//!
//! Tracks rectangular regions that need to be flushed to the display.
//! Each drawing operation marks a dirty rect. At flush time, the
//! accumulated rects are used for partial display updates.
//!
//! When the tracker is full, existing rects are merged into a
//! bounding box to make room. This degrades gracefully — worst
//! case is a full-screen flush.

/// Axis-aligned rectangle.
pub const Rect = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,

    /// Check if two rectangles overlap.
    pub fn intersects(self: Rect, other: Rect) bool {
        if (self.w == 0 or self.h == 0 or other.w == 0 or other.h == 0) return false;
        const a_right = self.x + self.w;
        const a_bottom = self.y + self.h;
        const b_right = other.x + other.w;
        const b_bottom = other.y + other.h;
        return self.x < b_right and other.x < a_right and
            self.y < b_bottom and other.y < a_bottom;
    }

    /// Return the bounding box that contains both rectangles.
    pub fn merge(self: Rect, other: Rect) Rect {
        if (self.w == 0 or self.h == 0) return other;
        if (other.w == 0 or other.h == 0) return self;

        const min_x = @min(self.x, other.x);
        const min_y = @min(self.y, other.y);
        const max_x = @max(self.x + self.w, other.x + other.w);
        const max_y = @max(self.y + self.h, other.y + other.h);
        return .{
            .x = min_x,
            .y = min_y,
            .w = max_x - min_x,
            .h = max_y - min_y,
        };
    }

    /// Area in pixels.
    pub fn area(self: Rect) u32 {
        return @as(u32, self.w) * @as(u32, self.h);
    }

    pub fn eql(self: Rect, other: Rect) bool {
        return self.x == other.x and self.y == other.y and
            self.w == other.w and self.h == other.h;
    }
};

/// Tracks up to `MAX` dirty rectangles.
///
/// When full, merges all existing rects into one bounding box
/// to make room. This ensures mark() never fails.
pub fn DirtyTracker(comptime MAX: u8) type {
    return struct {
        const Self = @This();

        rects: [MAX]Rect = undefined,
        count: u8 = 0,

        pub fn init() Self {
            return .{};
        }

        /// Mark a rectangular region as dirty.
        ///
        /// If the tracker is full, all existing rects are merged
        /// into a single bounding box first.
        pub fn mark(self: *Self, rect: Rect) void {
            if (rect.w == 0 or rect.h == 0) return;

            for (self.rects[0..self.count]) |*existing| {
                if (existing.intersects(rect)) {
                    existing.* = existing.merge(rect);
                    return;
                }
            }

            if (self.count >= MAX) {
                self.collapse();
                if (self.count >= MAX) {
                    self.rects[0] = self.rects[0].merge(rect);
                    return;
                }
            }

            self.rects[self.count] = rect;
            self.count += 1;
        }

        /// Mark the entire screen as dirty.
        pub fn markAll(self: *Self, w: u16, h: u16) void {
            self.count = 1;
            self.rects[0] = .{ .x = 0, .y = 0, .w = w, .h = h };
        }

        /// Get the current dirty regions.
        pub fn get(self: *const Self) []const Rect {
            return self.rects[0..self.count];
        }

        /// Clear all dirty regions (call after display flush).
        pub fn clear(self: *Self) void {
            self.count = 0;
        }

        /// Check if any region is dirty.
        pub fn isDirty(self: *const Self) bool {
            return self.count > 0;
        }

        fn collapse(self: *Self) void {
            if (self.count <= 1) return;
            var merged = self.rects[0];
            for (self.rects[1..self.count]) |r| {
                merged = merged.merge(r);
            }
            self.rects[0] = merged;
            self.count = 1;
        }
    };
}
