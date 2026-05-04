const std = @import("std");
const builtin = @import("builtin");

const math = std.math;
const mem = std.mem;

const ofmt_c = builtin.object_format == .c;
const linkage: std.builtin.GlobalLinkage = if (builtin.is_test)
    .internal
else if (ofmt_c)
    .strong
else
    .weak;
const visibility: std.builtin.SymbolVisibility = if (linkage == .internal or builtin.link_mode == .dynamic)
    .default
else
    .hidden;
const want_float_exceptions = !builtin.cpu.arch.isWasm();

pub const panic = if (builtin.is_test)
    std.debug.FullPanic(std.debug.defaultPanic)
else
    std.debug.no_panic;

comptime {
    @export(&__addtf3, .{ .name = "__addtf3", .linkage = linkage, .visibility = visibility });
    @export(&__subtf3, .{ .name = "__subtf3", .linkage = linkage, .visibility = visibility });
    @export(&__multf3, .{ .name = "__multf3", .linkage = linkage, .visibility = visibility });
    @export(&__divtf3, .{ .name = "__divtf3", .linkage = linkage, .visibility = visibility });
    @export(&__cmptf2, .{ .name = "__cmptf2", .linkage = linkage, .visibility = visibility });
    @export(&__eqtf2, .{ .name = "__eqtf2", .linkage = linkage, .visibility = visibility });
    @export(&__netf2, .{ .name = "__netf2", .linkage = linkage, .visibility = visibility });
    @export(&__lttf2, .{ .name = "__lttf2", .linkage = linkage, .visibility = visibility });
    @export(&__letf2, .{ .name = "__letf2", .linkage = linkage, .visibility = visibility });
    @export(&__getf2, .{ .name = "__getf2", .linkage = linkage, .visibility = visibility });
    @export(&__gttf2, .{ .name = "__gttf2", .linkage = linkage, .visibility = visibility });
    @export(&__unordtf2, .{ .name = "__unordtf2", .linkage = linkage, .visibility = visibility });
    @export(&__floatuntitf, .{ .name = "__floatuntitf", .linkage = linkage, .visibility = visibility });
    @export(&__fixtfti, .{ .name = "__fixtfti", .linkage = linkage, .visibility = visibility });
    @export(&roundq, .{ .name = "roundq", .linkage = linkage, .visibility = visibility });
}

fn wideMultiplyU128(a: u128, b: u128, hi: *u128, lo: *u128) void {
    const word_lo_mask: u64 = 0x00000000ffffffff;
    const word_hi_mask: u64 = 0xffffffff00000000;
    const word_full_mask: u64 = 0xffffffffffffffff;

    const W = struct {
        fn one(x: u128) u64 {
            return @as(u32, @truncate(x >> 96));
        }
        fn two(x: u128) u64 {
            return @as(u32, @truncate(x >> 64));
        }
        fn three(x: u128) u64 {
            return @as(u32, @truncate(x >> 32));
        }
        fn four(x: u128) u64 {
            return @as(u32, @truncate(x));
        }
    };

    const product11: u64 = W.one(a) * W.one(b);
    const product12: u64 = W.one(a) * W.two(b);
    const product13: u64 = W.one(a) * W.three(b);
    const product14: u64 = W.one(a) * W.four(b);
    const product21: u64 = W.two(a) * W.one(b);
    const product22: u64 = W.two(a) * W.two(b);
    const product23: u64 = W.two(a) * W.three(b);
    const product24: u64 = W.two(a) * W.four(b);
    const product31: u64 = W.three(a) * W.one(b);
    const product32: u64 = W.three(a) * W.two(b);
    const product33: u64 = W.three(a) * W.three(b);
    const product34: u64 = W.three(a) * W.four(b);
    const product41: u64 = W.four(a) * W.one(b);
    const product42: u64 = W.four(a) * W.two(b);
    const product43: u64 = W.four(a) * W.three(b);
    const product44: u64 = W.four(a) * W.four(b);

    const sum0: u128 = @as(u128, product44);
    const sum1: u128 = @as(u128, product34) +% @as(u128, product43);
    const sum2: u128 = @as(u128, product24) +%
        @as(u128, product33) +%
        @as(u128, product42);
    const sum3: u128 = @as(u128, product14) +%
        @as(u128, product23) +%
        @as(u128, product32) +%
        @as(u128, product41);
    const sum4: u128 = @as(u128, product13) +%
        @as(u128, product22) +%
        @as(u128, product31);
    const sum5: u128 = @as(u128, product12) +% @as(u128, product21);
    const sum6: u128 = @as(u128, product11);

    const r0: u128 = (sum0 & word_full_mask) +%
        ((sum1 & word_lo_mask) << 32);
    const r1: u128 = (sum0 >> 64) +%
        ((sum1 >> 32) & word_full_mask) +%
        (sum2 & word_full_mask) +%
        ((sum3 << 32) & word_hi_mask);

    lo.* = r0 +% (r1 << 64);
    hi.* = (r1 >> 64) +%
        (sum1 >> 96) +%
        (sum2 >> 64) +%
        (sum3 >> 32) +%
        sum4 +%
        (sum5 << 32) +%
        (sum6 << 64);
}

