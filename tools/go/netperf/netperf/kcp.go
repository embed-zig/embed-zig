package netperf

import (
	"bufio"
	"fmt"
	"log"
	"net"
	"time"

	kcp "github.com/xtaci/kcp-go/v5"
)

const defaultKCPBufferSize = 4 * 1024 * 1024

func runKCPServer(control net.Conn, reader *bufio.Reader, req Request) (Result, error) {
	bind := udpBindAddr(control.LocalAddr())
	pc, err := net.ListenUDP(udpNetwork(bind), bind)
	if err != nil {
		return Result{}, err
	}
	defer pc.Close()
	setUDPBuffers(pc, defaultKCPBufferSize)
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
	session, err := kcp.NewConn3(req.Conv, remote, nil, 0, 0, pc)
	if err != nil {
		return Result{}, err
	}
	defer session.Close()
	configureKCP(session, req)

	var res Result
	switch req.Direction {
	case "down":
		res = sendKCPConn(session, req.Bytes, req.StreamChunk(), req.KCP.IntervalMS)
	case "up":
		res = recvConn(session, req.Bytes)
	case "duplex":
		res = duplexKCPConn(session, req.Bytes, req.StreamChunk(), req.KCP.IntervalMS)
	case "ping":
		res = pingKCPServer(session)
	default:
		return Result{}, fmt.Errorf("unsupported direction %q", req.Direction)
	}
	if err := finishServer(control, reader, req, res); err != nil {
		return Result{}, err
	}
	return res, nil
}

func runKCPClient(host string, port int, req Request) (Result, error) {
	remote, err := net.ResolveUDPAddr("udp", splitHostPort(host, port))
	if err != nil {
		return Result{}, err
	}
	pc, err := net.ListenUDP(udpNetwork(remote), nil)
	if err != nil {
		return Result{}, err
	}
	defer pc.Close()
	setUDPBuffers(pc, defaultKCPBufferSize)
	if err := sendHello(pc, remote, req.Conv); err != nil {
		return Result{}, err
	}
	started := time.Now()
	session, err := kcp.NewConn3(req.Conv, remote, nil, 0, 0, pc)
	if err != nil {
		return Result{}, err
	}
	defer session.Close()
	configureKCP(session, req)

	switch req.Direction {
	case "down":
		return recvConn(session, req.Bytes), nil
	case "up":
		return sendKCPConn(session, req.Bytes, req.StreamChunk(), req.KCP.IntervalMS), nil
	case "duplex":
		return duplexKCPConn(session, req.Bytes, req.StreamChunk(), req.KCP.IntervalMS), nil
	case "ping":
		return pingKCPClient(session, started), nil
	default:
		return Result{}, fmt.Errorf("unsupported direction %q", req.Direction)
	}
}

func sendKCPConn(conn net.Conn, bytesTotal int, chunk int, intervalMS int) Result {
	payload := make([]byte, min(chunk, DefaultStreamChunk))
	fillPattern(payload)
	started := time.Now()
	var sent int
	var packets uint32
	for sent < bytesTotal {
		n := min(len(payload), bytesTotal-sent)
		written, err := conn.Write(payload[:n])
		sent += written
		packets++
		if err != nil {
			return Result{SentBytes: sent, ElapsedNS: elapsedNS(started), Errors: 1, Packets: packets}
		}
		if written != n {
			return Result{SentBytes: sent, ElapsedNS: elapsedNS(started), Errors: 1, Packets: packets}
		}
	}
	time.Sleep(time.Duration(max(1, intervalMS)) * time.Millisecond)
	return Result{SentBytes: sent, ElapsedNS: elapsedNS(started), Packets: packets}
}

func duplexKCPConn(conn net.Conn, bytesTotal int, chunk int, intervalMS int) Result {
	type out struct {
		res Result
	}
	sendCh := make(chan out, 1)
	recvCh := make(chan out, 1)
	go func() { sendCh <- out{res: sendKCPConn(conn, bytesTotal, chunk, intervalMS)} }()
	go func() { recvCh <- out{res: recvConn(conn, bytesTotal)} }()
	sendRes := (<-sendCh).res
	recvRes := (<-recvCh).res
	return mergeResults(sendRes, recvRes)
}

func configureKCP(session *kcp.UDPSession, req Request) {
	if ok := session.SetMtu(req.UDPPayload()); !ok {
		log.Printf("set kcp mtu failed")
	}
	session.SetWindowSize(req.KCP.SendWindow, req.KCP.RecvWindow)
	session.SetNoDelay(req.KCP.NoDelay, req.KCP.IntervalMS, req.KCP.Resend, req.KCP.NoCongestionControl)
	session.SetStreamMode(req.WireProtocol() == "ikcp-stream")
	session.SetACKNoDelay(false)
	session.SetWriteDelay(false)
}

func setUDPBuffers(conn *net.UDPConn, size int) {
	if err := conn.SetReadBuffer(size); err != nil {
		log.Printf("set udp read buffer failed: %v", err)
	}
	if err := conn.SetWriteBuffer(size); err != nil {
		log.Printf("set udp write buffer failed: %v", err)
	}
}

func udpNetwork(addr *net.UDPAddr) string {
	if addr != nil && addr.IP != nil && addr.IP.To4() == nil {
		return "udp6"
	}
	return "udp4"
}
