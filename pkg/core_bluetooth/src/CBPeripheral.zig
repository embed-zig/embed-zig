//! CBPeripheral — bt.Peripheral implementation via Apple CoreBluetooth.
//!
//! Bridges CBPeripheralManager to the bt.Peripheral VTable.
//! Dynamically creates a delegate class for async callbacks and uses
//! Mutex+Condition to present a blocking API.

const std = @import("std");
const bt = @import("bt");
const Peripheral = bt.Peripheral;
const objc = @import("objc.zig");
const Allocator = std.mem.Allocator;

const CBPeripheral = @This();

allocator: Allocator,
queue_label: [*:0]const u8,
manager: ?objc.Id = null,
delegate: ?objc.Id = null,
queue: ?objc.dispatch_queue_t = null,
state: Peripheral.State = .idle,
powered_on: bool = false,
state_known: bool = false,
started: bool = false,
mutex: std.Thread.Mutex = .{},
cond: std.Thread.Condition = .{},
operation_done: bool = false,
pending_notifications: std.ArrayListUnmanaged(PendingNotify) = .{},
op_error: ?OpError = null,
request_ctx: ?*anyopaque = null,
request_handler: ?Peripheral.RequestHandlerFn = null,
services: std.ArrayListUnmanaged(ServiceEntry) = .{},
chars: std.ArrayListUnmanaged(CharEntry) = .{},

hooks: std.ArrayListUnmanaged(EventHook) = .{},
sub_hooks: std.ArrayListUnmanaged(SubscriptionHook) = .{},

const OpError = enum { invalid_config, already_advertising, unexpected };

const PendingNotify = struct {
    cb_char: objc.Id,
    data: []const u8,
};

const ServiceEntry = struct {
    uuid: u16 = 0,
    char_start: usize = 0,
    char_count: usize = 0,
};

const CharEntry = struct {
    svc_uuid: u16 = 0,
    char_uuid: u16 = 0,
    config: Peripheral.CharConfig = .{},
    cb_char: ?objc.Id = null,
};

const EventHook = struct {
    ctx: ?*anyopaque,
    cb: *const fn (?*anyopaque, Peripheral.Event) void,
};

const SubscriptionHook = struct {
    ctx: ?*anyopaque,
    cb: *const fn (?*anyopaque, Peripheral.SubscriptionInfo) void,
};

// ---- lifecycle ----

pub const Config = struct {
    queue_label: [*:0]const u8 = "com.embed.bt.peripheral",
};

pub fn init(allocator: Allocator, config: Config) CBPeripheral {
    return .{ .allocator = allocator, .queue_label = config.queue_label };
}

pub const StartError = error{BluetoothUnavailable};

pub fn start(self: *CBPeripheral) StartError!void {
    if (self.started) return;

    self.queue = objc.createSerialQueue(self.queue_label);

    const delegate_cls = ensureDelegateClass();
    self.delegate = objc.msgSend(objc.Id, objc.alloc(delegate_cls), objc.sel("init"), .{});
    objc.setIvar(self.delegate.?, "zig_ptr", @ptrCast(self));

    self.manager = objc.msgSend(objc.Id, objc.alloc(objc.getClass("CBPeripheralManager")), objc.sel("initWithDelegate:queue:"), .{
        self.delegate.?,
        @as(*anyopaque, self.queue.?),
    });

    self.started = true;

    self.mutex.lock();
    defer self.mutex.unlock();
    while (!self.state_known) {
        self.cond.wait(&self.mutex);
    }
    if (!self.powered_on) return error.BluetoothUnavailable;
    self.materializeServicesLocked();
}

pub fn stop(self: *CBPeripheral) void {
    if (!self.started) return;
    if (self.state == .advertising) self.stopAdvertising();

    self.mutex.lock();
    self.started = false;
    self.powered_on = false;
    self.state_known = false;
    self.state = .idle;
    self.clearMaterializedServicesLocked();
    self.mutex.unlock();
    objc.release(self.manager.?);
    objc.release(self.delegate.?);
    objc.releaseQueue(self.queue.?);
    self.manager = null;
    self.delegate = null;
    self.queue = null;
}