fn normalizeF128(significand: *u128) i32 {
    const integer_bit = @as(u128, 1) << math.floatFractionalBits(f128);
    const shift = @clz(significand.*) - @clz(integer_bit);
    significand.* <<= @as(math.Log2Int(u128), @intCast(shift));
    return @as(i32, 1) - shift;
}

const LE = enum(i32) {
    Less = -1,
    Equal = 0,
    Greater = 1,

    const Unordered: LE = .Greater;
};

const GE = enum(i32) {
    Less = -1,
    Equal = 0,
    Greater = 1,

    const Unordered: GE = .Less;
};

fn cmpf2(comptime RT: type, a: f128, b: f128) RT {
    const sign_bit = (@as(u128, 1) << 127);
    const abs_mask = sign_bit - 1;
    const inf_rep = @as(u128, @bitCast(math.inf(f128)));

    const a_int = @as(i128, @bitCast(a));
    const b_int = @as(i128, @bitCast(b));
    const a_abs = @as(u128, @bitCast(a_int)) & abs_mask;
    const b_abs = @as(u128, @bitCast(b_int)) & abs_mask;

    if (a_abs > inf_rep or b_abs > inf_rep) return RT.Unordered;
    if ((a_abs | b_abs) == 0) return .Equal;

    if ((a_int & b_int) >= 0) {
        if (a_int < b_int) return .Less;
        if (a_int == b_int) return .Equal;
        return .Greater;
    }

    if (a_int > b_int) return .Less;
    if (a_int == b_int) return .Equal;
    return .Greater;
}

fn unordcmpf128(a: f128, b: f128) i32 {
    const sign_bit = (@as(u128, 1) << 127);
    const abs_mask = sign_bit - 1;
    const inf_rep = @as(u128, @bitCast(math.inf(f128)));

    const a_abs: u128 = @as(u128, @bitCast(a)) & abs_mask;
    const b_abs: u128 = @as(u128, @bitCast(b)) & abs_mask;
    return @intFromBool(a_abs > inf_rep or b_abs > inf_rep);
}

fn floatFromUnsignedIntToF128(x: u128) f128 {
    if (x == 0) return 0;

    const exp_bias: u128 = math.maxInt(u14);
    const implicit_bit: u128 = @as(u128, 1) << 112;

    const exp = 127 - @clz(x);
    var result: u128 = 0;

    if (exp <= 112) {
        const shift_amt = 112 - exp;
        result = x << @intCast(shift_amt);
        result ^= implicit_bit;
    } else {
        const shift_amt = exp - 112;
        const exact_tie = @ctz(x) == shift_amt - 1;
        result = (x >> @intCast(shift_amt - 1)) ^ (implicit_bit << 1);
        result = ((result + 1) >> 1) & ~@as(u128, @intFromBool(exact_tie));
    }

    result += (@as(u128, exp) + exp_bias) << 112;
    return @bitCast(result);
}

fn intFromF128ToI128(a: f128) i128 {
    const a_rep: u128 = @bitCast(a);
    const negative = (a_rep >> 127) != 0;
    const exponent = @as(i32, @intCast((a_rep << 1) >> 113)) - 16383;
    const significand: u128 = (a_rep & ((@as(u128, 1) << 112) - 1)) | (@as(u128, 1) << 112);

    if (exponent < 0) return 0;
    if (@as(u32, @intCast(exponent)) >= 127) {
        return if (negative) math.minInt(i128) else math.maxInt(i128);
    }

    var result: i128 = undefined;
    if (exponent < 112) {
        result = @intCast(significand >> @intCast(112 - exponent));
    } else {
        result = @as(i128, @intCast(significand)) << @intCast(exponent - 112);
    }

    if (negative) return ~result +% 1;
    return result;
}

