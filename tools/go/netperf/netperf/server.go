package netperf

import (
	"bufio"
	"context"
	"fmt"
	"log"
	"net"
	"strconv"
	"time"
)

const (
	defaultListen = "0.0.0.0:9821"
	idleTimeout   = 5 * time.Second
)

func Serve(ctx context.Context, addr string) error {
	if addr == "" {
		addr = defaultListen
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	defer ln.Close()
	log.Printf("netperf-go server listening on %s", addr)

	go func() {
		<-ctx.Done()
		_ = ln.Close()
	}()

	for {
		conn, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return err
		}
		go func() {
			defer conn.Close()
			res, err := handleServerConn(conn)
			if err != nil {
				log.Printf("session failed: %v", err)
				return
			}
			log.Printf("result sent=%d recv=%d elapsed_ns=%d mbps=%.3f packets=%d errors=%d first_byte_ns=%d rtt_ns=%d",
				res.SentBytes, res.ReceivedBytes, res.ElapsedNS, res.Mbps(), res.Packets, res.Errors, res.FirstByteNS, res.RTTNS)
		}()
	}
}

func handleServerConn(control net.Conn) (Result, error) {
	reader := bufio.NewReaderSize(control, MaxLineLen)
	line, err := ReadLine(reader)
	if err != nil {
		return Result{}, err
	}
	req, err := ParseRequest(line)
	if err != nil {
		return Result{}, err
	}
	log.Printf("request protocol=%s direction=%s bytes=%d", req.WireProtocol(), req.Direction, req.Bytes)
	switch req.WireProtocol() {
	case "tcp":
		return runTCPServer(control, reader, req)
	case "udp":
		return runUDPServer(control, reader, req)
	case "ikcp-stream", "ikcp-packet":
		return runKCPServer(control, reader, req)
	default:
		return Result{}, fmt.Errorf("unsupported protocol %q", req.Protocol)
	}
}

func runTCPServer(control net.Conn, reader *bufio.Reader, req Request) (Result, error) {
	ln, err := net.Listen("tcp", dataBindAddr(control.LocalAddr()))
	if err != nil {
		return Result{}, err
	}
	defer ln.Close()
	port := ln.Addr().(*net.TCPAddr).Port
	time.Sleep(100 * time.Millisecond)
	if _, err := fmt.Fprint(control, Ready{TCPPort: port, Conv: req.Conv}.Line()); err != nil {
		return Result{}, err
	}
	data, err := ln.Accept()
	if err != nil {
		return Result{}, err
	}
	defer data.Close()
	if tcp, ok := data.(*net.TCPConn); ok && req.KCP.NoDelay != 0 {
		_ = tcp.SetNoDelay(true)
	}

	var res Result
	switch req.Direction {
	case "down":
		res = sendConn(data, req.Bytes, req.StreamChunk())
	case "up":
		res = recvConn(data, req.Bytes)
	case "duplex":
		res = duplexConn(data, req.Bytes, req.StreamChunk())
	case "ping":
		res = pingConnServer(data)
	default:
		return Result{}, fmt.Errorf("unsupported direction %q", req.Direction)
	}
	if err := finishServer(control, reader, req, res); err != nil {
		return Result{}, err
	}
	return res, nil
}

func runUDPServer(control net.Conn, reader *bufio.Reader, req Request) (Result, error) {
	pc, err := net.ListenUDP("udp", udpBindAddr(control.LocalAddr()))
	if err != nil {
		return Result{}, err
	}
	defer pc.Close()
	port := pc.LocalAddr().(*net.UDPAddr).Port
	time.Sleep(100 * time.Millisecond)
	if _, err := fmt.Fprint(control, Ready{UDPPort: port, Conv: req.Conv}.Line()); err != nil {
		return Result{}, err
	}
	remote, err := waitHello(pc, req.Conv, idleTimeout)
	if err != nil {
		return Result{}, err
	}
	drainHelloPackets(pc, req.Conv)

	var res Result
	switch req.Direction {
	case "down":
		res = sendPacket(pc, remote, req.Bytes, req.UDPPayload(), req.UDPPPS)
	case "up":
		res = recvPacket(pc, req.Bytes, req.UDPPayload())
	case "duplex":
		res = duplexPacket(pc, remote, req.Bytes, req.UDPPayload(), req.UDPPPS)
	case "ping":
		res = pingPacketServer(pc, remote)
	default:
		return Result{}, fmt.Errorf("unsupported direction %q", req.Direction)
	}
	if err := finishServer(control, reader, req, res); err != nil {
		return Result{}, err
	}
	return res, nil
}