pub fn deinit(self: *CBPeripheral) void {
    self.stop();
    for (self.pending_notifications.items) |entry| {
        self.allocator.free(entry.data);
    }
    self.pending_notifications.deinit(self.allocator);
    self.services.deinit(self.allocator);
    self.chars.deinit(self.allocator);
    self.hooks.deinit(self.allocator);
    self.sub_hooks.deinit(self.allocator);
    const alloc = self.allocator;
    self.* = undefined;
    alloc.destroy(self);
}

// ---- handler registration ----

pub fn setConfig(self: *CBPeripheral, config: Peripheral.GattConfig) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    self.clearMaterializedServicesLocked();
    self.services.clearRetainingCapacity();
    self.chars.clearRetainingCapacity();

    for (config.services) |svc| {
        const char_start = self.chars.items.len;
        self.services.append(self.allocator, .{
            .uuid = svc.uuid,
            .char_start = char_start,
            .char_count = svc.chars.len,
        }) catch return;

        for (svc.chars) |ch| {
            self.chars.append(self.allocator, .{
                .svc_uuid = svc.uuid,
                .char_uuid = ch.uuid,
                .config = ch.config,
            }) catch return;
        }
    }

    if (self.started and self.powered_on) {
        self.materializeServicesLocked();
    }
}

pub fn setRequestHandler(self: *CBPeripheral, ctx: ?*anyopaque, func: Peripheral.RequestHandlerFn) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.request_ctx = ctx;
    self.request_handler = func;
}

// ---- advertising ----

pub fn startAdvertising(self: *CBPeripheral, config: Peripheral.AdvConfig) Peripheral.AdvError!void {
    if (!self.started) self.start() catch return error.Unexpected;
    if (self.state == .advertising) return error.AlreadyAdvertising;
    if (!self.powered_on) return error.Unexpected;

    var keys: [2]objc.Id = undefined;
    var vals: [2]objc.Id = undefined;
    var count: objc.NSUInteger = 0;

    if (config.device_name.len > 0) {
        keys[count] = objc.nsString("kCBAdvDataLocalName");
        vals[count] = objc.nsString(config.device_name);
        count += 1;
    }

    if (config.service_uuids.len > 0) {
        const uuid_objs = self.allocator.alloc(objc.Id, config.service_uuids.len) catch return error.Unexpected;
        defer self.allocator.free(uuid_objs);
        for (config.service_uuids, 0..) |uuid, i| uuid_objs[i] = objc.cbuuid(uuid);
        keys[count] = objc.nsString("kCBAdvDataServiceUUIDs");
        vals[count] = objc.nsArray(uuid_objs, uuid_objs.len);
        count += 1;
    }

    const adv_dict = objc.nsDictionary(keys[0..count], vals[0..count], count);

    self.mutex.lock();
    self.operation_done = false;
    self.op_error = null;

    objc.msgSend(void, self.manager.?, objc.sel("startAdvertising:"), .{adv_dict});

    while (!self.operation_done) {
        self.cond.wait(&self.mutex);
    }
    const err = self.op_error;
    self.mutex.unlock();

    if (err) |e| return switch (e) {
        .invalid_config => error.InvalidConfig,
        .already_advertising => error.AlreadyAdvertising,
        .unexpected => error.Unexpected,
    };

    self.state = .advertising;
    self.fireEvent(.{ .advertising_started = {} });
}

pub fn stopAdvertising(self: *CBPeripheral) void {
    if (self.state != .advertising) return;
    if (self.manager) |m| {
        objc.msgSend(void, m, objc.sel("stopAdvertising"), .{});
    }
    self.state = .idle;
    self.fireEvent(.{ .advertising_stopped = {} });
}

// ---- notify / indicate ----

pub fn notify(self: *CBPeripheral, _: u16, char_uuid: u16, data: []const u8) Peripheral.GattError!void {
    const cb_char = self.findCBChar(char_uuid) orelse return error.InvalidHandle;
    self.drainPendingNotifications();
    const ns_data = objc.nsData(data);
    const ok: objc.BOOL = objc.msgSend(objc.BOOL, self.manager.?, objc.sel("updateValue:forCharacteristic:onSubscribedCentrals:"), .{
        ns_data,
        cb_char,
        @as(?*anyopaque, null),
    });
    if (ok == objc.YES) return;
    const owned = self.allocator.dupe(u8, data) catch return error.Unexpected;
    self.pending_notifications.append(self.allocator, .{
        .cb_char = cb_char,
        .data = owned,
    }) catch {
        self.allocator.free(owned);
        return error.Unexpected;
    };
}