fn addf3(a: f128, b: f128) f128 {
    const significand_bits = math.floatMantissaBits(f128);
    const fractional_bits = math.floatFractionalBits(f128);
    const exponent_bits = math.floatExponentBits(f128);

    const sign_bit = (@as(u128, 1) << (significand_bits + exponent_bits));
    const max_exponent = ((1 << exponent_bits) - 1);
    const integer_bit = (@as(u128, 1) << fractional_bits);
    const quiet_bit = integer_bit >> 1;
    const significand_mask = (@as(u128, 1) << significand_bits) - 1;
    const abs_mask = sign_bit - 1;
    const qnan_rep = @as(u128, @bitCast(math.nan(f128))) | quiet_bit;

    var a_rep: u128 = @bitCast(a);
    var b_rep: u128 = @bitCast(b);
    const a_abs = a_rep & abs_mask;
    const b_abs = b_rep & abs_mask;
    const inf_rep: u128 = @bitCast(math.inf(f128));

    if (a_abs -% 1 >= inf_rep -% 1 or b_abs -% 1 >= inf_rep -% 1) {
        if (a_abs > inf_rep) return @bitCast(@as(u128, @bitCast(a)) | quiet_bit);
        if (b_abs > inf_rep) return @bitCast(@as(u128, @bitCast(b)) | quiet_bit);

        if (a_abs == inf_rep) {
            if ((@as(u128, @bitCast(a)) ^ @as(u128, @bitCast(b))) == sign_bit) {
                return @bitCast(qnan_rep);
            }
            return a;
        }
        if (b_abs == inf_rep) return b;

        if (a_abs == 0) {
            if (b_abs == 0) {
                return @bitCast(@as(u128, @bitCast(a)) & @as(u128, @bitCast(b)));
            }
            return b;
        }
        if (b_abs == 0) return a;
    }

    if (b_abs > a_abs) {
        const temp = a_rep;
        a_rep = b_rep;
        b_rep = temp;
    }

    var a_exponent: i32 = @intCast((a_rep >> significand_bits) & max_exponent);
    var b_exponent: i32 = @intCast((b_rep >> significand_bits) & max_exponent);
    var a_significand = a_rep & significand_mask;
    var b_significand = b_rep & significand_mask;

    if (a_exponent == 0) a_exponent = normalizeF128(&a_significand);
    if (b_exponent == 0) b_exponent = normalizeF128(&b_significand);

    const result_sign = a_rep & sign_bit;
    const subtraction = (a_rep ^ b_rep) & sign_bit != 0;

    a_significand = (a_significand | integer_bit) << 3;
    b_significand = (b_significand | integer_bit) << 3;

    const align_shift: u32 = @intCast(a_exponent - b_exponent);
    if (align_shift != 0) {
        if (align_shift < 128) {
            const sticky = if (b_significand << @intCast(128 - align_shift) != 0) @as(u128, 1) else 0;
            b_significand = (b_significand >> @truncate(align_shift)) | sticky;
        } else {
            b_significand = 1;
        }
    }

    if (subtraction) {
        a_significand -= b_significand;
        if (a_significand == 0) return @bitCast(@as(u128, 0));

        if (a_significand < integer_bit << 3) {
            const shift = @as(i32, @intCast(@clz(a_significand))) - @as(i32, @intCast(@clz(integer_bit << 3)));
            a_significand <<= @intCast(shift);
            a_exponent -= shift;
        }
    } else {
        a_significand += b_significand;
        if (a_significand & (integer_bit << 4) != 0) {
            const sticky = a_significand & 1;
            a_significand = (a_significand >> 1) | sticky;
            a_exponent += 1;
        }
    }

    if (a_exponent >= max_exponent) return @bitCast(inf_rep | result_sign);

    if (a_exponent <= 0) {
        a_significand >>= @intCast(4 - a_exponent);
        return @bitCast(result_sign | a_significand);
    }

    const round_guard_sticky = a_significand & 0x7;
    var result = (a_significand >> 3) & significand_mask;
    result |= @as(u128, @intCast(a_exponent)) << significand_bits;
    result |= result_sign;

    if (round_guard_sticky > 0x4) result += 1;
    if (round_guard_sticky == 0x4) result += result & 1;
    return @bitCast(result);
}

