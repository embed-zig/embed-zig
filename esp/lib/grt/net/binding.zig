pub const netconn = opaque {};
pub const netbuf = opaque {};

pub const ip_addr = extern struct {
    is_ipv6: u8,
    bytes: [16]u8,
    zone: u32,
};

pub const netconn_event_rcvplus: c_int = 0;
pub const netconn_event_rcvminus: c_int = 1;
pub const netconn_event_sendplus: c_int = 2;
pub const netconn_event_sendminus: c_int = 3;
pub const netconn_event_error: c_int = 4;

pub const netconn_tcp: u32 = 0x10;
pub const netconn_tcp_ipv6: u32 = 0x18;
pub const netconn_udp: u32 = 0x20;
pub const netconn_udp_ipv6: u32 = 0x28;

pub const err_ok: c_int = 0;
pub const err_mem: c_int = -1;
pub const err_buf: c_int = -2;
pub const err_timeout: c_int = -3;
pub const err_rte: c_int = -4;
pub const err_inprogress: c_int = -5;
pub const err_val: c_int = -6;
pub const err_wouldblock: c_int = -7;
pub const err_use: c_int = -8;
pub const err_already: c_int = -9;
pub const err_isconn: c_int = -10;
pub const err_conn: c_int = -11;
pub const err_if: c_int = -12;
pub const err_abrt: c_int = -13;
pub const err_rst: c_int = -14;
pub const err_clsd: c_int = -15;
pub const err_arg: c_int = -16;

pub extern fn espz_lwip_netconn_new(netconn_type: u32, ctx: ?*anyopaque) ?*netconn;
pub extern fn espz_lwip_netconn_set_callback_arg(conn: *netconn, ctx: ?*anyopaque) void;
pub extern fn espz_lwip_netconn_set_nonblocking(conn: *netconn, enabled: u32) void;
pub extern fn espz_lwip_netconn_delete(conn: *netconn) c_int;
pub extern fn espz_lwip_netconn_close(conn: *netconn) c_int;
pub extern fn espz_lwip_netconn_shutdown(conn: *netconn, shut_rx: u32, shut_tx: u32) c_int;
pub extern fn espz_lwip_netconn_bind(conn: *netconn, addr: *const ip_addr, port: u16) c_int;
pub extern fn espz_lwip_netconn_connect(conn: *netconn, addr: *const ip_addr, port: u16) c_int;
pub extern fn espz_lwip_netconn_listen(conn: *netconn, backlog: u32) c_int;
pub extern fn espz_lwip_netconn_accept(conn: *netconn, out: **netconn) c_int;
pub extern fn espz_lwip_netconn_recv(conn: *netconn, out: **netbuf) c_int;
pub extern fn espz_lwip_netconn_write(conn: *netconn, data: ?*const anyopaque, len: usize, written: *usize) c_int;
pub extern fn espz_lwip_netconn_send_to(conn: *netconn, data: ?*const anyopaque, len: usize, addr: *const ip_addr, port: u16) c_int;
pub extern fn espz_lwip_netconn_send(conn: *netconn, data: ?*const anyopaque, len: usize) c_int;
pub extern fn espz_lwip_netconn_get_addr(conn: *netconn, local: u32, addr: *ip_addr, port: *u16) c_int;
pub extern fn espz_lwip_netconn_err(conn: *netconn) c_int;
pub extern fn espz_lwip_netbuf_delete(buf: *netbuf) void;
pub extern fn espz_lwip_netbuf_len(buf: *netbuf) usize;
pub extern fn espz_lwip_netbuf_copy(buf: *netbuf, offset: usize, dst: ?*anyopaque, len: usize) usize;
pub extern fn espz_lwip_netbuf_from_addr(buf: *netbuf, addr: *ip_addr, port: *u16) void;
pub extern fn espz_lwip_netconn_set_socket_reuse_addr(conn: *netconn, enabled: c_int) c_int;
pub extern fn espz_lwip_netconn_set_socket_broadcast(conn: *netconn, enabled: c_int) c_int;
pub extern fn espz_lwip_netconn_set_tcp_no_delay(conn: *netconn, enabled: c_int) c_int;