fn drainPendingNotifications(self: *CBPeripheral) void {
    while (self.pending_notifications.items.len > 0) {
        const entry = self.pending_notifications.items[0];
        const ns_data = objc.nsData(entry.data);
        const ok: objc.BOOL = objc.msgSend(objc.BOOL, self.manager.?, objc.sel("updateValue:forCharacteristic:onSubscribedCentrals:"), .{
            ns_data,
            entry.cb_char,
            @as(?*anyopaque, null),
        });
        if (ok != objc.YES) return;
        self.allocator.free(entry.data);
        _ = self.pending_notifications.orderedRemove(0);
    }
}

pub fn indicate(self: *CBPeripheral, conn_handle: u16, char_uuid: u16, data: []const u8) Peripheral.GattError!void {
    return self.notify(conn_handle, char_uuid, data);
}

// ---- connection ----

pub fn disconnect(_: *CBPeripheral, _: u16) void {}

// ---- state & info ----

pub fn getState(self: *CBPeripheral) Peripheral.State {
    return self.state;
}

pub fn getAddr(_: *CBPeripheral) ?Peripheral.BdAddr {
    return null;
}

pub fn addEventHook(self: *CBPeripheral, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, Peripheral.Event) void) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.hooks.append(self.allocator, .{ .ctx = ctx, .cb = cb }) catch return;
}

pub fn removeEventHook(self: *CBPeripheral, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, Peripheral.Event) void) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    var i: usize = 0;
    while (i < self.hooks.items.len) {
        const hook = self.hooks.items[i];
        if (hook.ctx == ctx and hook.cb == cb) {
            _ = self.hooks.orderedRemove(i);
            continue;
        }
        i += 1;
    }
}

pub fn addSubscriptionHook(self: *CBPeripheral, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, Peripheral.SubscriptionInfo) void) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.sub_hooks.append(self.allocator, .{ .ctx = ctx, .cb = cb }) catch return;
}

pub fn removeSubscriptionHook(self: *CBPeripheral, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, Peripheral.SubscriptionInfo) void) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    var i: usize = 0;
    while (i < self.sub_hooks.items.len) {
        const hook = self.sub_hooks.items[i];
        if (hook.ctx == ctx and hook.cb == cb) {
            _ = self.sub_hooks.orderedRemove(i);
            continue;
        }
        i += 1;
    }
}

fn fireSubscriptionEvent(self: *CBPeripheral, info: Peripheral.SubscriptionInfo) void {
    self.mutex.lock();
    const snapshot = self.allocator.dupe(SubscriptionHook, self.sub_hooks.items) catch {
        self.mutex.unlock();
        return;
    };
    self.mutex.unlock();
    defer self.allocator.free(snapshot);
    for (snapshot) |hook| {
        hook.cb(hook.ctx, info);
    }
}

// ---- internal helpers ----

fn findCBChar(self: *CBPeripheral, char_uuid: u16) ?objc.Id {
    for (self.chars.items) |entry| {
        if (entry.char_uuid == char_uuid) return entry.cb_char;
    }
    return null;
}

fn findChar(self: *CBPeripheral, svc_uuid: u16, char_uuid: u16) ?*CharEntry {
    for (self.chars.items) |*entry| {
        if (entry.svc_uuid == svc_uuid and entry.char_uuid == char_uuid) return entry;
    }
    return null;
}

fn clearMaterializedServicesLocked(self: *CBPeripheral) void {
    if (self.manager) |manager| {
        objc.msgSend(void, manager, objc.sel("removeAllServices"), .{});
    }
    for (self.chars.items) |*entry| {
        if (entry.cb_char) |cb_char| {
            objc.release(cb_char);
            entry.cb_char = null;
        }
    }
}