fn mulf3(a: f128, b: f128) f128 {
    const significand_bits = math.floatMantissaBits(f128);
    const fractional_bits = math.floatFractionalBits(f128);
    const exponent_bits = math.floatExponentBits(f128);

    const round_bit: u128 = (@as(u128, 1) << 127);
    const sign_bit = (@as(u128, 1) << (significand_bits + exponent_bits));
    const max_exponent = ((1 << exponent_bits) - 1);
    const exponent_bias = (max_exponent >> 1);
    const integer_bit = (@as(u128, 1) << fractional_bits);
    const quiet_bit = integer_bit >> 1;
    const significand_mask = (@as(u128, 1) << significand_bits) - 1;
    const abs_mask = sign_bit - 1;
    const qnan_rep = @as(u128, @bitCast(math.nan(f128))) | quiet_bit;
    const inf_rep: u128 = @bitCast(math.inf(f128));
    const a_exponent: u32 = @truncate((@as(u128, @bitCast(a)) >> significand_bits) & max_exponent);
    const b_exponent: u32 = @truncate((@as(u128, @bitCast(b)) >> significand_bits) & max_exponent);
    const product_sign: u128 = (@as(u128, @bitCast(a)) ^ @as(u128, @bitCast(b))) & sign_bit;

    var a_significand: u128 = @intCast(@as(u128, @bitCast(a)) & significand_mask);
    var b_significand: u128 = @intCast(@as(u128, @bitCast(b)) & significand_mask);
    var scale: i32 = 0;

    if (a_exponent -% 1 >= max_exponent - 1 or b_exponent -% 1 >= max_exponent - 1) {
        const a_abs: u128 = @as(u128, @bitCast(a)) & abs_mask;
        const b_abs: u128 = @as(u128, @bitCast(b)) & abs_mask;

        if (a_abs > inf_rep) return @bitCast(@as(u128, @bitCast(a)) | quiet_bit);
        if (b_abs > inf_rep) return @bitCast(@as(u128, @bitCast(b)) | quiet_bit);

        if (a_abs == inf_rep) {
            if (b_abs != 0) return @bitCast(a_abs | product_sign);
            return @bitCast(qnan_rep);
        }
        if (b_abs == inf_rep) {
            if (a_abs != 0) return @bitCast(b_abs | product_sign);
            return @bitCast(qnan_rep);
        }
        if (a_abs == 0) return @bitCast(product_sign);
        if (b_abs == 0) return @bitCast(product_sign);

        if (a_abs < @as(u128, @bitCast(math.floatMin(f128)))) scale += normalizeF128(&a_significand);
        if (b_abs < @as(u128, @bitCast(math.floatMin(f128)))) scale += normalizeF128(&b_significand);
    }

    a_significand |= integer_bit;
    b_significand |= integer_bit;

    var product_hi: u128 = undefined;
    var product_lo: u128 = undefined;
    const left_align_shift = 128 - fractional_bits - 1;
    wideMultiplyU128(a_significand, b_significand << left_align_shift, &product_hi, &product_lo);

    var product_exponent: i32 = @as(i32, @intCast(a_exponent + b_exponent)) - exponent_bias + scale;

    if ((product_hi & integer_bit) != 0) {
        product_exponent +%= 1;
    } else {
        product_hi = (product_hi << 1) | (product_lo >> 127);
        product_lo <<= 1;
    }

    if (product_exponent >= max_exponent) return @bitCast(inf_rep | product_sign);

    var result: u128 = undefined;
    if (product_exponent <= 0) {
        const shift: u32 = @truncate(@as(u32, 1) -% @as(u32, @bitCast(product_exponent)));
        if (shift >= 128) return @bitCast(product_sign);

        const sticky = wideShrWithTruncation(&product_hi, &product_lo, shift);
        product_lo |= @intFromBool(sticky);
        result = product_hi;
    } else {
        result = product_hi & significand_mask;
        result |= @as(u128, @intCast(product_exponent)) << significand_bits;
    }

    if (product_lo > round_bit) result +%= 1;
    if (product_lo == round_bit) result +%= result & 1;
    result |= product_sign;
    return @bitCast(result);
}

fn wideShrWithTruncation(hi: *u128, lo: *u128, count: u32) bool {
    var inexact = false;
    if (count < 128) {
        inexact = (lo.* << @intCast(128 - count)) != 0;
        lo.* = (hi.* << @intCast(128 - count)) | (lo.* >> @intCast(count));
        hi.* >>= @intCast(count);
    } else if (count < 256) {
        inexact = (hi.* << @intCast(256 - count) | lo.*) != 0;
        lo.* = hi.* >> @intCast(count - 128);
        hi.* = 0;
    } else {
        inexact = (hi.* | lo.*) != 0;
        lo.* = 0;
        hi.* = 0;
    }
    return inexact;
}

