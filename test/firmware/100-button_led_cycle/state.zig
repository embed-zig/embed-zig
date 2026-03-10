const std = @import("std");
const embed = @import("embed");
const event = embed.pkg.event;
const led = embed.pkg.ui.led_strip;

const GestureCode = event.button.GestureCode;

pub const Color = led.Color;
pub const Frame = led.Frame(1);
pub const LedAnim = led.Animator(1, 4);

pub const State = struct {
    led: LedAnim = .{},
};

pub const Event = union(enum) {
    button: event.PeriphEvent,
    led_tick: void,
};

pub fn tickMiddleware(_: ?*anyopaque, _: u64, emit_ctx: *anyopaque, emit: event.EmitFn(Event)) void {
    emit(emit_ctx, .led_tick);
}

const click_colors = [_]Color{ Color.red, Color.green, Color.blue, Color.white };

fn transitionTo(state: *State, target: Frame) void {
    const prev = state.led.current;
    state.led = LedAnim.fixed(target);
    state.led.current = prev;
}

pub fn reduce(state: *State, ev: Event) void {
    switch (ev) {
        .button => |b| {
            const code: u16 = b.code;
            if (code == @intFromEnum(GestureCode.click)) {
                const count: usize = @intCast(b.data);
                if (count > 0 and count <= click_colors.len) {
                    transitionTo(state, Frame.solid(click_colors[count - 1]));
                }
            } else if (code == @intFromEnum(GestureCode.long_press)) {
                const target = if (std.meta.eql(state.led.current.pixels[0], Color.black))
                    Color.white
                else
                    Color.black;
                transitionTo(state, Frame.solid(target));
            }
        },
        .led_tick => {
            _ = state.led.tick();
        },
    }
}
