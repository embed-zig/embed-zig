const drivers = @import("drivers");
const ledstrip = @import("ledstrip");
const modem_api = @import("modem");

pub fn make(comptime Impl: type) type {
    const impl_periph_label = blk: {
        if (!@hasDecl(Impl, "PeriphLabel")) {
            @compileError("zux.App.make requires Impl.PeriphLabel");
        }
        break :blk @as(type, Impl.PeriphLabel);
    };
    const impl_init_config = blk: {
        if (!@hasDecl(Impl, "InitConfig")) {
            @compileError("zux.App.make requires Impl.InitConfig");
        }
        break :blk @as(type, Impl.InitConfig);
    };
    const impl_pixel_count = blk: {
        if (!@hasDecl(Impl, "pixel_count")) {
            @compileError("zux.App.make requires Impl.pixel_count");
        }
        break :blk @as(usize, Impl.pixel_count);
    };
    const impl_frame_type = ledstrip.Frame.make(impl_pixel_count);
    const impl_store_type = if (@hasDecl(Impl, "Store")) Impl.Store else void;

    comptime {
        if (@typeInfo(Impl) != .@"struct") {
            @compileError("zux.App.make requires Impl to be a struct type");
        }
        if (@typeInfo(impl_periph_label) != .@"enum") {
            @compileError("zux.App.make requires Impl.PeriphLabel to be an enum type");
        }

        if (!@hasDecl(Impl, "deinit")) {
            @compileError("zux.App.make requires Impl.deinit");
        }
        if (!@hasDecl(Impl, "init")) {
            @compileError("zux.App.make requires Impl.init");
        }
        if (!@hasDecl(Impl, "start")) {
            @compileError("zux.App.make requires Impl.start");
        }
        if (!@hasDecl(Impl, "stop")) {
            @compileError("zux.App.make requires Impl.stop");
        }
        if (!@hasDecl(Impl, "press_single_button")) {
            @compileError("zux.App.make requires Impl.press_single_button");
        }
        if (!@hasDecl(Impl, "release_single_button")) {
            @compileError("zux.App.make requires Impl.release_single_button");
        }
        if (!@hasDecl(Impl, "press_grouped_button")) {
            @compileError("zux.App.make requires Impl.press_grouped_button");
        }
        if (!@hasDecl(Impl, "release_grouped_button")) {
            @compileError("zux.App.make requires Impl.release_grouped_button");
        }
        if (!@hasDecl(Impl, "imu_accel")) {
            @compileError("zux.App.make requires Impl.imu_accel");
        }
        if (!@hasDecl(Impl, "imu_gyro")) {
            @compileError("zux.App.make requires Impl.imu_gyro");
        }
        if (!@hasDecl(Impl, "modem_sim_state_changed")) {
            @compileError("zux.App.make requires Impl.modem_sim_state_changed");
        }
        if (!@hasDecl(Impl, "modem_network_registration_changed")) {
            @compileError("zux.App.make requires Impl.modem_network_registration_changed");
        }
        if (!@hasDecl(Impl, "modem_network_signal_changed")) {
            @compileError("zux.App.make requires Impl.modem_network_signal_changed");
        }
        if (!@hasDecl(Impl, "modem_data_packet_state_changed")) {
            @compileError("zux.App.make requires Impl.modem_data_packet_state_changed");
        }
        if (!@hasDecl(Impl, "modem_data_apn_changed")) {
            @compileError("zux.App.make requires Impl.modem_data_apn_changed");
        }
        if (!@hasDecl(Impl, "modem_call_incoming")) {
            @compileError("zux.App.make requires Impl.modem_call_incoming");
        }
        if (!@hasDecl(Impl, "modem_call_state_changed")) {
            @compileError("zux.App.make requires Impl.modem_call_state_changed");
        }
        if (!@hasDecl(Impl, "modem_call_ended")) {
            @compileError("zux.App.make requires Impl.modem_call_ended");
        }
        if (!@hasDecl(Impl, "modem_sms_received")) {
            @compileError("zux.App.make requires Impl.modem_sms_received");
        }
        if (!@hasDecl(Impl, "modem_gnss_state_changed")) {
            @compileError("zux.App.make requires Impl.modem_gnss_state_changed");
        }
        if (!@hasDecl(Impl, "modem_gnss_fix_changed")) {
            @compileError("zux.App.make requires Impl.modem_gnss_fix_changed");
        }
        if (!@hasDecl(Impl, "set_led_strip_pixels")) {
            @compileError("zux.App.make requires Impl.set_led_strip_pixels");
        }
        if (!@hasDecl(Impl, "set_led_strip_animated")) {
            @compileError("zux.App.make requires Impl.set_led_strip_animated");
        }
        if (!@hasDecl(Impl, "set_led_strip_flash")) {
            @compileError("zux.App.make requires Impl.set_led_strip_flash");
        }
        if (!@hasDecl(Impl, "set_led_strip_pingpong")) {
            @compileError("zux.App.make requires Impl.set_led_strip_pingpong");
        }
        if (!@hasDecl(Impl, "set_led_strip_rotate")) {
            @compileError("zux.App.make requires Impl.set_led_strip_rotate");
        }
        if (!@hasDecl(Impl, "nfc_found")) {
            @compileError("zux.App.make requires Impl.nfc_found");
        }
        if (!@hasDecl(Impl, "nfc_read")) {
            @compileError("zux.App.make requires Impl.nfc_read");
        }
        if (!@hasDecl(Impl, "wifi_sta_scan_result")) {
            @compileError("zux.App.make requires Impl.wifi_sta_scan_result");
        }
        if (!@hasDecl(Impl, "wifi_sta_connected")) {
            @compileError("zux.App.make requires Impl.wifi_sta_connected");
        }
        if (!@hasDecl(Impl, "wifi_sta_disconnected")) {
            @compileError("zux.App.make requires Impl.wifi_sta_disconnected");
        }
        if (!@hasDecl(Impl, "wifi_sta_got_ip")) {
            @compileError("zux.App.make requires Impl.wifi_sta_got_ip");
        }
        if (!@hasDecl(Impl, "wifi_sta_lost_ip")) {
            @compileError("zux.App.make requires Impl.wifi_sta_lost_ip");
        }
        if (!@hasDecl(Impl, "wifi_ap_started")) {
            @compileError("zux.App.make requires Impl.wifi_ap_started");
        }
        if (!@hasDecl(Impl, "wifi_ap_stopped")) {
            @compileError("zux.App.make requires Impl.wifi_ap_stopped");
        }
        if (!@hasDecl(Impl, "wifi_ap_client_joined")) {
            @compileError("zux.App.make requires Impl.wifi_ap_client_joined");
        }
        if (!@hasDecl(Impl, "wifi_ap_client_left")) {
            @compileError("zux.App.make requires Impl.wifi_ap_client_left");
        }
        if (!@hasDecl(Impl, "wifi_ap_lease_granted")) {
            @compileError("zux.App.make requires Impl.wifi_ap_lease_granted");
        }
        if (!@hasDecl(Impl, "wifi_ap_lease_released")) {
            @compileError("zux.App.make requires Impl.wifi_ap_lease_released");
        }
        if (impl_store_type != void and !@hasDecl(Impl, "store")) {
            @compileError("zux.App.make requires Impl.store when Impl.Store is present");
        }

        _ = @as(*const fn (impl_init_config) anyerror!Impl, &Impl.init);
        _ = @as(*const fn (*Impl) void, &Impl.deinit);
        _ = @as(*const fn (*Impl) anyerror!void, &Impl.start);
        _ = @as(*const fn (*Impl) anyerror!void, &Impl.stop);
        _ = @as(*const fn (*Impl, impl_periph_label) anyerror!void, &Impl.press_single_button);
        _ = @as(*const fn (*Impl, impl_periph_label) anyerror!void, &Impl.release_single_button);
        _ = @as(*const fn (*Impl, impl_periph_label, u32) anyerror!void, &Impl.press_grouped_button);
        _ = @as(*const fn (*Impl, impl_periph_label) anyerror!void, &Impl.release_grouped_button);
        _ = @as(*const fn (*Impl, impl_periph_label, drivers.imu.Vec3) anyerror!void, &Impl.imu_accel);
        _ = @as(*const fn (*Impl, impl_periph_label, drivers.imu.Vec3) anyerror!void, &Impl.imu_gyro);
        _ = @as(*const fn (*Impl, impl_periph_label, modem_api.Modem.SimState) anyerror!void, &Impl.modem_sim_state_changed);
        _ = @as(*const fn (*Impl, impl_periph_label, modem_api.Modem.RegistrationState) anyerror!void, &Impl.modem_network_registration_changed);
        _ = @as(*const fn (*Impl, impl_periph_label, modem_api.Modem.SignalInfo) anyerror!void, &Impl.modem_network_signal_changed);
        _ = @as(*const fn (*Impl, impl_periph_label, modem_api.Modem.PacketState) anyerror!void, &Impl.modem_data_packet_state_changed);
        _ = @as(*const fn (*Impl, impl_periph_label, []const u8) anyerror!void, &Impl.modem_data_apn_changed);
        _ = @as(*const fn (*Impl, impl_periph_label, modem_api.Modem.CallInfo) anyerror!void, &Impl.modem_call_incoming);
        _ = @as(*const fn (*Impl, impl_periph_label, modem_api.Modem.CallStatus) anyerror!void, &Impl.modem_call_state_changed);
        _ = @as(*const fn (*Impl, impl_periph_label, modem_api.Modem.CallEndInfo) anyerror!void, &Impl.modem_call_ended);
        _ = @as(*const fn (*Impl, impl_periph_label, modem_api.Modem.SmsMessage) anyerror!void, &Impl.modem_sms_received);
        _ = @as(*const fn (*Impl, impl_periph_label, modem_api.Modem.GnssState) anyerror!void, &Impl.modem_gnss_state_changed);
        _ = @as(*const fn (*Impl, impl_periph_label, modem_api.Modem.GnssFix) anyerror!void, &Impl.modem_gnss_fix_changed);
        _ = @as(*const fn (*Impl, impl_periph_label, impl_frame_type, u8) anyerror!void, &Impl.set_led_strip_pixels);
        _ = @as(*const fn (*Impl, impl_periph_label, impl_frame_type, u8, u32) anyerror!void, &Impl.set_led_strip_animated);
        _ = @as(*const fn (*Impl, impl_periph_label, impl_frame_type, u8, u64, u64) anyerror!void, &Impl.set_led_strip_flash);
        _ = @as(*const fn (*Impl, impl_periph_label, impl_frame_type, impl_frame_type, u8, u64, u64) anyerror!void, &Impl.set_led_strip_pingpong);
        _ = @as(*const fn (*Impl, impl_periph_label, impl_frame_type, u8, u64, u64) anyerror!void, &Impl.set_led_strip_rotate);
        _ = @as(*const fn (*Impl, impl_periph_label, []const u8, drivers.nfc.CardType) anyerror!void, &Impl.nfc_found);
        _ = @as(*const fn (*Impl, impl_periph_label, []const u8, []const u8, drivers.nfc.CardType) anyerror!void, &Impl.nfc_read);
        _ = @as(*const fn (*Impl, impl_periph_label, drivers.wifi.Sta.ScanResult) anyerror!void, &Impl.wifi_sta_scan_result);
        _ = @as(*const fn (*Impl, impl_periph_label, drivers.wifi.Sta.LinkInfo) anyerror!void, &Impl.wifi_sta_connected);
        _ = @as(*const fn (*Impl, impl_periph_label, drivers.wifi.Sta.DisconnectInfo) anyerror!void, &Impl.wifi_sta_disconnected);
        _ = @as(*const fn (*Impl, impl_periph_label, drivers.wifi.Sta.IpInfo) anyerror!void, &Impl.wifi_sta_got_ip);
        _ = @as(*const fn (*Impl, impl_periph_label) anyerror!void, &Impl.wifi_sta_lost_ip);
        _ = @as(*const fn (*Impl, impl_periph_label, drivers.wifi.Ap.StartedInfo) anyerror!void, &Impl.wifi_ap_started);
        _ = @as(*const fn (*Impl, impl_periph_label) anyerror!void, &Impl.wifi_ap_stopped);
        _ = @as(*const fn (*Impl, impl_periph_label, drivers.wifi.Ap.ClientInfo) anyerror!void, &Impl.wifi_ap_client_joined);
        _ = @as(*const fn (*Impl, impl_periph_label, drivers.wifi.Ap.ClientInfo) anyerror!void, &Impl.wifi_ap_client_left);
        _ = @as(*const fn (*Impl, impl_periph_label, drivers.wifi.Ap.LeaseInfo) anyerror!void, &Impl.wifi_ap_lease_granted);
        _ = @as(*const fn (*Impl, impl_periph_label, drivers.wifi.Ap.LeaseInfo) anyerror!void, &Impl.wifi_ap_lease_released);
        if (impl_store_type != void) {
            _ = @as(*const fn (*Impl) *impl_store_type, &Impl.store);
        }
    }

    const app = struct {
        const Self = @This();

        impl: Impl,
        store: if (impl_store_type == void) void else *impl_store_type,

        pub const ImplType = Impl;
        pub const InitConfig = impl_init_config;
        pub const Lib = if (@hasDecl(Impl, "Lib")) Impl.Lib else void;
        pub const Config = if (@hasDecl(Impl, "Config")) Impl.Config else void;
        pub const BuildConfig = if (@hasDecl(Impl, "BuildConfig")) Impl.BuildConfig else void;
        pub const build_config = if (@hasDecl(Impl, "build_config")) Impl.build_config else {};
        pub const Store = if (@hasDecl(Impl, "Store")) Impl.Store else void;
        pub const Root = if (@hasDecl(Impl, "Root")) Impl.Root else void;
        pub const Imu = drivers.imu;
        pub const Modem = modem_api.Modem;
        pub const Nfc = drivers.nfc;
        pub const Wifi = drivers.wifi;
        pub const Label = if (@hasDecl(Impl, "Label")) Impl.Label else impl_periph_label;
        pub const PeriphLabel = impl_periph_label;
        pub const poller_count = if (@hasDecl(Impl, "poller_count")) Impl.poller_count else 0;
        pub const pixel_count = impl_pixel_count;
        pub const FrameType = impl_frame_type;

        pub fn init(init_config: InitConfig) !Self {
            var impl = try Impl.init(init_config);
            return .{
                .impl = impl,
                .store = if (impl_store_type == void) {} else impl.store(),
            };
        }

        pub fn deinit(self: *Self) void {
            self.impl.deinit();
        }

        pub fn start(self: *Self) !void {
            try self.impl.start();
        }

        pub fn stop(self: *Self) !void {
            try self.impl.stop();
        }

        pub fn press_single_button(self: *Self, label: PeriphLabel) !void {
            try self.impl.press_single_button(label);
        }

        pub fn release_single_button(self: *Self, label: PeriphLabel) !void {
            try self.impl.release_single_button(label);
        }

        pub fn press_grouped_button(self: *Self, label: PeriphLabel, button_id: u32) !void {
            try self.impl.press_grouped_button(label, button_id);
        }

        pub fn release_grouped_button(self: *Self, label: PeriphLabel) !void {
            try self.impl.release_grouped_button(label);
        }

        pub fn imu_accel(self: *Self, label: PeriphLabel, accel: Imu.Vec3) !void {
            try self.impl.imu_accel(label, accel);
        }

        pub fn imu_gyro(self: *Self, label: PeriphLabel, gyro: Imu.Vec3) !void {
            try self.impl.imu_gyro(label, gyro);
        }

        pub fn modem_sim_state_changed(self: *Self, label: PeriphLabel, sim: Modem.SimState) !void {
            try self.impl.modem_sim_state_changed(label, sim);
        }

        pub fn modem_network_registration_changed(self: *Self, label: PeriphLabel, registration: Modem.RegistrationState) !void {
            try self.impl.modem_network_registration_changed(label, registration);
        }

        pub fn modem_network_signal_changed(self: *Self, label: PeriphLabel, signal: Modem.SignalInfo) !void {
            try self.impl.modem_network_signal_changed(label, signal);
        }

        pub fn modem_data_packet_state_changed(self: *Self, label: PeriphLabel, packet: Modem.PacketState) !void {
            try self.impl.modem_data_packet_state_changed(label, packet);
        }

        pub fn modem_data_apn_changed(self: *Self, label: PeriphLabel, apn: []const u8) !void {
            try self.impl.modem_data_apn_changed(label, apn);
        }

        pub fn modem_call_incoming(self: *Self, label: PeriphLabel, call: Modem.CallInfo) !void {
            try self.impl.modem_call_incoming(label, call);
        }

        pub fn modem_call_state_changed(self: *Self, label: PeriphLabel, call: Modem.CallStatus) !void {
            try self.impl.modem_call_state_changed(label, call);
        }

        pub fn modem_call_ended(self: *Self, label: PeriphLabel, call: Modem.CallEndInfo) !void {
            try self.impl.modem_call_ended(label, call);
        }

        pub fn modem_sms_received(self: *Self, label: PeriphLabel, sms: Modem.SmsMessage) !void {
            try self.impl.modem_sms_received(label, sms);
        }

        pub fn modem_gnss_state_changed(self: *Self, label: PeriphLabel, state: Modem.GnssState) !void {
            try self.impl.modem_gnss_state_changed(label, state);
        }

        pub fn modem_gnss_fix_changed(self: *Self, label: PeriphLabel, fix: Modem.GnssFix) !void {
            try self.impl.modem_gnss_fix_changed(label, fix);
        }

        pub fn set_led_strip_pixels(self: *Self, label: PeriphLabel, frame: FrameType, brightness: u8) !void {
            try self.impl.set_led_strip_pixels(label, frame, brightness);
        }

        pub fn set_led_strip_animated(
            self: *Self,
            label: PeriphLabel,
            frame: FrameType,
            brightness: u8,
            duration: u32,
        ) !void {
            try self.impl.set_led_strip_animated(label, frame, brightness, duration);
        }

        pub fn set_led_strip_flash(
            self: *Self,
            label: PeriphLabel,
            frame: FrameType,
            brightness: u8,
            duration_ns: u64,
            interval_ns: u64,
        ) !void {
            try self.impl.set_led_strip_flash(label, frame, brightness, duration_ns, interval_ns);
        }

        pub fn set_led_strip_pingpong(
            self: *Self,
            label: PeriphLabel,
            from_frame: FrameType,
            to_frame: FrameType,
            brightness: u8,
            duration_ns: u64,
            interval_ns: u64,
        ) !void {
            try self.impl.set_led_strip_pingpong(label, from_frame, to_frame, brightness, duration_ns, interval_ns);
        }

        pub fn set_led_strip_rotate(
            self: *Self,
            label: PeriphLabel,
            frame: FrameType,
            brightness: u8,
            duration_ns: u64,
            interval_ns: u64,
        ) !void {
            try self.impl.set_led_strip_rotate(label, frame, brightness, duration_ns, interval_ns);
        }

        pub fn nfc_found(self: *Self, label: PeriphLabel, uid: []const u8, card_type: Nfc.CardType) !void {
            try self.impl.nfc_found(label, uid, card_type);
        }

        pub fn nfc_read(self: *Self, label: PeriphLabel, uid: []const u8, payload: []const u8, card_type: Nfc.CardType) !void {
            try self.impl.nfc_read(label, uid, payload, card_type);
        }

        pub fn wifi_sta_scan_result(self: *Self, label: PeriphLabel, report: Wifi.Sta.ScanResult) !void {
            try self.impl.wifi_sta_scan_result(label, report);
        }

        pub fn wifi_sta_connected(self: *Self, label: PeriphLabel, info: Wifi.Sta.LinkInfo) !void {
            try self.impl.wifi_sta_connected(label, info);
        }

        pub fn wifi_sta_disconnected(self: *Self, label: PeriphLabel, info: Wifi.Sta.DisconnectInfo) !void {
            try self.impl.wifi_sta_disconnected(label, info);
        }

        pub fn wifi_sta_got_ip(self: *Self, label: PeriphLabel, info: Wifi.Sta.IpInfo) !void {
            try self.impl.wifi_sta_got_ip(label, info);
        }

        pub fn wifi_sta_lost_ip(self: *Self, label: PeriphLabel) !void {
            try self.impl.wifi_sta_lost_ip(label);
        }

        pub fn wifi_ap_started(self: *Self, label: PeriphLabel, info: Wifi.Ap.StartedInfo) !void {
            try self.impl.wifi_ap_started(label, info);
        }

        pub fn wifi_ap_stopped(self: *Self, label: PeriphLabel) !void {
            try self.impl.wifi_ap_stopped(label);
        }

        pub fn wifi_ap_client_joined(self: *Self, label: PeriphLabel, info: Wifi.Ap.ClientInfo) !void {
            try self.impl.wifi_ap_client_joined(label, info);
        }

        pub fn wifi_ap_client_left(self: *Self, label: PeriphLabel, info: Wifi.Ap.ClientInfo) !void {
            try self.impl.wifi_ap_client_left(label, info);
        }

        pub fn wifi_ap_lease_granted(self: *Self, label: PeriphLabel, info: Wifi.Ap.LeaseInfo) !void {
            try self.impl.wifi_ap_lease_granted(label, info);
        }

        pub fn wifi_ap_lease_released(self: *Self, label: PeriphLabel, info: Wifi.Ap.LeaseInfo) !void {
            try self.impl.wifi_ap_lease_released(label, info);
        }
    };

    return app;
}
