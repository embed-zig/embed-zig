//! ble — CoreBluetooth wrapper for macOS BLE Central operations.
//!
//! Provides scan, connect, service/char discovery, write, and notify
//! subscribe using Apple's CoreBluetooth framework via ObjC runtime.
//!
//! Implements the xfer Transport interface (`send`/`recv`) so it can
//! be used directly with ReadX/WriteX.

const std = @import("std");
const objc = @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
    @cInclude("CoreFoundation/CoreFoundation.h");
});

// ============================================================================
// ObjC Runtime Helpers
// ============================================================================

const id = ?*anyopaque;
const SEL = objc.SEL;
const Class = objc.Class;

fn cls(name: [*:0]const u8) Class {
    return objc.objc_getClass(name);
}

fn s(name: [*:0]const u8) SEL {
    return objc.sel_registerName(name);
}

fn msg0(target: id, selector: SEL) id {
    const f: *const fn (id, SEL) callconv(.c) id = @ptrCast(&objc.objc_msgSend);
    return f(target, selector);
}

fn msg1(target: id, selector: SEL, a1: id) id {
    const f: *const fn (id, SEL, id) callconv(.c) id = @ptrCast(&objc.objc_msgSend);
    return f(target, selector, a1);
}

fn msg2(target: id, selector: SEL, a1: id, a2: id) id {
    const f: *const fn (id, SEL, id, id) callconv(.c) id = @ptrCast(&objc.objc_msgSend);
    return f(target, selector, a1, a2);
}

fn msgInt(target: id, selector: SEL) i64 {
    const f: *const fn (id, SEL) callconv(.c) i64 = @ptrCast(&objc.objc_msgSend);
    return f(target, selector);
}

fn msgUsize(target: id, selector: SEL, val: usize) id {
    const f: *const fn (id, SEL, usize) callconv(.c) id = @ptrCast(&objc.objc_msgSend);
    return f(target, selector, val);
}

fn msgDouble(target: id, selector: SEL, val: f64) id {
    const f: *const fn (id, SEL, f64) callconv(.c) id = @ptrCast(&objc.objc_msgSend);
    return f(target, selector, val);
}

fn nsStringToSlice(nsstr: id, buf: []u8) []const u8 {
    if (nsstr == null) return "";
    const cstr: ?[*:0]const u8 = @ptrCast(msgUsize(nsstr, s("cStringUsingEncoding:"), 4));
    if (cstr) |p| {
        const len = std.mem.len(p);
        const n = @min(len, buf.len);
        @memcpy(buf[0..n], p[0..n]);
        return buf[0..n];
    }
    return "";
}

fn cfStr(comptime literal: [*:0]const u8) id {
    return @ptrCast(@constCast(objc.__CFStringMakeConstantString(literal)));
}

extern fn dispatch_queue_create(label: [*:0]const u8, attr: ?*anyopaque) ?*anyopaque;

// ============================================================================
// CBUUID helpers
// ============================================================================

pub const TERM_SERVICE_UUID: u16 = 0xFFE0;
pub const TERM_CHAR_UUID: u16 = 0xFFE1;

// ============================================================================
// BleTransport — xfer Transport over CoreBluetooth
// ============================================================================

