//! Channel 行为一致性测试运行器
//!
//! 本文件接受一个已经构造好的 Channel 类型工厂（通过 comptime 参数传入），
//! 内部直接经由 `(u32)` 实例化测试对象，
//! 运行全部测试，验证其行为与 Go channel 语义一致。
//!
//! 注意：本 runner 只使用 channel contract 暴露的 API（init/deinit/send/recv/recvTimeout/close），
//! 不依赖 trySend/tryRecv/readFd/writeFd 等 impl 特有方法。
//! 那些 impl 特有的行为（如 readiness/selector 可观测性）应在 impl 自己的测试中覆盖。
//!
//! 用法示例：
//! ```
//! const runner = @import("sync/test_runner/integration/channel.zig").make(lib, @import("sync").Channel(lib, platform.ChannelFactory));
//! t.run("sync/channel", runner);
//! ```
//!
//! 各子 case 在 `channel/*.zig` 中各自 `TestRunner.make`，栈宽由 `spawn_config` 固定；
//! 用例实现集中在 `channel/suite.zig`。
//!
//! 以下是当前 runner 覆盖的测试要点清单：
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  〇、无缓冲 channel（capacity=0）— Go rendezvous 语义
//! ═══════════════════════════════════════════════════════════
//!
//!  U1. capacity=0 时允许创建 channel（unbuffered）
//!  U2. unbuffered send 阻塞直到有 receiver 取走
//!  U3. unbuffered recv 阻塞直到有 sender 提供
//!  U4. unbuffered 握手后值正确传递
//!  U5. unbuffered 多轮 send/recv 握手不死锁
//!  U6. unbuffered close 唤醒阻塞的 recv，返回 ok=false
//!  U7. unbuffered close 唤醒阻塞的 send，返回 ok=false
//!  U8. unbuffered close 后 send 返回 ok=false
//!  U9. unbuffered close 后 recv 返回 ok=false
//!  U10. unbuffered SPSC 并发不丢消息
//!  U11. unbuffered MPSC 并发不丢消息
//!  U12. unbuffered deinit 无泄漏
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  一、初始化与基本属性
//! ═══════════════════════════════════════════════════════════
//!
//!  1. capacity=1 时允许创建 channel（单槽位缓冲）
//!  2. capacity>1 时允许创建 channel（多槽位缓冲，如 64, 1024）
//!  3. 新建有缓冲 channel 的初始状态正确：
//!     send 后可 recv，值一致
//!  4. deinit 后资源释放干净（allocator 无泄漏）
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  二、发送与接收的基本语义
//! ═══════════════════════════════════════════════════════════
//!
//!  5.  单个元素 send 后可被 recv 读出，ok=true，值与写入一致
//!  6.  多个元素发送后按 FIFO 顺序读取，严格先进先出
//!  7.  环形缓冲区绕回后仍保持 FIFO：
//!      head/tail 指针绕回不影响顺序
//!  8.  发送和接收交替进行时状态正确：
//!      长度、顺序一致
//!  9.  recv 在有数据时返回 ok=true，拿到正确值
//!  10. send 在有空位时返回 ok=true
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  三、有缓冲 channel 缓冲区边界
//! ═══════════════════════════════════════════════════════════
//!
//!  11. 缓冲区未满时 send 立即返回 ok=true，不阻塞
//!  12. 恰好填满缓冲区（send capacity 次）后，所有 send 都返回 ok=true
//!  13. 缓冲区满时 send 阻塞：
//!      启动 send 线程，短暂等待后确认它仍未返回
//!  14. 缓冲区满后，另一线程 recv 取走一个值，阻塞的 send 被唤醒并成功写入
//!  15. 缓冲区为空时 recv 阻塞：
//!      启动 recv 线程，短暂等待后确认它仍未返回
//!  16. 缓冲区为空后，另一线程 send 写入一个值，阻塞的 recv 被唤醒并拿到值
//!  17. capacity=1 时行为正确：
//!      send 一个后满，再 send 阻塞；recv 后腾出空位
//!  18. ring buffer 回绕：
//!      send/recv 交替超过 capacity 次，head/tail 正确回绕，数据不错乱
//!  19. 填满再全部读空后再次填满排空，token 数量一致，不丢不多
//!  20. 同一个 channel 反复填满-排空多轮，行为始终正确，状态不残留
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  四、close 的 Go 语义
//! ═══════════════════════════════════════════════════════════
//!
//! Go 语义里 close 后 send 是 panic，double close 也是 panic。
//! 本 contract 只约束 send after close 返回 ok=false，因此这里锁定的是
//! send/recv after close 的可观测语义；double close 不属于当前 runner 的断言范围。
//!
//!  21. close 一个未关闭 channel 成功，channel 进入 closed 状态
//!  22. close 后 send 返回 ok=false，不能静默成功
//!  23. close 后多次 send 均返回 ok=false（幂等）
//!  24. close 后，缓冲中已有的数据仍然可以按 FIFO 继续读完（ok=true）
//!  25. close 后，缓冲耗尽时 recv 返回 ok=false，不再阻塞，不再返回旧值
//!  26. close 后对空 closed channel 连续多次 recv 都返回 ok=false（行为稳定）
//!  27. close 后 send+recv 排空完整流程：先 send 若干 -> close -> recv 全部 -> ok=false
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  五、阻塞路径与唤醒
//! ═══════════════════════════════════════════════════════════
//!
//!  28. 空 channel 上阻塞 recv，当有发送到来时被正确唤醒，收到值 ok=true
//!  29. 满缓冲 channel 上阻塞 send，当有接收到来时被正确唤醒，发送成功
//!  30. 空 channel 上阻塞 recv，close 后必须被唤醒，返回 ok=false，不能永久卡死
//!  31. 满缓冲 channel 上阻塞 send，close 后必须被唤醒，返回 ok=false
//!  32. close 唤醒所有（多个）阻塞在 recv 上的线程，它们都拿到 ok=false
//!  33. close 唤醒所有（多个）阻塞在 send 上的线程，它们都拿到 ok=false
//!  34. 交替 send/recv 大量轮次（≥10000），不死锁、不丢数据
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  六、并发正确性
//! ═══════════════════════════════════════════════════════════
//!
//!  35. 单生产者单消费者并发下不丢消息，发送数量与接收数量一致
//!  36. 多生产者单消费者并发下不丢消息，总数正确，无覆盖
//!  37. 单生产者多消费者并发下不重复投递，每个元素只被一个消费者拿到一次
//!  38. 多生产者多消费者并发下保持数据完整性：无重复、无丢失、无越界、无死锁
//!  39. 并发 close 与 recv 竞态：已有数据可读完，之后 ok=false
//!  40. 并发 close 与 send 竞态：send 返回 ok=true 或 ok=false，不能静默丢失
//!  41. 高并发压力：M 个生产者 × K 个消费者并发跑，验证无 race、无 panic
//!
//!
//! ═══════════════════════════════════════════════════════════
//!  七、资源安全
//! ═══════════════════════════════════════════════════════════
//!
//!  说明：这些 case 主要覆盖常见 close/deinit 生命周期不会 panic 或 hang，
//!  并在默认测试分配器下不留下明显 allocator 泄漏；它们不是独立的 leak detector。
//!
//!  42. 正常 send/recv/deinit 路径可正常收尾
//!  43. 带未消费缓冲数据直接 deinit 可正常收尾
//!  44. close 后 deinit 可正常收尾
//!  45. 快速连续 close + recv 不 panic、不 hang
//!  46. 快速连续 close + send 不 panic、不 hang