pub fn __addtf3(a: f128, b: f128) callconv(.c) f128 {
    return addf3(a, b);
}

pub fn __subtf3(a: f128, b: f128) callconv(.c) f128 {
    const neg_b = @as(f128, @bitCast(@as(u128, @bitCast(b)) ^ (@as(u128, 1) << 127)));
    return addf3(a, neg_b);
}

pub fn __multf3(a: f128, b: f128) callconv(.c) f128 {
    return mulf3(a, b);
}

pub fn __divtf3(a: f128, b: f128) callconv(.c) f128 {
    const significand_bits = math.floatMantissaBits(f128);
    const exponent_bits = math.floatExponentBits(f128);
    const sign_bit = (@as(u128, 1) << (significand_bits + exponent_bits));
    const max_exponent = ((1 << exponent_bits) - 1);
    const exponent_bias = (max_exponent >> 1);
    const implicit_bit = (@as(u128, 1) << significand_bits);
    const quiet_bit = implicit_bit >> 1;
    const significand_mask = implicit_bit - 1;
    const abs_mask = sign_bit - 1;
    const exponent_mask = abs_mask ^ significand_mask;
    const qnan_rep = exponent_mask | quiet_bit;
    const inf_rep: u128 = @bitCast(math.inf(f128));
    const a_exponent: u32 = @truncate((@as(u128, @bitCast(a)) >> significand_bits) & max_exponent);
    const b_exponent: u32 = @truncate((@as(u128, @bitCast(b)) >> significand_bits) & max_exponent);
    const quotient_sign: u128 = (@as(u128, @bitCast(a)) ^ @as(u128, @bitCast(b))) & sign_bit;

    var a_significand: u128 = @as(u128, @bitCast(a)) & significand_mask;
    var b_significand: u128 = @as(u128, @bitCast(b)) & significand_mask;
    var scale: i32 = 0;

    if (a_exponent -% 1 >= max_exponent - 1 or b_exponent -% 1 >= max_exponent - 1) {
        const a_abs: u128 = @as(u128, @bitCast(a)) & abs_mask;
        const b_abs: u128 = @as(u128, @bitCast(b)) & abs_mask;

        if (a_abs > inf_rep) return @bitCast(@as(u128, @bitCast(a)) | quiet_bit);
        if (b_abs > inf_rep) return @bitCast(@as(u128, @bitCast(b)) | quiet_bit);

        if (a_abs == inf_rep) {
            if (b_abs == inf_rep) return @bitCast(qnan_rep);
            return @bitCast(a_abs | quotient_sign);
        }
        if (b_abs == inf_rep) return @bitCast(quotient_sign);
        if (a_abs == 0) {
            if (b_abs == 0) return @bitCast(qnan_rep);
            return @bitCast(quotient_sign);
        }
        if (b_abs == 0) return @bitCast(inf_rep | quotient_sign);

        if (a_abs < implicit_bit) scale +%= normalizeF128(&a_significand);
        if (b_abs < implicit_bit) scale -%= normalizeF128(&b_significand);
    }

    a_significand |= implicit_bit;
    b_significand |= implicit_bit;
    var quotient_exponent: i32 = @as(i32, @intCast(a_exponent)) - @as(i32, @intCast(b_exponent)) + scale;

    const q63b: u64 = @truncate(b_significand >> 49);
    var recip64: u64 = 0x7504f333F9DE6484 -% q63b;

    var correction64: u64 = undefined;
    correction64 = @truncate(~(@as(u128, recip64) *% q63b >> 64) +% 1);
    recip64 = @truncate(@as(u128, recip64) *% correction64 >> 63);
    correction64 = @truncate(~(@as(u128, recip64) *% q63b >> 64) +% 1);
    recip64 = @truncate(@as(u128, recip64) *% correction64 >> 63);
    correction64 = @truncate(~(@as(u128, recip64) *% q63b >> 64) +% 1);
    recip64 = @truncate(@as(u128, recip64) *% correction64 >> 63);
    correction64 = @truncate(~(@as(u128, recip64) *% q63b >> 64) +% 1);
    recip64 = @truncate(@as(u128, recip64) *% correction64 >> 63);
    correction64 = @truncate(~(@as(u128, recip64) *% q63b >> 64) +% 1);
    recip64 = @truncate(@as(u128, recip64) *% correction64 >> 63);
    recip64 -%= 1;

    const q127blo: u64 = @truncate(b_significand << 15);
    var correction: u128 = undefined;
    var reciprocal: u128 = undefined;
    var r64q63: u128 = undefined;
    var r64q127: u128 = undefined;
    var r64c_h: u128 = undefined;
    var r64c_l: u128 = undefined;
    var dummy: u128 = undefined;

    wideMultiplyU128(recip64, q63b, &dummy, &r64q63);
    wideMultiplyU128(recip64, q127blo, &dummy, &r64q127);
    correction = -%(r64q63 + (r64q127 >> 64));

    const c_hi: u64 = @truncate(correction >> 64);
    const c_lo: u64 = @truncate(correction);
    wideMultiplyU128(recip64, c_hi, &dummy, &r64c_h);
    wideMultiplyU128(recip64, c_lo, &dummy, &r64c_l);
    reciprocal = r64c_h + (r64c_l >> 64);
    reciprocal -%= 2;

    var quotient: u128 = undefined;
    var quotient_lo: u128 = undefined;
    wideMultiplyU128(a_significand << 2, reciprocal, &quotient, &quotient_lo);

    var residual: u128 = undefined;
    var qb: u128 = undefined;
    if (quotient < (implicit_bit << 1)) {
        wideMultiplyU128(quotient, b_significand, &dummy, &qb);
        residual = (a_significand << 113) -% qb;
        quotient_exponent -%= 1;
    } else {
        quotient >>= 1;
        wideMultiplyU128(quotient, b_significand, &dummy, &qb);
        residual = (a_significand << 112) -% qb;
    }

    const written_exponent = quotient_exponent +% exponent_bias;
    if (written_exponent >= max_exponent) {
        return @bitCast(inf_rep | quotient_sign);
    } else if (written_exponent < 1) {
        if (written_exponent == 0) {
            const round = @intFromBool((residual << 1) > b_significand);
            var abs_result = quotient & significand_mask;
            abs_result += round;
            if ((abs_result & ~significand_mask) > 0) return @bitCast(abs_result | quotient_sign);
        }
        return @bitCast(quotient_sign);
    } else {
        const round = @intFromBool((residual << 1) >= b_significand);
        var abs_result = quotient & significand_mask;
        abs_result |= @as(u128, @intCast(written_exponent)) << significand_bits;
        abs_result +%= round;
        return @bitCast(abs_result | quotient_sign);
    }
}