pub const BleTransport = struct {
    const QUEUE_SLOTS = 64;
    const SLOT_SIZE = 520;

    const Slot = struct {
        data: [SLOT_SIZE]u8 = undefined,
        len: usize = 0,
    };

    peripheral: ?*anyopaque = null,
    characteristic: ?*anyopaque = null,

    queue: [QUEUE_SLOTS]Slot = [_]Slot{.{}} ** QUEUE_SLOTS,
    head: usize = 0,
    tail: usize = 0,
    len: usize = 0,
    closed: bool = false,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},

    pub fn init() BleTransport {
        return .{};
    }

    pub fn deinit(_: *BleTransport) void {}

    pub fn send(self: *BleTransport, data: []const u8) anyerror!void {
        const periph = self.peripheral orelse return error.NotConnected;
        const chr = self.characteristic orelse return error.NotConnected;

        // Create NSData from the slice
        const nsdata_cls = cls("NSData");
        const msgPtrLen: *const fn (id, SEL, [*]const u8, usize) callconv(.c) id =
            @ptrCast(&objc.objc_msgSend);
        const nsdata = msgPtrLen(
            @ptrCast(nsdata_cls),
            s("dataWithBytes:length:"),
            data.ptr,
            data.len,
        );
        if (nsdata == null) return error.SendFailed;

        // writeValue:forCharacteristic:type: (type 0 = with response)
        const msgWrite: *const fn (id, SEL, id, id, i64) callconv(.c) void =
            @ptrCast(&objc.objc_msgSend);
        msgWrite(periph, s("writeValue:forCharacteristic:type:"), nsdata, chr, 0);
    }

    pub fn recv(self: *BleTransport, buf: []u8, timeout_ms: u32) anyerror!?usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.len == 0 and !self.closed) {
            self.cond.timedWait(&self.mutex, @as(u64, timeout_ms) * 1_000_000) catch {
                if (self.len == 0) return null;
            };
        }

        if (self.len == 0) {
            if (self.closed) return error.Closed;
            return null;
        }

        const slot = &self.queue[self.tail];
        const n = @min(slot.len, buf.len);
        @memcpy(buf[0..n], slot.data[0..n]);
        self.tail = (self.tail + 1) % QUEUE_SLOTS;
        self.len -= 1;
        return n;
    }

    pub fn pushNotify(self: *BleTransport, data: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.len >= QUEUE_SLOTS) return;

        var slot = &self.queue[self.head];
        const n = @min(data.len, SLOT_SIZE);
        @memcpy(slot.data[0..n], data[0..n]);
        slot.len = n;
        self.head = (self.head + 1) % QUEUE_SLOTS;
        self.len += 1;
        self.cond.signal();
    }

    pub fn close(self: *BleTransport) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        self.cond.broadcast();
    }
};

// ============================================================================
// Scanner — CoreBluetooth BLE scan via ObjC runtime
// ============================================================================

pub const ScanResult = struct {
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    uuid: [37]u8 = [_]u8{0} ** 37,
    uuid_len: usize = 0,
    rssi: i8 = 0,

    pub fn nameSlice(self: *const ScanResult) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn uuidSlice(self: *const ScanResult) []const u8 {
        return self.uuid[0..self.uuid_len];
    }
};

