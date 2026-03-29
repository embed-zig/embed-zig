//! Memory utilities — re-exports from std.mem.

const re_export = struct {
    const std = @import("std");

    /// Core allocator and alignment types.
    pub const Allocator = std.mem.Allocator;
    pub const Alignment = std.mem.Alignment;

    /// Basic slice length, prefix/suffix, and equality helpers.
    pub const len = std.mem.len;
    pub const count = std.mem.count;
    pub const endsWith = std.mem.endsWith;
    pub const startsWith = std.mem.startsWith;
    pub const span = std.mem.span;
    pub const allEqual = std.mem.allEqual;
    pub const eql = std.mem.eql;
    pub const SliceTo = std.mem.SliceTo;
    pub const sliceTo = std.mem.sliceTo;

    /// Copying and zero-initialization helpers.
    pub const copyForwards = std.mem.copyForwards;
    pub const copyBackwards = std.mem.copyBackwards;
    pub const zeroes = std.mem.zeroes;
    pub const zeroInit = std.mem.zeroInit;

    /// Ordering, sorting, and aggregate min/max helpers.
    pub const sort = std.mem.sort;
    pub const sortUnstable = std.mem.sortUnstable;
    pub const sortContext = std.mem.sortContext;
    pub const sortUnstableContext = std.mem.sortUnstableContext;
    pub const order = std.mem.order;
    pub const orderZ = std.mem.orderZ;
    pub const lessThan = std.mem.lessThan;
    pub const min = std.mem.min;
    pub const max = std.mem.max;
    pub const minMax = std.mem.minMax;
    pub const indexOfMin = std.mem.indexOfMin;
    pub const indexOfMax = std.mem.indexOfMax;
    pub const indexOfMinMax = std.mem.indexOfMinMax;

    /// Search and containment helpers for slices and sentinels.
    pub const indexOfDiff = std.mem.indexOfDiff;
    pub const indexOf = std.mem.indexOf;
    pub const indexOfAny = std.mem.indexOfAny;
    pub const indexOfAnyPos = std.mem.indexOfAnyPos;
    pub const indexOfNone = std.mem.indexOfNone;
    pub const indexOfNonePos = std.mem.indexOfNonePos;
    pub const indexOfPos = std.mem.indexOfPos;
    pub const indexOfPosLinear = std.mem.indexOfPosLinear;
    pub const indexOfScalar = std.mem.indexOfScalar;
    pub const indexOfScalarPos = std.mem.indexOfScalarPos;
    pub const indexOfSentinel = std.mem.indexOfSentinel;
    pub const lastIndexOf = std.mem.lastIndexOf;
    pub const lastIndexOfAny = std.mem.lastIndexOfAny;
    pub const lastIndexOfNone = std.mem.lastIndexOfNone;
    pub const lastIndexOfLinear = std.mem.lastIndexOfLinear;
    pub const lastIndexOfScalar = std.mem.lastIndexOfScalar;
    pub const containsAtLeast = std.mem.containsAtLeast;
    pub const containsAtLeastScalar = std.mem.containsAtLeastScalar;

    /// Endianness conversion and integer encoding helpers.
    pub const bigToNative = std.mem.bigToNative;
    pub const littleToNative = std.mem.littleToNative;
    pub const nativeTo = std.mem.nativeTo;
    pub const nativeToBig = std.mem.nativeToBig;
    pub const nativeToLittle = std.mem.nativeToLittle;
    pub const toNative = std.mem.toNative;

    pub const readInt = std.mem.readInt;
    pub const readPackedInt = std.mem.readPackedInt;
    pub const readPackedIntForeign = std.mem.readPackedIntForeign;
    pub const readPackedIntNative = std.mem.readPackedIntNative;
    pub const readVarInt = std.mem.readVarInt;
    pub const readVarPackedInt = std.mem.readVarPackedInt;
    pub const writeInt = std.mem.writeInt;
    pub const writePackedInt = std.mem.writePackedInt;
    pub const writeVarPackedInt = std.mem.writeVarPackedInt;
    pub const byteSwapAllElements = std.mem.byteSwapAllElements;

    /// In-place mutation and replacement helpers.
    pub const swap = std.mem.swap;
    pub const reverse = std.mem.reverse;
    pub const ReverseIterator = std.mem.ReverseIterator;
    pub const rotate = std.mem.rotate;
    pub const replace = std.mem.replace;
    pub const replaceScalar = std.mem.replaceScalar;
    pub const replacementSize = std.mem.replacementSize;
    pub const collapseRepeats = std.mem.collapseRepeats;
    pub const collapseRepeatsLen = std.mem.collapseRepeatsLen;

    /// Byte and typed view conversion helpers.
    pub const sliceAsBytes = std.mem.sliceAsBytes;
    pub const bytesAsSlice = std.mem.bytesAsSlice;
    pub const asBytes = std.mem.asBytes;
    pub const toBytes = std.mem.toBytes;
    pub const bytesAsValue = std.mem.bytesAsValue;
    pub const bytesToValue = std.mem.bytesToValue;

    /// Alignment calculation and validation helpers.
    pub const AlignedSlice = std.mem.AlignedSlice;
    pub const alignBackward = std.mem.alignBackward;
    pub const alignBackwardAnyAlign = std.mem.alignBackwardAnyAlign;
    pub const alignForward = std.mem.alignForward;
    pub const alignForwardAnyAlign = std.mem.alignForwardAnyAlign;
    pub const alignForwardLog2 = std.mem.alignForwardLog2;
    pub const alignInBytes = std.mem.alignInBytes;
    pub const alignInSlice = std.mem.alignInSlice;
    pub const alignPointer = std.mem.alignPointer;
    pub const alignPointerOffset = std.mem.alignPointerOffset;
    pub const doNotOptimizeAway = std.mem.doNotOptimizeAway;
    pub const isValidAlign = std.mem.isValidAlign;
    pub const isValidAlignGeneric = std.mem.isValidAlignGeneric;
    pub const isAlignedAnyAlign = std.mem.isAlignedAnyAlign;
    pub const isAlignedLog2 = std.mem.isAlignedLog2;
    pub const isAligned = std.mem.isAligned;
    pub const isAlignedGeneric = std.mem.isAlignedGeneric;

    /// Tokenization iterators and helpers.
    pub const DelimiterType = std.mem.DelimiterType;
    pub const TokenIterator = std.mem.TokenIterator;
    pub const tokenizeAny = std.mem.tokenizeAny;
    pub const tokenizeScalar = std.mem.tokenizeScalar;
    pub const tokenizeSequence = std.mem.tokenizeSequence;

    /// Splitting iterators and helpers.
    pub const splitAny = std.mem.splitAny;
    pub const splitBackwardsAny = std.mem.splitBackwardsAny;
    pub const SplitBackwardsIterator = std.mem.SplitBackwardsIterator;
    pub const splitBackwardsScalar = std.mem.splitBackwardsScalar;
    pub const splitBackwardsSequence = std.mem.splitBackwardsSequence;
    pub const SplitIterator = std.mem.SplitIterator;
    pub const splitScalar = std.mem.splitScalar;
    pub const splitSequence = std.mem.splitSequence;
    pub const window = std.mem.window;
    pub const WindowIterator = std.mem.WindowIterator;

    /// Trimming helpers for prefix/suffix stripping.
    pub const trimStart = std.mem.trimStart;
    pub const trimLeft = std.mem.trimLeft;
    pub const trimEnd = std.mem.trimEnd;
    pub const trimRight = std.mem.trimRight;
    pub const trim = std.mem.trim;

    /// Joining helpers for combining slices with separators.
    pub const join = std.mem.join;
    pub const joinZ = std.mem.joinZ;
    pub const joinMaybeZ = std.mem.joinMaybeZ;

    /// Concatenation helpers for building combined slices.
    pub const concat = std.mem.concat;
    pub const concatWithSentinel = std.mem.concatWithSentinel;
    pub const concatMaybeSentinel = std.mem.concatMaybeSentinel;
};