fn materializeServicesLocked(self: *CBPeripheral) void {
    if (!self.started or !self.powered_on or self.manager == null) return;

    for (self.services.items) |service| {
        if (service.char_count == 0) continue;

        const cb_chars = self.allocator.alloc(objc.Id, service.char_count) catch return;
        defer self.allocator.free(cb_chars);

        for (0..service.char_count) |i| {
            const entry = &self.chars.items[service.char_start + i];
            entry.cb_char = makeCharacteristic(entry.char_uuid, entry.config);
            cb_chars[i] = entry.cb_char.?;
        }

        const cb_svc = objc.msgSend(objc.Id, objc.alloc(objc.getClass("CBMutableService")), objc.sel("initWithType:primary:"), .{
            objc.cbuuid(service.uuid),
            @as(objc.BOOL, objc.YES),
        });
        defer objc.release(cb_svc);

        const char_array = objc.nsArray(cb_chars, cb_chars.len);
        objc.msgSend(void, cb_svc, objc.sel("setCharacteristics:"), .{char_array});

        self.operation_done = false;
        self.op_error = null;
        objc.msgSend(void, self.manager.?, objc.sel("addService:"), .{cb_svc});

        while (!self.operation_done) {
            self.cond.wait(&self.mutex);
        }

        if (self.op_error != null) {
            return;
        }
    }
}

fn makeCharacteristic(uuid: u16, config: Peripheral.CharConfig) objc.Id {
    return objc.msgSend(objc.Id, objc.alloc(objc.getClass("CBMutableCharacteristic")), objc.sel("initWithType:properties:value:permissions:"), .{
        objc.cbuuid(uuid),
        characteristicProperties(config),
        @as(?*anyopaque, null),
        characteristicPermissions(config),
    });
}

fn characteristicProperties(config: Peripheral.CharConfig) objc.NSUInteger {
    var props: objc.NSUInteger = 0;
    if (config.read) props |= 0x02;
    if (config.write_without_response) props |= 0x04;
    if (config.write) props |= 0x08;
    if (config.notify) props |= 0x10;
    if (config.indicate) props |= 0x20;
    return props;
}

fn characteristicPermissions(config: Peripheral.CharConfig) objc.NSUInteger {
    var perms: objc.NSUInteger = 0;
    if (config.read) perms |= 0x01;
    if (config.write or config.write_without_response) perms |= 0x02;
    return perms;
}

fn fireEvent(self: *CBPeripheral, event: Peripheral.Event) void {
    self.mutex.lock();
    const snapshot = self.allocator.dupe(EventHook, self.hooks.items) catch {
        self.mutex.unlock();
        return;
    };
    self.mutex.unlock();
    defer self.allocator.free(snapshot);
    for (snapshot) |hook| hook.cb(hook.ctx, event);
}

fn signalDone(self: *CBPeripheral) void {
    self.operation_done = true;
    self.cond.signal();
}

// ---- Delegate class (created once) ----

var delegate_class: ?objc.Class = null;
var delegate_once = std.once(initDelegateClass);

fn ensureDelegateClass() objc.Class {
    delegate_once.call();
    return delegate_class.?;
}

fn initDelegateClass() void {
    var builder = objc.allocateClassPair("NSObject", "ZigCBPeripheralDelegate");
    builder.addIvar("zig_ptr", @sizeOf(*anyopaque), @alignOf(*anyopaque));

    builder.addProtocol("CBPeripheralManagerDelegate");

    builder.addMethod("peripheralManagerDidUpdateState:", @ptrCast(&pmDidUpdateState), "v@:@");
    builder.addMethod("peripheralManager:didAddService:error:", @ptrCast(&pmDidAddService), "v@:@@@");
    builder.addMethod("peripheralManagerDidStartAdvertising:error:", @ptrCast(&pmDidStartAdvertising), "v@:@@");
    builder.addMethod("peripheralManager:didReceiveReadRequest:", @ptrCast(&pmDidReceiveRead), "v@:@@");
    builder.addMethod("peripheralManager:didReceiveWriteRequests:", @ptrCast(&pmDidReceiveWrite), "v@:@@");
    builder.addMethod("peripheralManager:central:didSubscribeToCharacteristic:", @ptrCast(&pmDidSubscribe), "v@:@@@");
    builder.addMethod("peripheralManager:central:didUnsubscribeFromCharacteristic:", @ptrCast(&pmDidUnsubscribe), "v@:@@@");
    builder.addMethod("peripheralManagerIsReadyToUpdateSubscribers:", @ptrCast(&pmIsReadyToUpdate), "v@:@");

    delegate_class = builder.register();
}