fn __cmptf2(a: f128, b: f128) callconv(.c) i32 {
    return @intFromEnum(cmpf2(LE, a, b));
}

fn __letf2(a: f128, b: f128) callconv(.c) i32 {
    return __cmptf2(a, b);
}

fn __eqtf2(a: f128, b: f128) callconv(.c) i32 {
    return __cmptf2(a, b);
}

fn __netf2(a: f128, b: f128) callconv(.c) i32 {
    return __cmptf2(a, b);
}

fn __lttf2(a: f128, b: f128) callconv(.c) i32 {
    return __cmptf2(a, b);
}

fn __getf2(a: f128, b: f128) callconv(.c) i32 {
    return @intFromEnum(cmpf2(GE, a, b));
}

fn __gttf2(a: f128, b: f128) callconv(.c) i32 {
    return __getf2(a, b);
}

fn __unordtf2(a: f128, b: f128) callconv(.c) i32 {
    return unordcmpf128(a, b);
}

pub fn __floatuntitf(a: u128) callconv(.c) f128 {
    return floatFromUnsignedIntToF128(a);
}

pub fn __fixtfti(a: f128) callconv(.c) i128 {
    return intFromF128ToI128(a);
}

pub fn roundq(x_: f128) callconv(.c) f128 {
    const f128_toint = 1.0 / math.floatEps(f128);

    var x = x_;
    const u: u128 = @bitCast(x);
    const e = (u >> 112) & 0x7FFF;
    var y: f128 = undefined;

    if (e >= 0x3FFF + 112) {
        return x;
    }
    if (u >> 127 != 0) {
        x = -x;
    }
    if (e < 0x3FFF - 1) {
        if (want_float_exceptions) mem.doNotOptimizeAway(x + f128_toint);
        return 0 * @as(f128, @bitCast(u));
    }

    y = x + f128_toint - f128_toint - x;
    if (y > 0.5) {
        y = y + x - 1;
    } else if (y <= -0.5) {
        y = y + x + 1;
    } else {
        y = y + x;
    }

    if (u >> 127 != 0) {
        return -y;
    }
    return y;
}