func drainHelloPackets(conn *net.UDPConn, conv uint32) {
	want := stringsTrimLine(HelloLine(conv))
	buf := make([]byte, MaxLineLen)
	_ = conn.SetReadDeadline(time.Now().Add(20 * time.Millisecond))
	defer conn.SetReadDeadline(time.Time{})
	for {
		n, _, err := conn.ReadFromUDP(buf)
		if err != nil {
			return
		}
		if stringsTrimLine(string(buf[:n])) != want {
			return
		}
	}
}

func finishServer(control net.Conn, reader *bufio.Reader, req Request, serverResult Result) error {
	for {
		line, err := ReadLine(reader)
		if err != nil {
			return err
		}
		if IsDiagLine(line) {
			log.Printf("client_diag %s", stringsTrimLine(line))
			continue
		}
		clientResult, err := ParseStop(line)
		if err != nil {
			return err
		}
		log.Printf("client_result sent=%d recv=%d elapsed_ns=%d mbps=%.3f packets=%d errors=%d first_byte_ns=%d rtt_ns=%d",
			clientResult.SentBytes, clientResult.ReceivedBytes, clientResult.ElapsedNS, clientResult.Mbps(), clientResult.Packets, clientResult.Errors, clientResult.FirstByteNS, clientResult.RTTNS)
		if req.Protocol == "udp" {
			logUDPLoss(req, serverResult, clientResult)
		}
		_, err = fmt.Fprint(control, serverResult.ResultLine("server"))
		return err
	}
}

func logUDPLoss(req Request, serverResult Result, clientResult Result) {
	var expected int
	var got int
	switch req.Direction {
	case "down":
		expected = serverResult.SentBytes
		got = clientResult.ReceivedBytes
	case "up":
		expected = clientResult.SentBytes
		got = serverResult.ReceivedBytes
	case "duplex":
		logUDPLoss(Request{Direction: "up"}, serverResult, clientResult)
		logUDPLoss(Request{Direction: "down"}, serverResult, clientResult)
		return
	default:
		return
	}
	lost := expected - got
	if lost < 0 {
		lost = 0
	}
	ratio := 0.0
	if expected > 0 {
		ratio = float64(lost) * 100 / float64(expected)
	}
	log.Printf("udp_loss direction=%s expected=%d got=%d lost=%d loss=%.2f%%", req.Direction, expected, got, lost, ratio)
}

func dataBindAddr(addr net.Addr) string {
	host := "0.0.0.0"
	if tcp, ok := addr.(*net.TCPAddr); ok && tcp.IP.To4() == nil {
		host = "::"
	}
	return net.JoinHostPort(host, "0")
}

func udpBindAddr(addr net.Addr) *net.UDPAddr {
	if tcp, ok := addr.(*net.TCPAddr); ok && tcp.IP != nil && !tcp.IP.IsUnspecified() {
		return &net.UDPAddr{IP: tcp.IP, Port: 0}
	}
	if tcp, ok := addr.(*net.TCPAddr); ok && tcp.IP.To4() == nil {
		return &net.UDPAddr{IP: net.IPv6zero, Port: 0}
	}
	return &net.UDPAddr{IP: net.IPv4zero, Port: 0}
}

func splitHostPort(host string, port int) string {
	return net.JoinHostPort(host, strconv.Itoa(port))
}
