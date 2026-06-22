const modem_api = @import("drivers");

pub const max_apn_len = modem_api.Modem.max_apn_len;
pub const max_identity_len = modem_api.Modem.max_identity_len;
pub const max_phone_number_len = modem_api.Modem.max_phone_number_len;
pub const max_sms_text_len = modem_api.Modem.max_sms_text_len;

pub const Rat = modem_api.Modem.Rat;
pub const SimState = modem_api.Modem.SimState;
pub const RegistrationState = modem_api.Modem.RegistrationState;
pub const PacketState = modem_api.Modem.PacketState;
pub const SignalInfo = modem_api.Modem.SignalInfo;
pub const CallDirection = modem_api.Modem.CallDirection;
pub const CallState = modem_api.Modem.CallState;
pub const CallEndReason = modem_api.Modem.CallEndReason;
pub const CallInfo = modem_api.Modem.CallInfo;
pub const CallStatus = modem_api.Modem.CallStatus;
pub const CallEndInfo = modem_api.Modem.CallEndInfo;
pub const SmsStorage = modem_api.Modem.SmsStorage;
pub const SmsEncoding = modem_api.Modem.SmsEncoding;
pub const SmsMessage = modem_api.Modem.SmsMessage;
pub const GnssState = modem_api.Modem.GnssState;
pub const GnssFixQuality = modem_api.Modem.GnssFixQuality;
pub const GnssFix = modem_api.Modem.GnssFix;

pub const SimStateChanged = struct {
    pub const kind = .modem_sim_state_changed;

    source_id: u32,
    sim: SimState,
};

pub const NetworkRegistrationChanged = struct {
    pub const kind = .modem_network_registration_changed;

    source_id: u32,
    registration: RegistrationState,
};

pub const NetworkSignalChanged = struct {
    pub const kind = .modem_network_signal_changed;

    source_id: u32,
    signal: SignalInfo,
};

pub const IdentityChanged = struct {
    pub const kind = .modem_identity_changed;

    source_id: u32,
    imei_end: u8,
    imei_buf: [max_identity_len]u8,
    imsi_end: u8,
    imsi_buf: [max_identity_len]u8,

    pub fn imei(self: *const @This()) []const u8 {
        return self.imei_buf[0..self.imei_end];
    }

    pub fn imsi(self: *const @This()) []const u8 {
        return self.imsi_buf[0..self.imsi_end];
    }
};

pub const DataPacketStateChanged = struct {
    pub const kind = .modem_data_packet_state_changed;

    source_id: u32,
    packet: PacketState,
};

pub const DataApnChanged = struct {
    pub const kind = .modem_data_apn_changed;

    source_id: u32,
    apn_end: u8,
    apn_buf: [max_apn_len]u8,

    pub fn apn(self: *const @This()) []const u8 {
        return self.apn_buf[0..self.apn_end];
    }
};

pub const CallIncoming = struct {
    pub const kind = .modem_call_incoming;

    source_id: u32,
    call_id: u8,
    direction: CallDirection,
    number_end: u8,
    number_buf: [max_phone_number_len]u8,

    pub fn number(self: *const @This()) []const u8 {
        return self.number_buf[0..self.number_end];
    }
};

pub const CallStateChanged = struct {
    pub const kind = .modem_call_state_changed;

    source_id: u32,
    call_id: u8,
    direction: CallDirection,
    state: CallState,
    number_end: u8,
    number_buf: [max_phone_number_len]u8,

    pub fn number(self: *const @This()) []const u8 {
        return self.number_buf[0..self.number_end];
    }
};

pub const CallEnded = struct {
    pub const kind = .modem_call_ended;

    source_id: u32,
    call_id: u8,
    reason: CallEndReason,
};

pub const SmsReceived = struct {
    pub const kind = .modem_sms_received;

    source_id: u32,
    index: ?u16,
    storage: SmsStorage,
    sender_end: u8,
    sender_buf: [max_phone_number_len]u8,
    text_end: u16,
    text_buf: [max_sms_text_len]u8,
    encoding: SmsEncoding,

    pub fn sender(self: *const @This()) []const u8 {
        return self.sender_buf[0..self.sender_end];
    }

    pub fn text(self: *const @This()) []const u8 {
        return self.text_buf[0..self.text_end];
    }
};

pub const GnssStateChanged = struct {
    pub const kind = .modem_gnss_state_changed;

    source_id: u32,
    state: GnssState,
};

pub const GnssFixChanged = struct {
    pub const kind = .modem_gnss_fix_changed;

    source_id: u32,
    fix: GnssFix,
};

pub const Event = modem_api.Modem.Event;
pub const CallbackFn = modem_api.Modem.CallbackFn;