fn getSelf(delegate: objc.Id) ?*CBPeripheral {
    const ptr = objc.getIvar(delegate, "zig_ptr") orelse return null;
    return @ptrCast(@alignCast(ptr));
}

// ---- Delegate callbacks ----

fn pmDidUpdateState(delegate: objc.Id, _: objc.SEL, manager: objc.Id) callconv(.c) void {
    const self = getSelf(delegate) orelse return;
    const cb_state: objc.NSInteger = objc.msgSend(objc.NSInteger, manager, objc.sel("state"), .{});
    self.mutex.lock();
    self.powered_on = (cb_state == 5); // CBManagerStatePoweredOn
    self.state_known = true;
    self.signalDone();
    self.mutex.unlock();
}

fn pmDidAddService(delegate: objc.Id, _: objc.SEL, _: objc.Id, _: objc.Id, err: ?objc.Id) callconv(.c) void {
    const self = getSelf(delegate) orelse return;
    self.mutex.lock();
    if (err != null) self.op_error = .unexpected;
    self.signalDone();
    self.mutex.unlock();
}

fn pmDidStartAdvertising(delegate: objc.Id, _: objc.SEL, _: objc.Id, err: ?objc.Id) callconv(.c) void {
    const self = getSelf(delegate) orelse return;
    self.mutex.lock();
    if (err != null) self.op_error = .unexpected;
    self.signalDone();
    self.mutex.unlock();
}

fn pmDidReceiveRead(delegate: objc.Id, _: objc.SEL, manager: objc.Id, request: objc.Id) callconv(.c) void {
    const self = getSelf(delegate) orelse return;

    const characteristic: objc.Id = objc.msgSend(objc.Id, request, objc.sel("characteristic"), .{});
    const service: objc.Id = objc.msgSend(objc.Id, characteristic, objc.sel("service"), .{});
    const service_uuid_obj: objc.Id = objc.msgSend(objc.Id, service, objc.sel("UUID"), .{});
    const uuid_obj: objc.Id = objc.msgSend(objc.Id, characteristic, objc.sel("UUID"), .{});
    const svc_uuid = objc.cbuuidToU16(service_uuid_obj);
    const char_uuid = objc.cbuuidToU16(uuid_obj);

    const char_entry = self.findChar(svc_uuid, char_uuid) orelse {
        objc.msgSend(void, manager, objc.sel("respondToRequest:withResult:"), .{
            request,
            @as(objc.NSInteger, 10), // CBATTErrorAttributeNotFound
        });
        return;
    };
    if (!char_entry.config.read) {
        objc.msgSend(void, manager, objc.sel("respondToRequest:withResult:"), .{
            request,
            @as(objc.NSInteger, 2), // CBATTErrorReadNotPermitted
        });
        return;
    }
    const handler = self.request_handler orelse {
        objc.msgSend(void, manager, objc.sel("respondToRequest:withResult:"), .{
            request,
            @as(objc.NSInteger, 6), // CBATTErrorRequestNotSupported
        });
        return;
    };

    var rw_impl = ResponseWriterImpl{ .manager = manager, .request = request };
    var rw = Peripheral.ResponseWriter{
        ._impl = @ptrCast(&rw_impl),
        ._write_fn = @ptrCast(&ResponseWriterImpl.writeFn),
        ._ok_fn = @ptrCast(&ResponseWriterImpl.okFn),
        ._err_fn = @ptrCast(&ResponseWriterImpl.errFn),
    };

    var req = Peripheral.Request{
        .op = .read,
        .conn_handle = 0,
        .service_uuid = svc_uuid,
        .char_uuid = char_uuid,
        .data = &.{},
    };

    handler(self.request_ctx, &req, &rw);
}

