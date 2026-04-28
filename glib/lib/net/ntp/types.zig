const time_mod = @import("time");

pub const NTP_PORT: u16 = 123;
pub const NTP_UNIX_OFFSET: i64 = 2208988800;

pub const QueryError = error{
    Timeout,
    InvalidResponse,
    KissOfDeath,
    OriginMismatch,
    SourceMismatch,
    NoServerConfigured,
    Closed,
    OutOfMemory,
    SendFailed,
    RecvFailed,
};

pub const NtpTimestamp = struct {
    seconds: i64,
    fraction: u32,
};

pub const Response = struct {
    receive_timestamp: NtpTimestamp,
    transmit_timestamp: NtpTimestamp,
    receive_time: time_mod.Time,
    transmit_time: time_mod.Time,
    stratum: u8,
};
