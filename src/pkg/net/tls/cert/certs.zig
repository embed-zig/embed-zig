/// Embedded CA root certificates for TLS verification.
///
/// Each certificate is a PEM-encoded `[]const u8` available at comptime.
/// Usage:
///
///     const cert = @import("tls").cert;
///     const ca_pem = cert.isrg_root_x1;
///
/// Available presets (single roots):
///   - `isrg_root_x1`            - ISRG Root X1 (Let's Encrypt)
///   - `amazon_root_ca1`         - Amazon Root CA 1 (AWS services)
///   - `digicert_global_root_g2` - DigiCert Global Root G2
///
/// Available bundles:
///   - `cmn_ca_bundle`           - ESP-IDF common CA bundle (40 roots, ~54 KB)
///   - `mozilla_ca_bundle`       - Full Mozilla CA bundle (~130 roots, ~235 KB)
/// ISRG Root X1 - the root CA behind Let's Encrypt.
/// Covers most HTTPS sites using free Let's Encrypt certificates.
pub const isrg_root_x1: []const u8 = @embedFile("isrg_root_x1.pem");

/// Amazon Root CA 1 - root CA for AWS Certificate Manager
/// and many Amazon/CloudFront-hosted services.
pub const amazon_root_ca1: []const u8 = @embedFile("amazon_root_ca1.pem");

/// DigiCert Global Root G2 - widely trusted root CA.
/// Covers Azure, many enterprise services, and dl.espressif.com.
pub const digicert_global_root_g2: []const u8 = @embedFile("digicert_global_root_g2.pem");

/// Common CA bundle - the 40 most-used root CAs curated by ESP-IDF.
/// Covers Amazon, DigiCert, GlobalSign, GoDaddy, Google Trust Services,
/// IdenTrust, ISRG (Let's Encrypt), Sectigo/COMODO, and more.
/// Good balance between flash size (~54 KB) and coverage for public HTTPS.
pub const cmn_ca_bundle: []const u8 = @embedFile("cmn_ca_bundle.pem");

/// Full Mozilla CA bundle (~130 root certificates).
/// Use this when you need broad compatibility with any public HTTPS server.
/// Warning: ~235 KB - consider cmn_ca_bundle or a specific root if flash space is tight.
pub const mozilla_ca_bundle: []const u8 = @embedFile("mozilla_ca_bundle.pem");