/// Core allocator and alignment types.
pub const Allocator = re_export.Allocator;
pub const Alignment = re_export.Alignment;

/// Basic slice length, prefix/suffix, and equality helpers.
pub const len = re_export.len;
pub const count = re_export.count;
pub const endsWith = re_export.endsWith;
pub const startsWith = re_export.startsWith;
pub const span = re_export.span;
pub const allEqual = re_export.allEqual;
pub const eql = re_export.eql;
pub const SliceTo = re_export.SliceTo;
pub const sliceTo = re_export.sliceTo;

/// Copying and zero-initialization helpers.
pub const copyForwards = re_export.copyForwards;
pub const copyBackwards = re_export.copyBackwards;
pub const zeroes = re_export.zeroes;
pub const zeroInit = re_export.zeroInit;

/// Ordering, sorting, and aggregate min/max helpers.
pub const sort = re_export.sort;
pub const sortUnstable = re_export.sortUnstable;
pub const sortContext = re_export.sortContext;
pub const sortUnstableContext = re_export.sortUnstableContext;
pub const order = re_export.order;
pub const orderZ = re_export.orderZ;
pub const lessThan = re_export.lessThan;
pub const min = re_export.min;
pub const max = re_export.max;
pub const minMax = re_export.minMax;
pub const indexOfMin = re_export.indexOfMin;
pub const indexOfMax = re_export.indexOfMax;
pub const indexOfMinMax = re_export.indexOfMinMax;

/// Search and containment helpers for slices and sentinels.
pub const indexOfDiff = re_export.indexOfDiff;
pub const indexOf = re_export.indexOf;
pub const indexOfAny = re_export.indexOfAny;
pub const indexOfAnyPos = re_export.indexOfAnyPos;
pub const indexOfNone = re_export.indexOfNone;
pub const indexOfNonePos = re_export.indexOfNonePos;
pub const indexOfPos = re_export.indexOfPos;
pub const indexOfPosLinear = re_export.indexOfPosLinear;
pub const indexOfScalar = re_export.indexOfScalar;
pub const indexOfScalarPos = re_export.indexOfScalarPos;
pub const indexOfSentinel = re_export.indexOfSentinel;
pub const lastIndexOf = re_export.lastIndexOf;
pub const lastIndexOfAny = re_export.lastIndexOfAny;
pub const lastIndexOfNone = re_export.lastIndexOfNone;
pub const lastIndexOfLinear = re_export.lastIndexOfLinear;
pub const lastIndexOfScalar = re_export.lastIndexOfScalar;
pub const containsAtLeast = re_export.containsAtLeast;
pub const containsAtLeastScalar = re_export.containsAtLeastScalar;