pub const Scanner = struct {
    const MAX_RESULTS = 32;

    results: [MAX_RESULTS]ScanResult = [_]ScanResult{.{}} ** MAX_RESULTS,
    count: usize = 0,
    powered_on: bool = false,
    central: id = null,

    pub fn init() Scanner {
        return .{};
    }

    /// Scan for BLE peripherals advertising the term service UUID.
    /// Blocks for `duration_ms` milliseconds, pumping the CFRunLoop.
    var active_scanner: ?*Scanner = null;

    pub fn scan(self: *Scanner, duration_ms: u32) void {
        active_scanner = self;
        defer active_scanner = null;

        const delegate_cls = registerDelegateClass() orelse return;
        const delegate = msg0(msg0(@ptrCast(delegate_cls), s("alloc")), s("init"));
        if (delegate == null) return;

        const queue = dispatch_queue_create("com.bleterm.ble", null);
        self.central = msg2(
            msg0(@ptrCast(cls("CBCentralManager")), s("alloc")),
            s("initWithDelegate:queue:"),
            delegate,
            @ptrCast(queue),
        );
        if (self.central == null) return;

        // Wait for BLE to power on (up to 3 seconds)
        var wait_ms: u32 = 0;
        while (!self.powered_on and wait_ms < 3000) : (wait_ms += 100) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
        if (!self.powered_on) return;

        // Scan for the requested duration
        std.Thread.sleep(@as(u64, duration_ms) * std.time.ns_per_ms);

        _ = msg0(self.central, s("stopScan"));
    }

    fn registerDelegateClass() ?Class {
        const class_name = "BLETermScanDelegate";
        const existing = cls(class_name);
        if (existing != null) return existing;

        const superclass = cls("NSObject");
        if (superclass == null) return null;

        const new_cls = objc.objc_allocateClassPair(superclass, class_name, 0);
        if (new_cls == null) return null;

        _ = objc.class_addMethod(
            new_cls,
            s("centralManagerDidUpdateState:"),
            @as(objc.IMP, @ptrCast(&cbDidUpdateState)),
            "v@:@",
        );
        _ = objc.class_addMethod(
            new_cls,
            s("centralManager:didDiscoverPeripheral:advertisementData:RSSI:"),
            @as(objc.IMP, @ptrCast(&cbDidDiscover)),
            "v@:@@@@",
        );

        const protocol = objc.objc_getProtocol("CBCentralManagerDelegate");
        if (protocol != null) {
            _ = objc.class_addProtocol(new_cls, protocol);
        }

        objc.objc_registerClassPair(new_cls);
        return new_cls;
    }

    fn cbDidUpdateState(self_delegate: id, _sel: SEL, central: id) callconv(.c) void {
        _ = _sel;
        _ = self_delegate;
        const scanner = active_scanner orelse return;

        const state = msgInt(central, s("state"));
        if (state == 5) { // CBManagerStatePoweredOn
            scanner.powered_on = true;
            startScanning(central);
        }
    }

    fn startScanning(central: id) void {
        // Scan for all peripherals (no service UUID filter)
        // to maximize discovery. Filter results in cbDidDiscover.
        const scan_sel = s("scanForPeripheralsWithServices:options:");
        const f: *const fn (id, SEL, id, id) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
        f(central, scan_sel, null, null);
    }

    fn cbDidDiscover(
        self_delegate: id,
        _sel: SEL,
        central: id,
        peripheral: id,
        adv_data: id,
        rssi_number: id,
    ) callconv(.c) void {
        _ = _sel;
        _ = central;
        _ = adv_data;

        _ = self_delegate;
        const scanner = active_scanner orelse return;
        if (scanner.count >= MAX_RESULTS) return;

        var result = ScanResult{};

        // Get peripheral name
        const name_ns = msg0(peripheral, s("name"));
        if (name_ns != null) {
            const slice = nsStringToSlice(name_ns, &result.name);
            result.name_len = slice.len;
        }

        // Get peripheral UUID string
        const identifier = msg0(peripheral, s("identifier"));
        if (identifier != null) {
            const uuid_str = msg0(identifier, s("UUIDString"));
            if (uuid_str != null) {
                const slice = nsStringToSlice(uuid_str, &result.uuid);
                result.uuid_len = slice.len;
            }
        }

        // Get RSSI
        if (rssi_number != null) {
            const rssi_val = msgInt(rssi_number, s("integerValue"));
            result.rssi = @as(i8, @intCast(std.math.clamp(rssi_val, -128, 0)));
        }

        // Deduplicate by UUID
        for (scanner.results[0..scanner.count]) |*existing| {
            if (existing.uuid_len == result.uuid_len and
                std.mem.eql(u8, existing.uuid[0..existing.uuid_len], result.uuid[0..result.uuid_len]))
            {
                existing.rssi = result.rssi;
                if (result.name_len > 0) {
                    @memcpy(existing.name[0..result.name_len], result.name[0..result.name_len]);
                    existing.name_len = result.name_len;
                }
                return;
            }
        }

        scanner.results[scanner.count] = result;
        scanner.count += 1;
    }
};

// ============================================================================
// Connection — CoreBluetooth Central connect + service/char discovery
// ============================================================================