fn pmDidReceiveWrite(delegate: objc.Id, _: objc.SEL, manager: objc.Id, requests: objc.Id) callconv(.c) void {
    const self = getSelf(delegate) orelse return;

    const count: objc.NSUInteger = objc.msgSend(objc.NSUInteger, requests, objc.sel("count"), .{});
    if (count == 0) return;

    // Apple docs: "Call respondToRequest:withResult: exactly once,
    // passing in the first request of the requests array."
    const first_request: objc.Id = objc.msgSend(objc.Id, requests, objc.sel("objectAtIndex:"), .{@as(objc.NSUInteger, 0)});
    var final_result: objc.NSInteger = 0; // CBATTErrorSuccess

    for (0..count) |i| {
        const request: objc.Id = objc.msgSend(objc.Id, requests, objc.sel("objectAtIndex:"), .{@as(objc.NSUInteger, i)});
        const characteristic: objc.Id = objc.msgSend(objc.Id, request, objc.sel("characteristic"), .{});
        const service: objc.Id = objc.msgSend(objc.Id, characteristic, objc.sel("service"), .{});
        const service_uuid_obj: objc.Id = objc.msgSend(objc.Id, service, objc.sel("UUID"), .{});
        const uuid_obj: objc.Id = objc.msgSend(objc.Id, characteristic, objc.sel("UUID"), .{});
        const svc_uuid = objc.cbuuidToU16(service_uuid_obj);
        const char_uuid = objc.cbuuidToU16(uuid_obj);

        const char_entry = self.findChar(svc_uuid, char_uuid) orelse {
            final_result = 10; // CBATTErrorAttributeNotFound
            break;
        };
        if (!(char_entry.config.write or char_entry.config.write_without_response)) {
            final_result = 3; // CBATTErrorWriteNotPermitted
            break;
        }
        const handler = self.request_handler orelse {
            final_result = 6; // CBATTErrorRequestNotSupported
            break;
        };

        const value: objc.Id = objc.msgSend(objc.Id, request, objc.sel("value"), .{});
        var data_buf: [512]u8 = undefined;
        const data_slice = objc.nsDataGetBytes(value, &data_buf);

        std.debug.print("[CB] write svc=0x{X:0>4} char=0x{X:0>4} len={d}", .{ svc_uuid, char_uuid, data_slice.len });
        if (data_slice.len > 0) {
            const show = @min(data_slice.len, 8);
            std.debug.print(" data=[", .{});
            for (data_slice[0..show], 0..) |b, bi| {
                if (bi > 0) std.debug.print(" ", .{});
                std.debug.print("{X:0>2}", .{b});
            }
            if (data_slice.len > show) std.debug.print(" ...", .{});
            std.debug.print("]", .{});
        }
        std.debug.print("\n", .{});

        var deferred = DeferredResponseWriterImpl{};
        var rw = Peripheral.ResponseWriter{
            ._impl = @ptrCast(&deferred),
            ._write_fn = @ptrCast(&DeferredResponseWriterImpl.writeFn),
            ._ok_fn = @ptrCast(&DeferredResponseWriterImpl.okFn),
            ._err_fn = @ptrCast(&DeferredResponseWriterImpl.errFn),
        };

        var req = Peripheral.Request{
            .op = .write,
            .conn_handle = 0,
            .service_uuid = svc_uuid,
            .char_uuid = char_uuid,
            .data = data_slice,
        };

        handler(self.request_ctx, &req, &rw);

        if (deferred.result != 0) {
            final_result = deferred.result;
            break;
        }
    }

    objc.msgSend(void, manager, objc.sel("respondToRequest:withResult:"), .{
        first_request,
        final_result,
    });
}

