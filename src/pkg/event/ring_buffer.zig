//! RingBuffer - Generic circular buffer with overwrite behavior
//!
//! A fixed-size circular buffer that overwrites oldest elements when full.
//! Zero heap allocation - all storage is inline.
//!
//! ## Usage
//!
//! ```zig
//! var buf = RingBuffer(u32, 4).init();
//!
//! buf.push(1);
//! buf.push(2);
//! buf.push(3);
//!
//! // Iterate from oldest to newest
//! var iter = buf.iterator();
//! while (iter.next()) |val| {
//!     std.debug.print("{} ", .{val.*});
//! }
//! // Output: 1 2 3
//!
//! // Access by index
//! buf.get(0)  // oldest: 1
//! buf.getLast()  // newest: 3
//!
//! // Overwrite when full
//! buf.push(4);
//! buf.push(5);  // overwrites 1
//! // Now contains: 2 3 4 5
//! ```

const std = @import("std");

/// Generic ring buffer with fixed capacity
pub fn RingBuffer(comptime T: type, comptime capacity: comptime_int) type {
    if (capacity == 0) {
        @compileError("RingBuffer capacity must be > 0");
    }

    return struct {
        const Self = @This();
        pub const Capacity = capacity;

        /// Storage for elements
        items: [capacity]T = undefined,

        /// Index of the oldest element (next to be overwritten)
        head: usize = 0,

        /// Number of elements currently in the buffer
        len: usize = 0,

        /// Initialize an empty ring buffer
        pub fn init() Self {
            return .{};
        }

        /// Initialize with a fill value
        pub fn initFill(value: T) Self {
            var self = Self{};
            for (&self.items) |*item| {
                item.* = value;
            }
            return self;
        }

        /// Push an element, overwriting oldest if full
        /// Returns pointer to the pushed element
        pub fn push(self: *Self, value: T) *T {
            const idx = (self.head + self.len) % capacity;

            if (self.len < capacity) {
                self.len += 1;
            } else {
                // Buffer full, advance head (overwrite oldest)
                self.head = (self.head + 1) % capacity;
            }

            self.items[idx] = value;
            return &self.items[idx];
        }

        /// Push and return whether an element was overwritten
        pub fn pushOverwrite(self: *Self, value: T) struct { ptr: *T, overwritten: bool } {
            const was_full = self.len >= capacity;
            const ptr = self.push(value);
            return .{ .ptr = ptr, .overwritten = was_full };
        }

        /// Get element by index (0 = oldest, len-1 = newest)
        /// Returns null if index out of bounds
        pub fn get(self: *Self, index: usize) ?*T {
            if (index >= self.len) return null;
            const actual_idx = (self.head + index) % capacity;
            return &self.items[actual_idx];
        }

        /// Get element by index (const version)
        pub fn getConst(self: *const Self, index: usize) ?*const T {
            if (index >= self.len) return null;
            const actual_idx = (self.head + index) % capacity;
            return &self.items[actual_idx];
        }

        /// Get element by reverse index (0 = newest, len-1 = oldest)
        pub fn getReverse(self: *Self, index: usize) ?*T {
            if (index >= self.len) return null;
            const actual_idx = (self.head + self.len - 1 - index) % capacity;
            return &self.items[actual_idx];
        }

        /// Get element by reverse index (const version)
        pub fn getReverseConst(self: *const Self, index: usize) ?*const T {
            if (index >= self.len) return null;
            const actual_idx = (self.head + self.len - 1 - index) % capacity;
            return &self.items[actual_idx];
        }

        /// Get the oldest element
        pub fn getFirst(self: *Self) ?*T {
            return self.get(0);
        }

        /// Get the newest element
        pub fn getLast(self: *Self) ?*T {
            if (self.len == 0) return null;
            return self.get(self.len - 1);
        }

        /// Get the newest element (const version)
        pub fn getLastConst(self: *const Self) ?*const T {
            if (self.len == 0) return null;
            return self.getConst(self.len - 1);
        }

        /// Check if buffer is empty
        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }

        /// Check if buffer is full
        pub fn isFull(self: *const Self) bool {
            return self.len >= capacity;
        }

        /// Clear all elements
        pub fn clear(self: *Self) void {
            self.head = 0;
            self.len = 0;
        }

        /// Get current number of elements
        pub fn count(self: *const Self) usize {
            return self.len;
        }

        /// Iterator for traversing elements (oldest to newest)
        pub const Iterator = struct {
            buf: *Self,
            index: usize,

            pub fn next(self: *Iterator) ?*T {
                if (self.index >= self.buf.len) return null;
                const result = self.buf.get(self.index);
                self.index += 1;
                return result;
            }
        };

        /// Const iterator
        pub const ConstIterator = struct {
            buf: *const Self,
            index: usize,

            pub fn next(self: *ConstIterator) ?*const T {
                if (self.index >= self.buf.len) return null;
                const result = self.buf.getConst(self.index);
                self.index += 1;
                return result;
            }
        };

        /// Get an iterator (oldest to newest)
        pub fn iterator(self: *Self) Iterator {
            return .{ .buf = self, .index = 0 };
        }

        /// Get a const iterator (oldest to newest)
        pub fn constIterator(self: *const Self) ConstIterator {
            return .{ .buf = self, .index = 0 };
        }

        /// Convert to slice (only valid if buffer hasn't wrapped)
        /// Returns null if buffer has wrapped around
        pub fn asSlice(self: *Self) ?[]T {
            if (self.head == 0) {
                return self.items[0..self.len];
            }
            return null;
        }
    };
}
