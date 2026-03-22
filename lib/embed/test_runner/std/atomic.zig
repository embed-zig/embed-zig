pub fn run(comptime lib: type) !void {
    const log = lib.log.scoped(.atomic);

    var v = lib.atomic.Value(u32).init(0);
    v.store(10, .seq_cst);
    const loaded = v.load(.seq_cst);
    if (loaded != 10) return error.AtomicStoreFailed;
    log.info("store/load ok val={}", .{loaded});

    const prev = v.fetchAdd(5, .seq_cst);
    if (prev != 10) return error.AtomicFetchAddPrevFailed;
    const after = v.load(.seq_cst);
    if (after != 15) return error.AtomicFetchAddFailed;
    log.info("fetchAdd ok prev={} after={}", .{ prev, after });

    const prev2 = v.fetchSub(3, .seq_cst);
    if (prev2 != 15) return error.AtomicFetchSubPrevFailed;
    const after2 = v.load(.seq_cst);
    if (after2 != 12) return error.AtomicFetchSubFailed;
    log.info("fetchSub ok prev={} after={}", .{ prev2, after2 });

    const swapped = v.cmpxchgStrong(12, 99, .seq_cst, .seq_cst);
    if (swapped != null) return error.CmpxchgShouldSucceed;
    if (v.load(.seq_cst) != 99) return error.CmpxchgValueWrong;
    log.info("cmpxchgStrong ok val={}", .{v.load(.seq_cst)});

    const failed = v.cmpxchgStrong(0, 1, .seq_cst, .seq_cst);
    if (failed == null) return error.CmpxchgShouldFail;
    if (failed.? != 99) return error.CmpxchgReturnWrong;
    log.info("cmpxchgStrong fail ok returned={}", .{failed.?});

    const old = v.swap(77, .seq_cst);
    if (old != 99) return error.SwapOldWrong;
    if (v.load(.seq_cst) != 77) return error.SwapNewWrong;
    log.info("swap ok old={} new={}", .{ old, v.load(.seq_cst) });

    log.info("atomic done", .{});
}