fn pmDidSubscribe(delegate: objc.Id, _: objc.SEL, _: objc.Id, central: objc.Id, characteristic: objc.Id) callconv(.c) void {
    const self = getSelf(delegate) orelse return;

    const service: objc.Id = objc.msgSend(objc.Id, characteristic, objc.sel("service"), .{});
    const svc_uuid = objc.cbuuidToU16(objc.msgSend(objc.Id, service, objc.sel("UUID"), .{}));
    const char_uuid = objc.cbuuidToU16(objc.msgSend(objc.Id, characteristic, objc.sel("UUID"), .{}));

    const max_update_len: objc.NSUInteger = objc.msgSend(objc.NSUInteger, central, objc.sel("maximumUpdateValueLength"), .{});
    const mtu: u16 = @intCast(@min(max_update_len + 3, 517));
    std.debug.print("[CB] subscribe svc=0x{X:0>4} char=0x{X:0>4} central.maxUpdateLen={d} mtu={d}\n", .{ svc_uuid, char_uuid, max_update_len, mtu });

    self.fireEvent(.{ .connected = .{
        .conn_handle = 0,
        .peer_addr = .{0} ** 6,
        .peer_addr_type = .random,
        .interval = 0,
        .latency = 0,
        .timeout = 0,
    } });

    self.fireEvent(.{ .mtu_changed = .{
        .conn_handle = 0,
        .mtu = mtu,
    } });

    self.fireSubscriptionEvent(.{
        .conn_handle = 0,
        .service_uuid = svc_uuid,
        .char_uuid = char_uuid,
        .cccd_value = 0x0001,
    });
}

fn pmDidUnsubscribe(delegate: objc.Id, _: objc.SEL, _: objc.Id, _: objc.Id, characteristic: objc.Id) callconv(.c) void {
    const self = getSelf(delegate) orelse return;

    const service: objc.Id = objc.msgSend(objc.Id, characteristic, objc.sel("service"), .{});
    const svc_uuid = objc.cbuuidToU16(objc.msgSend(objc.Id, service, objc.sel("UUID"), .{}));
    const char_uuid = objc.cbuuidToU16(objc.msgSend(objc.Id, characteristic, objc.sel("UUID"), .{}));
    std.debug.print("[CB] unsubscribe svc=0x{X:0>4} char=0x{X:0>4}\n", .{ svc_uuid, char_uuid });

    self.fireSubscriptionEvent(.{
        .conn_handle = 0,
        .service_uuid = svc_uuid,
        .char_uuid = char_uuid,
        .cccd_value = 0x0000,
    });

    self.fireEvent(.{ .disconnected = 0 });
}

fn pmIsReadyToUpdate(delegate: objc.Id, _: objc.SEL, _: objc.Id) callconv(.c) void {
    const self = getSelf(delegate) orelse return;
    self.drainPendingNotifications();
}

// ---- ResponseWriter implementations ----

// Captures the handler result without calling respondToRequest:.
// Used by pmDidReceiveWrite to batch-respond once with requests[0].
const DeferredResponseWriterImpl = struct {
    result: objc.NSInteger = 0,

    fn writeFn(impl_ptr: *anyopaque, _: []const u8) void {
        const self: *DeferredResponseWriterImpl = @ptrCast(@alignCast(impl_ptr));
        self.result = 0;
    }

    fn okFn(impl_ptr: *anyopaque) void {
        const self: *DeferredResponseWriterImpl = @ptrCast(@alignCast(impl_ptr));
        self.result = 0;
    }

    fn errFn(impl_ptr: *anyopaque, code: u8) void {
        const self: *DeferredResponseWriterImpl = @ptrCast(@alignCast(impl_ptr));
        self.result = @intCast(code);
    }
};

const ResponseWriterImpl = struct {
    manager: objc.Id,
    request: objc.Id,

    fn writeFn(impl_ptr: *anyopaque, data: []const u8) void {
        const self: *ResponseWriterImpl = @ptrCast(@alignCast(impl_ptr));
        const ns_data = objc.nsData(data);
        objc.msgSend(void, self.request, objc.sel("setValue:"), .{ns_data});
        objc.msgSend(void, self.manager, objc.sel("respondToRequest:withResult:"), .{
            self.request,
            @as(objc.NSInteger, 0),
        });
    }

    fn okFn(impl_ptr: *anyopaque) void {
        const self: *ResponseWriterImpl = @ptrCast(@alignCast(impl_ptr));
        objc.msgSend(void, self.manager, objc.sel("respondToRequest:withResult:"), .{
            self.request,
            @as(objc.NSInteger, 0),
        });
    }

    fn errFn(impl_ptr: *anyopaque, code: u8) void {
        const self: *ResponseWriterImpl = @ptrCast(@alignCast(impl_ptr));
        objc.msgSend(void, self.manager, objc.sel("respondToRequest:withResult:"), .{
            self.request,
            @as(objc.NSInteger, @intCast(code)),
        });
    }
};