pub const Connection = struct {
    transport: BleTransport = BleTransport.init(),
    connected: bool = false,
    mtu: u16 = 20,

    central: id = null,
    peripheral: id = null,
    characteristic: id = null,
    queue: ?*anyopaque = null,

    // State machine flags (set by delegate callbacks on the dispatch queue)
    powered_on: bool = false,
    peripheral_found: bool = false,
    conn_done: bool = false,
    svc_done: bool = false,
    chr_done: bool = false,
    notify_done: bool = false,
    failed: bool = false,

    // Target for scan-then-connect
    target_name: [64]u8 = undefined,
    target_name_len: usize = 0,
    target_uuid: [37]u8 = undefined,
    target_uuid_len: usize = 0,

    var active_conn: ?*Connection = null;

    pub fn init() Connection {
        return .{};
    }

    pub fn connect(self: *Connection, uuid: []const u8) !void {
        self.target_uuid_len = @min(uuid.len, self.target_uuid.len);
        @memcpy(self.target_uuid[0..self.target_uuid_len], uuid[0..self.target_uuid_len]);
        self.target_name_len = 0;
        try self.doConnect();
    }

    pub fn connectByName(self: *Connection, name_prefix: []const u8) !void {
        self.target_name_len = @min(name_prefix.len, self.target_name.len);
        @memcpy(self.target_name[0..self.target_name_len], name_prefix[0..self.target_name_len]);
        self.target_uuid_len = 0;
        try self.doConnect();
    }

    pub fn disconnect(self: *Connection) void {
        if (self.central != null and self.peripheral != null) {
            _ = msg1(self.central, s("cancelPeripheralConnection:"), self.peripheral);
        }
        self.transport.close();
        self.connected = false;
        active_conn = null;
    }

    fn dbg(comptime fmt: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        std.fs.File.stderr().writeAll(msg) catch {};
    }

    fn doConnect(self: *Connection) !void {
        active_conn = self;

        const delegate_cls = registerConnDelegateClass() orelse return error.InitFailed;
        const delegate = msg0(msg0(@ptrCast(delegate_cls), s("alloc")), s("init"));
        if (delegate == null) return error.InitFailed;

        self.queue = dispatch_queue_create("com.bleterm.conn", null);
        self.central = msg2(
            msg0(@ptrCast(cls("CBCentralManager")), s("alloc")),
            s("initWithDelegate:queue:"),
            delegate,
            @ptrCast(self.queue),
        );
        if (self.central == null) return error.InitFailed;

        dbg("[ble] waiting for power on...\n", .{});

        if (!waitFor(&self.powered_on, &self.failed, 3000)) return error.NotPoweredOn;

        dbg("[ble] powered on, scanning...\n", .{});

        const scan_f: *const fn (id, SEL, id, id) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
        scan_f(self.central, s("scanForPeripheralsWithServices:options:"), null, null);

        if (!waitFor(&self.peripheral_found, &self.failed, 10000)) {
            dbg("[ble] scan timeout — device not found\n", .{});
            return error.ConnectionTimeout;
        }

        dbg("[ble] peripheral found, connecting...\n", .{});

        const connect_f: *const fn (id, SEL, id, id) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
        connect_f(self.central, s("connectPeripheral:options:"), self.peripheral, null);

        if (!waitFor(&self.conn_done, &self.failed, 10000)) {
            dbg("[ble] connection timeout\n", .{});
            return error.ConnectionTimeout;
        }

        dbg("[ble] connected, discovering services...\n", .{});

        if (!waitFor(&self.svc_done, &self.failed, 5000)) return error.ServiceNotFound;

        dbg("[ble] service found, discovering chars...\n", .{});

        if (!waitFor(&self.chr_done, &self.failed, 5000)) return error.CharNotFound;

        dbg("[ble] char found, subscribing...\n", .{});

        if (!waitFor(&self.notify_done, &self.failed, 3000)) return error.NotifyFailed;

        // maximumWriteValueLengthForType: takes NSInteger (0 = withResponse)
        const mtu_val = msgInt(self.peripheral, s("maximumWriteValueLengthForType:"));
        if (mtu_val > 0 and mtu_val < 65535) {
            self.mtu = @intCast(mtu_val);
        }

        self.transport.peripheral = self.peripheral;
        self.transport.characteristic = self.characteristic;
        self.connected = true;

        dbg("[ble] ready (mtu={})\n", .{self.mtu});
    }

    fn waitFor(flag: *bool, fail: *bool, timeout_ms: u32) bool {
        var waited: u32 = 0;
        while (!flag.* and !fail.* and waited < timeout_ms) : (waited += 10) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        return flag.* and !fail.*;
    }

    // ================================================================
    // Delegate class registration
    // ================================================================

    fn registerConnDelegateClass() ?Class {
        const class_name = "BLETermConnDelegate";
        const existing = cls(class_name);
        if (existing != null) return existing;

        const superclass = cls("NSObject");
        if (superclass == null) return null;

        const new_cls = objc.objc_allocateClassPair(superclass, class_name, 0);
        if (new_cls == null) return null;

        // CBCentralManagerDelegate — register both old and modern selector names
        _ = objc.class_addMethod(new_cls, s("centralManagerDidUpdateState:"), @as(objc.IMP, @ptrCast(&connDidUpdateState)), "v@:@");
        _ = objc.class_addMethod(new_cls, s("centralManager:didDiscoverPeripheral:advertisementData:RSSI:"), @as(objc.IMP, @ptrCast(&connDidDiscover)), "v@:@@@@");
        _ = objc.class_addMethod(new_cls, s("centralManager:didConnectPeripheral:"), @as(objc.IMP, @ptrCast(&connDidConnect)), "v@:@@");
        _ = objc.class_addMethod(new_cls, s("centralManager:didConnect:"), @as(objc.IMP, @ptrCast(&connDidConnect)), "v@:@@");
        _ = objc.class_addMethod(new_cls, s("centralManager:didFailToConnectPeripheral:error:"), @as(objc.IMP, @ptrCast(&connDidFailConnect)), "v@:@@@");
        _ = objc.class_addMethod(new_cls, s("centralManager:didFailToConnect:error:"), @as(objc.IMP, @ptrCast(&connDidFailConnect)), "v@:@@@");
        _ = objc.class_addMethod(new_cls, s("centralManager:didDisconnectPeripheral:error:"), @as(objc.IMP, @ptrCast(&connDidDisconnect)), "v@:@@@");

        // CBPeripheralDelegate
        _ = objc.class_addMethod(new_cls, s("peripheral:didDiscoverServices:"), @as(objc.IMP, @ptrCast(&connDidDiscoverServices)), "v@:@@");
        _ = objc.class_addMethod(new_cls, s("peripheral:didDiscoverCharacteristicsForService:error:"), @as(objc.IMP, @ptrCast(&connDidDiscoverChars)), "v@:@@@");
        _ = objc.class_addMethod(new_cls, s("peripheral:didUpdateNotificationStateForCharacteristic:error:"), @as(objc.IMP, @ptrCast(&connDidUpdateNotify)), "v@:@@@");
        _ = objc.class_addMethod(new_cls, s("peripheral:didUpdateValueForCharacteristic:error:"), @as(objc.IMP, @ptrCast(&connDidUpdateValue)), "v@:@@@");

        for ([_][*:0]const u8{ "CBCentralManagerDelegate", "CBPeripheralDelegate" }) |proto_name| {
            const proto = objc.objc_getProtocol(proto_name);
            if (proto != null) _ = objc.class_addProtocol(new_cls, proto);
        }

        objc.objc_registerClassPair(new_cls);
        return new_cls;
    }

    // ================================================================
    // CBCentralManagerDelegate callbacks
    // ================================================================

    fn connDidUpdateState(_d: id, _s: SEL, central: id) callconv(.c) void {
        _ = _d;
        _ = _s;
        const conn = active_conn orelse return;
        if (msgInt(central, s("state")) == 5) conn.powered_on = true;
    }

    fn connDidDiscover(_d: id, _s: SEL, _central: id, peripheral: id, _adv: id, _rssi: id) callconv(.c) void {
        _ = _d;
        _ = _s;
        _ = _central;
        _ = _adv;
        _ = _rssi;
        const conn = active_conn orelse return;
        if (conn.peripheral != null) return;

        var match = false;

        if (conn.target_name_len > 0) {
            const name_ns = msg0(peripheral, s("name"));
            if (name_ns != null) {
                var name_buf: [64]u8 = undefined;
                const name = nsStringToSlice(name_ns, &name_buf);
                if (name.len > 0) {
                    dbg("[ble] discovered: {s}\n", .{name});
                }
                if (name.len >= conn.target_name_len and
                    std.mem.eql(u8, name[0..conn.target_name_len], conn.target_name[0..conn.target_name_len]))
                {
                    match = true;
                }
            }
        } else if (conn.target_uuid_len > 0) {
            const ident = msg0(peripheral, s("identifier"));
            if (ident != null) {
                const uuid_ns = msg0(ident, s("UUIDString"));
                if (uuid_ns != null) {
                    var uuid_buf: [37]u8 = undefined;
                    const uuid = nsStringToSlice(uuid_ns, &uuid_buf);
                    if (std.mem.eql(u8, uuid[0..@min(uuid.len, conn.target_uuid_len)], conn.target_uuid[0..conn.target_uuid_len])) {
                        match = true;
                    }
                }
            }
        }

        if (match) {
            _ = msg0(peripheral, s("retain"));
            conn.peripheral = peripheral;
            conn.peripheral_found = true;
            _ = msg0(conn.central, s("stopScan"));
            dbg("[ble] found target\n", .{});
        }
    }

    fn connDidConnect(_d: id, _s: SEL, _central: id, peripheral: id) callconv(.c) void {
        _ = _d;
        _ = _s;
        _ = _central;
        const conn = active_conn orelse return;
        dbg("[ble] didConnect callback\n", .{});
        conn.conn_done = true;

        // Set peripheral delegate so we get service/char discovery callbacks
        const cm_delegate = msg0(conn.central, s("delegate"));
        _ = msg1(peripheral, s("setDelegate:"), cm_delegate);

        // Discover services (filter for 0xFFE0)
        const uuid_str = cfStr("FFE0");
        const cbuuid = msg1(@ptrCast(cls("CBUUID")), s("UUIDWithString:"), uuid_str);
        const arr = msg1(@ptrCast(cls("NSArray")), s("arrayWithObject:"), cbuuid);
        _ = msg1(peripheral, s("discoverServices:"), arr);
    }

    fn connDidFailConnect(_d: id, _s: SEL, _central: id, _peripheral: id, _err: id) callconv(.c) void {
        _ = _d;
        _ = _s;
        _ = _central;
        _ = _peripheral;
        _ = _err;
        const conn = active_conn orelse return;
        dbg("[ble] didFailToConnect\n", .{});
        conn.failed = true;
    }

    fn connDidDisconnect(_d: id, _s: SEL, _central: id, _peripheral: id, _err: id) callconv(.c) void {
        _ = _d;
        _ = _s;
        _ = _central;
        _ = _peripheral;
        _ = _err;
        const conn = active_conn orelse return;
        conn.connected = false;
        conn.transport.close();
    }

    // ================================================================
    // CBPeripheralDelegate callbacks
    // ================================================================

    fn connDidDiscoverServices(_d: id, _s: SEL, peripheral: id, _err: id) callconv(.c) void {
        _ = _d;
        _ = _s;
        _ = _err;
        const conn = active_conn orelse return;

        const services = msg0(peripheral, s("services"));
        if (services == null) {
            conn.failed = true;
            return;
        }

        const count = msgInt(services, s("count"));
        var i: i64 = 0;
        while (i < count) : (i += 1) {
            const svc = msgUsize(services, s("objectAtIndex:"), @intCast(i));
            if (svc == null) continue;

            // Discover characteristics for this service (filter for 0xFFE1)
            conn.svc_done = true;
            const chr_uuid_str = cfStr("FFE1");
            const chr_cbuuid = msg1(@ptrCast(cls("CBUUID")), s("UUIDWithString:"), chr_uuid_str);
            const chr_arr = msg1(@ptrCast(cls("NSArray")), s("arrayWithObject:"), chr_cbuuid);
            _ = msg2(peripheral, s("discoverCharacteristics:forService:"), chr_arr, svc);
            return;
        }
        conn.failed = true;
    }

    fn connDidDiscoverChars(_d: id, _s: SEL, peripheral: id, service: id, _err: id) callconv(.c) void {
        _ = _d;
        _ = _s;
        _ = _err;
        const conn = active_conn orelse return;

        const chars = msg0(service, s("characteristics"));
        if (chars == null) {
            conn.failed = true;
            return;
        }

        const count = msgInt(chars, s("count"));
        var i: i64 = 0;
        while (i < count) : (i += 1) {
            const chr = msgUsize(chars, s("objectAtIndex:"), @intCast(i));
            if (chr == null) continue;

            conn.characteristic = chr;
            _ = msg0(chr, s("retain"));
            conn.chr_done = true;

            // Subscribe to notifications
            const msgBool: *const fn (id, SEL, bool, id) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
            msgBool(peripheral, s("setNotifyValue:forCharacteristic:"), true, chr);
            return;
        }
        conn.failed = true;
    }

    fn connDidUpdateNotify(_d: id, _s: SEL, _peripheral: id, _chr: id, _err: id) callconv(.c) void {
        _ = _d;
        _ = _s;
        _ = _peripheral;
        _ = _chr;
        _ = _err;
        const conn = active_conn orelse return;
        conn.notify_done = true;
    }

    fn connDidUpdateValue(_d: id, _s: SEL, _peripheral: id, chr: id, _err: id) callconv(.c) void {
        _ = _d;
        _ = _s;
        _ = _peripheral;
        _ = _err;
        const conn = active_conn orelse return;

        const nsdata = msg0(chr, s("value"));
        if (nsdata == null) return;

        const length: usize = @intCast(msgInt(nsdata, s("length")));
        if (length == 0) return;

        const bytes_ptr: ?[*]const u8 = @ptrCast(msg0(nsdata, s("bytes")));
        if (bytes_ptr) |ptr| {
            conn.transport.pushNotify(ptr[0..length]);
        }
    }
};
