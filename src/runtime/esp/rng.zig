const esp = @import("esp");
const runtime = @import("runtime");

pub const Rng = struct {
    pub fn fill(_: Rng, buf: []u8) runtime.rng.Error!void {
        esp.random.fill(buf);
    }
};