/// Endianness conversion and integer encoding helpers.
pub const bigToNative = re_export.bigToNative;
pub const littleToNative = re_export.littleToNative;
pub const nativeTo = re_export.nativeTo;
pub const nativeToBig = re_export.nativeToBig;
pub const nativeToLittle = re_export.nativeToLittle;
pub const toNative = re_export.toNative;
pub const readInt = re_export.readInt;
pub const readPackedInt = re_export.readPackedInt;
pub const readPackedIntForeign = re_export.readPackedIntForeign;
pub const readPackedIntNative = re_export.readPackedIntNative;
pub const readVarInt = re_export.readVarInt;
pub const readVarPackedInt = re_export.readVarPackedInt;
pub const writeInt = re_export.writeInt;
pub const writePackedInt = re_export.writePackedInt;
pub const writeVarPackedInt = re_export.writeVarPackedInt;
pub const byteSwapAllElements = re_export.byteSwapAllElements;

/// In-place mutation and replacement helpers.
pub const swap = re_export.swap;
pub const reverse = re_export.reverse;
pub const ReverseIterator = re_export.ReverseIterator;
pub const rotate = re_export.rotate;
pub const replace = re_export.replace;
pub const replaceScalar = re_export.replaceScalar;
pub const replacementSize = re_export.replacementSize;
pub const collapseRepeats = re_export.collapseRepeats;
pub const collapseRepeatsLen = re_export.collapseRepeatsLen;

/// Byte and typed view conversion helpers.
pub const sliceAsBytes = re_export.sliceAsBytes;
pub const bytesAsSlice = re_export.bytesAsSlice;
pub const asBytes = re_export.asBytes;
pub const toBytes = re_export.toBytes;
pub const bytesAsValue = re_export.bytesAsValue;
pub const bytesToValue = re_export.bytesToValue;

/// Alignment calculation and validation helpers.
pub const AlignedSlice = re_export.AlignedSlice;
pub const alignBackward = re_export.alignBackward;
pub const alignBackwardAnyAlign = re_export.alignBackwardAnyAlign;
pub const alignForward = re_export.alignForward;
pub const alignForwardAnyAlign = re_export.alignForwardAnyAlign;
pub const alignForwardLog2 = re_export.alignForwardLog2;
pub const alignInBytes = re_export.alignInBytes;
pub const alignInSlice = re_export.alignInSlice;
pub const alignPointer = re_export.alignPointer;
pub const alignPointerOffset = re_export.alignPointerOffset;
pub const doNotOptimizeAway = re_export.doNotOptimizeAway;
pub const isValidAlign = re_export.isValidAlign;
pub const isValidAlignGeneric = re_export.isValidAlignGeneric;
pub const isAlignedAnyAlign = re_export.isAlignedAnyAlign;
pub const isAlignedLog2 = re_export.isAlignedLog2;
pub const isAligned = re_export.isAligned;
pub const isAlignedGeneric = re_export.isAlignedGeneric;

/// Tokenization iterators and helpers.
pub const DelimiterType = re_export.DelimiterType;
pub const TokenIterator = re_export.TokenIterator;
pub const tokenizeAny = re_export.tokenizeAny;
pub const tokenizeScalar = re_export.tokenizeScalar;
pub const tokenizeSequence = re_export.tokenizeSequence;

/// Splitting iterators and helpers.
pub const splitAny = re_export.splitAny;
pub const splitBackwardsAny = re_export.splitBackwardsAny;
pub const SplitBackwardsIterator = re_export.SplitBackwardsIterator;
pub const splitBackwardsScalar = re_export.splitBackwardsScalar;
pub const splitBackwardsSequence = re_export.splitBackwardsSequence;
pub const SplitIterator = re_export.SplitIterator;
pub const splitScalar = re_export.splitScalar;
pub const splitSequence = re_export.splitSequence;
pub const window = re_export.window;
pub const WindowIterator = re_export.WindowIterator;

/// Trimming helpers for prefix/suffix stripping.
pub const trimStart = re_export.trimStart;
pub const trimLeft = re_export.trimLeft;
pub const trimEnd = re_export.trimEnd;
pub const trimRight = re_export.trimRight;
pub const trim = re_export.trim;

/// Joining helpers for combining slices with separators.
pub const join = re_export.join;
pub const joinZ = re_export.joinZ;
pub const joinMaybeZ = re_export.joinMaybeZ;

/// Concatenation helpers for building combined slices.
pub const concat = re_export.concat;
pub const concatWithSentinel = re_export.concatWithSentinel;
pub const concatMaybeSentinel = re_export.concatMaybeSentinel;