pub fn make(comptime EventType: type, source_id: u32, adapter_event: Event) !EventType {
    return switch (adapter_event) {
        .sim => |value| switch (value) {
            .state_changed => |sim| .{
                .modem_sim_state_changed = .{
                    .source_id = source_id,
                    .sim = sim,
                },
            },
        },
        .network => |value| switch (value) {
            .registration_changed => |registration| .{
                .modem_network_registration_changed = .{
                    .source_id = source_id,
                    .registration = registration,
                },
            },
            .signal_changed => |signal| .{
                .modem_network_signal_changed = .{
                    .source_id = source_id,
                    .signal = signal,
                },
            },
        },
        .data => |value| switch (value) {
            .packet_state_changed => |packet| .{
                .modem_data_packet_state_changed = .{
                    .source_id = source_id,
                    .packet = packet,
                },
            },
            .apn_changed => |apn| .{
                .modem_data_apn_changed = .{
                    .source_id = source_id,
                    .apn_end = try copyApnLen(apn),
                    .apn_buf = try copyApnBuf(apn),
                },
            },
        },
        .call => |value| switch (value) {
            .incoming => |call| .{
                .modem_call_incoming = .{
                    .source_id = source_id,
                    .call_id = call.call_id,
                    .direction = call.direction,
                    .number_end = try copyPhoneLen(sliceOrEmpty(call.number)),
                    .number_buf = try copyPhoneBuf(sliceOrEmpty(call.number)),
                },
            },
            .state_changed => |call| .{
                .modem_call_state_changed = .{
                    .source_id = source_id,
                    .call_id = call.call_id,
                    .direction = call.direction,
                    .state = call.state,
                    .number_end = try copyPhoneLen(sliceOrEmpty(call.number)),
                    .number_buf = try copyPhoneBuf(sliceOrEmpty(call.number)),
                },
            },
            .ended => |call| .{
                .modem_call_ended = .{
                    .source_id = source_id,
                    .call_id = call.call_id,
                    .reason = call.reason,
                },
            },
        },
        .sms => |value| switch (value) {
            .received => |sms| .{
                .modem_sms_received = .{
                    .source_id = source_id,
                    .index = sms.index,
                    .storage = sms.storage,
                    .sender_end = try copyPhoneLen(sliceOrEmpty(sms.sender)),
                    .sender_buf = try copyPhoneBuf(sliceOrEmpty(sms.sender)),
                    .text_end = try copySmsTextLen(sms.text),
                    .text_buf = try copySmsTextBuf(sms.text),
                    .encoding = sms.encoding,
                },
            },
        },
        .gnss => |value| switch (value) {
            .state_changed => |state| .{
                .modem_gnss_state_changed = .{
                    .source_id = source_id,
                    .state = state,
                },
            },
            .fix_changed => |fix| .{
                .modem_gnss_fix_changed = .{
                    .source_id = source_id,
                    .fix = fix,
                },
            },
        },
    };
}

fn sliceOrEmpty(value: ?[]const u8) []const u8 {
    return value orelse "";
}

fn copyApnLen(value: []const u8) !u8 {
    if (value.len > max_apn_len) return error.InvalidApnLength;
    return @intCast(value.len);
}

fn copyApnBuf(value: []const u8) ![max_apn_len]u8 {
    if (value.len > max_apn_len) return error.InvalidApnLength;

    var buf = [_]u8{0} ** max_apn_len;
    @memcpy(buf[0..value.len], value);
    return buf;
}

pub fn copyIdentityLen(value: []const u8) !u8 {
    if (value.len > max_identity_len) return error.InvalidIdentityLength;
    return @intCast(value.len);
}

pub fn copyIdentityBuf(value: []const u8) ![max_identity_len]u8 {
    if (value.len > max_identity_len) return error.InvalidIdentityLength;

    var buf = [_]u8{0} ** max_identity_len;
    @memcpy(buf[0..value.len], value);
    return buf;
}

fn copyPhoneLen(value: []const u8) !u8 {
    if (value.len > max_phone_number_len) return error.InvalidPhoneNumberLength;
    return @intCast(value.len);
}

fn copyPhoneBuf(value: []const u8) ![max_phone_number_len]u8 {
    if (value.len > max_phone_number_len) return error.InvalidPhoneNumberLength;

    var buf = [_]u8{0} ** max_phone_number_len;
    @memcpy(buf[0..value.len], value);
    return buf;
}

fn copySmsTextLen(value: []const u8) !u16 {
    if (value.len > max_sms_text_len) return error.InvalidSmsTextLength;
    return @intCast(value.len);
}

fn copySmsTextBuf(value: []const u8) ![max_sms_text_len]u8 {
    if (value.len > max_sms_text_len) return error.InvalidSmsTextLength;

    var buf = [_]u8{0} ** max_sms_text_len;
    @memcpy(buf[0..value.len], value);
    return buf;
}