const stdz = @import("stdz");
const testing_api = @import("testing");

// 无缓冲 channel（U1–U12）
const unbuffered_init = @import("channel/unbuffered_init.zig");
const unbuffered_rendezvous = @import("channel/unbuffered_rendezvous.zig");
const unbuffered_send_blocks = @import("channel/unbuffered_send_blocks.zig");
const unbuffered_recv_blocks = @import("channel/unbuffered_recv_blocks.zig");
const unbuffered_multi_round = @import("channel/unbuffered_multi_round.zig");
const unbuffered_close_wakes_recv = @import("channel/unbuffered_close_wakes_recv.zig");
const unbuffered_close_wakes_send = @import("channel/unbuffered_close_wakes_send.zig");
const unbuffered_send_after_close = @import("channel/unbuffered_send_after_close.zig");
const unbuffered_recv_after_close = @import("channel/unbuffered_recv_after_close.zig");
const unbuffered_spsc = @import("channel/unbuffered_spsc.zig");
const unbuffered_mpsc = @import("channel/unbuffered_mpsc.zig");
const unbuffered_deinit = @import("channel/unbuffered_deinit.zig");

// 初始化与基本属性（#1–#4）
const init_buffered = @import("channel/init_buffered.zig");
const initial_state_buffered = @import("channel/initial_state_buffered.zig");
const deinit_clean = @import("channel/deinit_clean.zig");

