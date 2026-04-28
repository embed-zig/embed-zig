const c = @import("c.zig").c;

pub const Error = error{
    AllocatorRequired,
    AuthFailed,
    BadState,
    BufferTooSmall,
    CommunicationFailure,
    CorruptionDetected,
    DoesNotExist,
    GenericError,
    InsufficientData,
    InsufficientEntropy,
    InsufficientMemory,
    InvalidArgument,
    InvalidHandle,
    InvalidPadding,
    InvalidSignature,
    InvalidCertificate,
    NotPermitted,
    NotSupported,
    PsaError,
    TlsWantRead,
    TlsWantWrite,
    Unsupported,
    StorageFailure,
    MbedTlsError,
};

pub fn check(status: c.psa_status_t) Error!void {
    if (status == c.PSA_SUCCESS) return;
    return fromStatus(status);
}

pub fn checkMbed(status: c_int) Error!void {
    if (status == 0) return;
    return fromMbed(status);
}

pub fn unsupportedIf(condition: bool) Error!void {
    if (condition) return Error.Unsupported;
}

pub fn fromStatus(status: c.psa_status_t) Error {
    return switch (status) {
        c.PSA_ERROR_BAD_STATE => Error.BadState,
        c.PSA_ERROR_BUFFER_TOO_SMALL => Error.BufferTooSmall,
        c.PSA_ERROR_COMMUNICATION_FAILURE => Error.CommunicationFailure,
        c.PSA_ERROR_CORRUPTION_DETECTED => Error.CorruptionDetected,
        c.PSA_ERROR_DOES_NOT_EXIST => Error.DoesNotExist,
        c.PSA_ERROR_GENERIC_ERROR => Error.GenericError,
        c.PSA_ERROR_INSUFFICIENT_DATA => Error.InsufficientData,
        c.PSA_ERROR_INSUFFICIENT_ENTROPY => Error.InsufficientEntropy,
        c.PSA_ERROR_INSUFFICIENT_MEMORY => Error.InsufficientMemory,
        c.PSA_ERROR_INVALID_ARGUMENT => Error.InvalidArgument,
        c.PSA_ERROR_INVALID_HANDLE => Error.InvalidHandle,
        c.PSA_ERROR_INVALID_PADDING => Error.InvalidPadding,
        c.PSA_ERROR_INVALID_SIGNATURE => Error.InvalidSignature,
        c.PSA_ERROR_NOT_PERMITTED => Error.NotPermitted,
        c.PSA_ERROR_NOT_SUPPORTED => Error.NotSupported,
        c.PSA_ERROR_STORAGE_FAILURE => Error.StorageFailure,
        else => Error.PsaError,
    };
}

pub fn fromMbed(status: c_int) Error {
    return switch (status) {
        c.MBEDTLS_ERR_SSL_WANT_READ => Error.TlsWantRead,
        c.MBEDTLS_ERR_SSL_WANT_WRITE => Error.TlsWantWrite,
        c.MBEDTLS_ERR_X509_CERT_VERIFY_FAILED => Error.InvalidCertificate,
        c.MBEDTLS_ERR_X509_INVALID_FORMAT => Error.InvalidArgument,
        c.MBEDTLS_ERR_PEM_NO_HEADER_FOOTER_PRESENT => Error.InvalidArgument,
        c.MBEDTLS_ERR_PK_BAD_INPUT_DATA => Error.InvalidArgument,
        else => Error.MbedTlsError,
    };
}
