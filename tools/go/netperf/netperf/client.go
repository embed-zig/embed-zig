package netperf

import (
	"bufio"
	"context"
	"fmt"
	"log"
	"net"
	"strings"
	"time"
)

func RunClient(ctx context.Context, host string, port int, req Request) error {
	if req.Direction == "all" {
		for _, direction := range []string{"up", "down", "duplex", "ping"} {
			child := req
			child.Direction = direction
			if err := runClientOnce(ctx, host, port, child); err != nil {
				return err
			}
		}
		return nil
	}
	return runClientOnce(ctx, host, port, req)
}

func runClientOnce(ctx context.Context, host string, port int, req Request) error {
	_ = ctx
	control, err := net.Dial("tcp", splitHostPort(host, port))
	if err != nil {
		return err
	}
	defer control.Close()
	if tcp, ok := control.(*net.TCPConn); ok && req.KCP.NoDelay != 0 {
		_ = tcp.SetNoDelay(true)
	}
	reader := bufio.NewReaderSize(control, MaxLineLen)
	if _, err := fmt.Fprint(control, req.RequestLine()); err != nil {
		return err
	}
	line, err := ReadLine(reader)
	if err != nil {
		return err
	}
	ready, err := ParseReady(line)
	if err != nil {
		return err
	}
	log.Printf("ready protocol=%s direction=%s tcp=%d udp=%d", req.WireProtocol(), req.Direction, ready.TCPPort, ready.UDPPort)

	var client Result
	switch req.WireProtocol() {
	case "tcp":
		client, err = runTCPClient(host, ready.TCPPort, req)
	case "udp":
		client, err = runUDPClient(host, ready.UDPPort, req)
	case "ikcp-stream", "ikcp-packet":
		client, err = runKCPClient(host, ready.UDPPort, req)
	default:
		err = fmt.Errorf("unsupported protocol %q", req.Protocol)
	}
	if err != nil {
		return err
	}
	if _, err := fmt.Fprint(control, client.StopLine()); err != nil {
		return err
	}
	serverLine, err := ReadLine(reader)
	if err != nil {
		return err
	}
	server, err := ParseResult(serverLine)
	if err != nil {
		return err
	}
	log.Printf("netperf %s/%s client sent=%d recv=%d elapsed_ns=%d mbps=%.3f packets=%d errors=%d first_byte_ns=%d rtt_ns=%d",
		req.WireProtocol(), req.Direction, client.SentBytes, client.ReceivedBytes, client.ElapsedNS, client.Mbps(), client.Packets, client.Errors, client.FirstByteNS, client.RTTNS)
	log.Printf("netperf %s/%s server sent=%d recv=%d elapsed_ns=%d mbps=%.3f packets=%d errors=%d first_byte_ns=%d rtt_ns=%d",
		req.WireProtocol(), req.Direction, server.SentBytes, server.ReceivedBytes, server.ElapsedNS, server.Mbps(), server.Packets, server.Errors, server.FirstByteNS, server.RTTNS)
	log.Printf("netperf %s/%s summary mbps=%.3f sent=%d recv=%d",
		req.WireProtocol(), req.Direction, summaryMbps(req.Direction, client, server), client.SentBytes+server.SentBytes, client.ReceivedBytes+server.ReceivedBytes)
	return nil
}

func runTCPClient(host string, port int, req Request) (Result, error) {
	started := time.Now()
	conn, err := net.Dial("tcp", splitHostPort(host, port))
	if err != nil {
		return Result{}, err
	}
	defer conn.Close()
	if tcp, ok := conn.(*net.TCPConn); ok && req.KCP.NoDelay != 0 {
		_ = tcp.SetNoDelay(true)
	}
	switch req.Direction {
	case "down":
		return recvConn(conn, req.Bytes), nil
	case "up":
		return sendConn(conn, req.Bytes, req.StreamChunk()), nil
	case "duplex":
		return duplexConn(conn, req.Bytes, req.StreamChunk()), nil
	case "ping":
		return pingConnClient(conn, started), nil
	default:
		return Result{}, fmt.Errorf("unsupported direction %q", req.Direction)
	}
}

func runUDPClient(host string, port int, req Request) (Result, error) {
	remote, err := net.ResolveUDPAddr("udp", splitHostPort(host, port))
	if err != nil {
		return Result{}, err
	}
	conn, err := net.ListenUDP("udp", nil)
	if err != nil {
		return Result{}, err
	}
	defer conn.Close()
	if err := sendHello(conn, remote, req.Conv); err != nil {
		return Result{}, err
	}
	switch req.Direction {
	case "down":
		return recvPacket(conn, req.Bytes, req.UDPPayload()), nil
	case "up":
		return sendPacket(conn, remote, req.Bytes, req.UDPPayload(), req.UDPPPS), nil
	case "duplex":
		return duplexPacket(conn, remote, req.Bytes, req.UDPPayload(), req.UDPPPS), nil
	case "ping":
		return pingPacketClient(conn, remote, time.Now()), nil
	default:
		return Result{}, fmt.Errorf("unsupported direction %q", req.Direction)
	}
}

func summaryMbps(direction string, client Result, server Result) float64 {
	switch direction {
	case "down":
		return client.Mbps()
	case "up":
		return server.Mbps()
	case "duplex":
		if client.Mbps() < server.Mbps() {
			return client.Mbps()
		}
		return server.Mbps()
	case "ping":
		return client.Mbps()
	default:
		if strings.TrimSpace(direction) == "" {
			return 0
		}
		return client.Mbps()
	}
}