// 发送与接收基本语义（#5–#10）
const send_recv_single = @import("channel/send_recv_single.zig");
const fifo_order = @import("channel/fifo_order.zig");
const ring_wrap = @import("channel/ring_wrap.zig");
const send_recv_interleaved = @import("channel/send_recv_interleaved.zig");
const recv_returns_correct_value = @import("channel/recv_returns_correct_value.zig");
const send_returns_ok = @import("channel/send_returns_ok.zig");

// 有缓冲边界（#11–#20）
const buffered_send_immediate = @import("channel/buffered_send_immediate.zig");
const fill_buffer_exactly = @import("channel/fill_buffer_exactly.zig");
const capacity_one = @import("channel/capacity_one.zig");
const ring_wrap_extended = @import("channel/ring_wrap_extended.zig");
const fill_drain_token_balance = @import("channel/fill_drain_token_balance.zig");
const multi_round_fill_drain = @import("channel/multi_round_fill_drain.zig");

// close 语义（#21–#27）
const close_success = @import("channel/close_success.zig");
const send_after_close = @import("channel/send_after_close.zig");
const multi_send_after_close = @import("channel/multi_send_after_close.zig");
const close_flush_buffered_data = @import("channel/close_flush_buffered_data.zig");
const recv_after_close_empty = @import("channel/recv_after_close_empty.zig");
const multi_recv_after_close = @import("channel/multi_recv_after_close.zig");
const close_flush_full_flow = @import("channel/close_flush_full_flow.zig");

// 资源安全（#42–#44）
const resource_safety_normal = @import("channel/resource_safety_normal.zig");
const resource_safety_unconsumed = @import("channel/resource_safety_unconsumed.zig");
const resource_safety_close_and_deinit = @import("channel/resource_safety_close_and_deinit.zig");

// 阻塞与唤醒：满/空槽、sendTimeout/recvTimeout、单侧 close 唤醒（#13–#16、#28–#31）
const send_blocks_when_full = @import("channel/send_blocks_when_full.zig");
const recv_unblocks_send = @import("channel/recv_unblocks_send.zig");
const recv_blocks_when_empty = @import("channel/recv_blocks_when_empty.zig");
const send_unblocks_recv = @import("channel/send_unblocks_recv.zig");
const recv_woken_by_send = @import("channel/recv_woken_by_send.zig");
const send_woken_by_recv = @import("channel/send_woken_by_recv.zig");
const send_timeout_contract = @import("channel/send_timeout_contract.zig");
const recv_timeout_contract = @import("channel/recv_timeout_contract.zig");
const recv_woken_by_close = @import("channel/recv_woken_by_close.zig");
const send_woken_by_close = @import("channel/send_woken_by_close.zig");

// 多线程 close 唤醒；高吞吐交替（#32–#34）
const close_wakes_multi_recv = @import("channel/close_wakes_multi_recv.zig");
const close_wakes_multi_send = @import("channel/close_wakes_multi_send.zig");
const high_throughput_no_deadlock = @import("channel/high_throughput_no_deadlock.zig");

// 并发正确性：SPSC / MPSC / SPMC / MPMC（#35–#38）
const spsc_no_drop = @import("channel/spsc_no_drop.zig");
const mpsc_no_drop = @import("channel/mpsc_no_drop.zig");
const spmc_no_duplicate = @import("channel/spmc_no_duplicate.zig");
const mpmc_integrity = @import("channel/mpmc_integrity.zig");

// 并发 close 与 recv/send（#39–#40）
const concurrent_close_recv = @import("channel/concurrent_close_recv.zig");
const concurrent_close_send = @import("channel/concurrent_close_send.zig");

// 快速 close + recv/send（#45–#46）
const rapid_close_recv = @import("channel/rapid_close_recv.zig");
const rapid_close_send = @import("channel/rapid_close_send.zig");

// 有缓冲：数据读尽后多余接收者（空缓冲 wakeup token）
const buffered_recv_empty_after_drain = @import("channel/buffered_recv_empty_after_drain.zig");

