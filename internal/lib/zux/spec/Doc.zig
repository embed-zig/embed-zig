const ComponentSpec = @import("Component.zig");
const ReducerSpec = @import("Reducer.zig");
const RenderSpec = @import("Render.zig");
const StatePathSpec = @import("StatePath.zig");
const UserStorySpec = @import("UserStory.zig");

const Doc = @This();
const StoreObjectSpec = type;

stores: []const StoreObjectSpec = &.{},
state_paths: []const StatePathSpec = &.{},
components: []const ComponentSpec = &.{},
reducers: []const ReducerSpec = &.{},
renders: []const RenderSpec = &.{},
user_stories: []const UserStorySpec = &.{},

pub fn addParsed(self: *Doc, comptime parsed: anytype) void {
    switch (parsed) {
        .store => |store_spec| {
            self.stores = appendOne(StoreObjectSpec, self.stores, store_spec);
        },
        .state_path => |state_path| {
            self.state_paths = appendOne(StatePathSpec, self.state_paths, state_path);
        },
        .component => |component| {
            self.components = appendOne(ComponentSpec, self.components, component);
        },
        .reducer => |reducer| {
            self.reducers = appendOne(ReducerSpec, self.reducers, reducer);
        },
        .render => |render| {
            self.renders = appendOne(RenderSpec, self.renders, render);
        },
        .user_story => |user_story| {
            self.user_stories = appendOne(UserStorySpec, self.user_stories, user_story);
        },
        .doc => |doc| {
            self.addDoc(doc);
        },
    }
}

pub fn addDoc(self: *Doc, comptime doc: Doc) void {
    self.stores = appendMany(StoreObjectSpec, self.stores, doc.stores);
    self.state_paths = appendMany(StatePathSpec, self.state_paths, doc.state_paths);
    self.components = appendMany(ComponentSpec, self.components, doc.components);
    self.reducers = appendMany(ReducerSpec, self.reducers, doc.reducers);
    self.renders = appendMany(RenderSpec, self.renders, doc.renders);
    self.user_stories = appendMany(UserStorySpec, self.user_stories, doc.user_stories);
}

fn appendOne(
    comptime T: type,
    comptime items: []const T,
    comptime item: T,
) []const T {
    const next = comptime blk: {
        var array: [items.len + 1]T = undefined;

        for (items, 0..) |existing, i| {
            array[i] = existing;
        }
        array[items.len] = item;

        break :blk array;
    };

    return next[0..];
}

fn appendMany(
    comptime T: type,
    comptime items: []const T,
    comptime more: []const T,
) []const T {
    var next = items;

    for (more) |item| {
        next = appendOne(T, next, item);
    }

    return next;
}
