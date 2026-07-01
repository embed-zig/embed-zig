const cmdctl = @import("cmdctl");

test "tools/cmdctl/unit" {
    try cmdctl.testParseTcpDefaults();
    try cmdctl.testParseServeTcpDefaults();
    try cmdctl.testParseSerialExec();
    try cmdctl.testParseSerialBaud();
    try cmdctl.testParseBtAddr();
    try cmdctl.testParseUuid16();
}