pub fn make(comptime lib: type, comptime Channel: fn (type) type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: stdz.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.parallel();
            t.run("unbufferedInit", unbuffered_init.make(lib, Channel));
            t.run("unbufferedRendezvous", unbuffered_rendezvous.make(lib, Channel));
            t.run("unbufferedSendBlocks", unbuffered_send_blocks.make(lib, Channel));
            t.run("unbufferedRecvBlocks", unbuffered_recv_blocks.make(lib, Channel));
            t.run("unbufferedMultiRound", unbuffered_multi_round.make(lib, Channel));
            t.run("unbufferedCloseWakesRecv", unbuffered_close_wakes_recv.make(lib, Channel));
            t.run("unbufferedCloseWakesSend", unbuffered_close_wakes_send.make(lib, Channel));
            t.run("unbufferedSendAfterClose", unbuffered_send_after_close.make(lib, Channel));
            t.run("unbufferedRecvAfterClose", unbuffered_recv_after_close.make(lib, Channel));
            t.run("unbufferedSpsc", unbuffered_spsc.make(lib, Channel));
            t.run("unbufferedMpsc", unbuffered_mpsc.make(lib, Channel));
            t.run("unbufferedDeinit", unbuffered_deinit.make(lib, Channel));
            t.run("initBuffered", init_buffered.make(lib, Channel));
            t.run("initialStateBuffered", initial_state_buffered.make(lib, Channel));
            t.run("deinitClean", deinit_clean.make(lib, Channel));
            t.run("sendRecvSingle", send_recv_single.make(lib, Channel));
            t.run("fifoOrder", fifo_order.make(lib, Channel));
            t.run("ringWrap", ring_wrap.make(lib, Channel));
            t.run("sendRecvInterleaved", send_recv_interleaved.make(lib, Channel));
            t.run("recvReturnsCorrectValue", recv_returns_correct_value.make(lib, Channel));
            t.run("sendReturnsOk", send_returns_ok.make(lib, Channel));
            t.run("bufferedSendImmediate", buffered_send_immediate.make(lib, Channel));
            t.run("fillBufferExactly", fill_buffer_exactly.make(lib, Channel));
            t.run("capacityOne", capacity_one.make(lib, Channel));
            t.run("ringWrapExtended", ring_wrap_extended.make(lib, Channel));
            t.run("fillDrainTokenBalance", fill_drain_token_balance.make(lib, Channel));
            t.run("multiRoundFillDrain", multi_round_fill_drain.make(lib, Channel));
            t.run("closeSuccess", close_success.make(lib, Channel));
            t.run("sendAfterClose", send_after_close.make(lib, Channel));
            t.run("multiSendAfterClose", multi_send_after_close.make(lib, Channel));
            t.run("closeFlushBufferedData", close_flush_buffered_data.make(lib, Channel));
            t.run("recvAfterCloseEmpty", recv_after_close_empty.make(lib, Channel));
            t.run("multiRecvAfterClose", multi_recv_after_close.make(lib, Channel));
            t.run("closeFlushFullFlow", close_flush_full_flow.make(lib, Channel));
            t.run("resourceSafetyNormal", resource_safety_normal.make(lib, Channel));
            t.run("resourceSafetyUnconsumed", resource_safety_unconsumed.make(lib, Channel));
            t.run("resourceSafetyCloseAndDeinit", resource_safety_close_and_deinit.make(lib, Channel));
            t.run("sendBlocksWhenFull", send_blocks_when_full.make(lib, Channel));
            t.run("recvUnblocksSend", recv_unblocks_send.make(lib, Channel));
            t.run("recvBlocksWhenEmpty", recv_blocks_when_empty.make(lib, Channel));
            t.run("sendUnblocksRecv", send_unblocks_recv.make(lib, Channel));
            t.run("recvWokenBySend", recv_woken_by_send.make(lib, Channel));
            t.run("sendWokenByRecv", send_woken_by_recv.make(lib, Channel));
            t.run("sendTimeoutContract", send_timeout_contract.make(lib, Channel));
            t.run("recvTimeoutContract", recv_timeout_contract.make(lib, Channel));
            t.run("recvWokenByClose", recv_woken_by_close.make(lib, Channel));
            t.run("sendWokenByClose", send_woken_by_close.make(lib, Channel));
            t.run("closeWakesMultiRecv", close_wakes_multi_recv.make(lib, Channel));
            t.run("closeWakesMultiSend", close_wakes_multi_send.make(lib, Channel));
            t.run("highThroughputNoDeadlock", high_throughput_no_deadlock.make(lib, Channel));
            t.run("spscNoDrop", spsc_no_drop.make(lib, Channel));
            t.run("mpscNoDrop", mpsc_no_drop.make(lib, Channel));
            t.run("spmcNoDuplicate", spmc_no_duplicate.make(lib, Channel));
            t.run("mpmcIntegrity", mpmc_integrity.make(lib, Channel));
            t.run("concurrentCloseRecv", concurrent_close_recv.make(lib, Channel));
            t.run("concurrentCloseSend", concurrent_close_send.make(lib, Channel));
            t.run("rapidCloseRecv", rapid_close_recv.make(lib, Channel));
            t.run("rapidCloseSend", rapid_close_send.make(lib, Channel));
            t.run("bufferedRecvEmptyAfterDrain", buffered_recv_empty_after_drain.make(lib, Channel));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}
