//! HCI status/error codes (Bluetooth Core Spec Vol 2 Part D).
//!
//! Pure constants — no state, no I/O.

pub const Status = enum(u8) {
    success = 0x00,
    unknown_command = 0x01,
    no_connection = 0x02,
    hardware_failure = 0x03,
    page_timeout = 0x04,
    authentication_failure = 0x05,
    key_missing = 0x06,
    memory_full = 0x07,
    connection_timeout = 0x08,
    max_connections = 0x09,
    max_sco_connections = 0x0A,
    acl_exists = 0x0B,
    command_disallowed = 0x0C,
    rejected_limited_resources = 0x0D,
    rejected_security = 0x0E,
    rejected_bd_addr = 0x0F,
    connection_accept_timeout = 0x10,
    unsupported_feature = 0x11,
    invalid_parameters = 0x12,
    remote_user_terminated = 0x13,
    remote_low_resources = 0x14,
    remote_power_off = 0x15,
    local_host_terminated = 0x16,
    repeated_attempts = 0x17,
    pairing_not_allowed = 0x18,
    unknown_lmp_pdu = 0x19,
    unsupported_remote_feature = 0x1A,
    sco_offset_rejected = 0x1B,
    sco_interval_rejected = 0x1C,
    sco_air_mode_rejected = 0x1D,
    invalid_lmp_parameters = 0x1E,
    unspecified_error = 0x1F,
    unsupported_lmp_value = 0x20,
    role_change_not_allowed = 0x21,
    lmp_response_timeout = 0x22,
    lmp_transaction_collision = 0x23,
    lmp_pdu_not_allowed = 0x24,
    encryption_mode_not_acceptable = 0x25,
    unit_key_used = 0x26,
    qos_not_supported = 0x27,
    instant_passed = 0x28,
    pairing_unit_key_not_supported = 0x29,
    different_transaction_collision = 0x2A,
    qos_unacceptable_parameter = 0x2C,
    qos_rejected = 0x2D,
    channel_classification_not_supported = 0x2E,
    insufficient_security = 0x2F,
    parameter_out_of_range = 0x30,
    role_switch_pending = 0x32,
    reserved_slot_violation = 0x34,
    role_switch_failed = 0x35,
    extended_inquiry_response_too_large = 0x36,
    simple_pairing_not_supported = 0x37,
    host_busy_pairing = 0x38,
    connection_rejected_no_channel = 0x39,
    controller_busy = 0x3A,
    unacceptable_connection_parameters = 0x3B,
    advertising_timeout = 0x3C,
    connection_terminated_mic_failure = 0x3D,
    connection_failed_to_establish = 0x3E,
    coarse_clock_adjustment_rejected = 0x40,
    type0_submap_not_defined = 0x41,
    unknown_advertising_identifier = 0x42,
    limit_reached = 0x43,
    operation_cancelled_by_host = 0x44,
    packet_too_long = 0x45,
    _,

    pub fn isSuccess(self: Status) bool {
        return self == .success;
    }

    pub fn fromByte(byte: u8) Status {
        return @enumFromInt(byte);
    }
};

test "bt/unit_tests/host/hci/status/basics" {
    const s = Status.success;
    try @import("std").testing.expect(s.isSuccess());
    try @import("std").testing.expect(!Status.connection_timeout.isSuccess());
    try @import("std").testing.expectEqual(Status.remote_user_terminated, Status.fromByte(0x13));
    try @import("std").testing.expectEqual(@as(u8, 0x08), @intFromEnum(Status.connection_timeout));
}
