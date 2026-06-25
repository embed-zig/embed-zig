package netperf

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"time"
)

const (
	transferTimeout = 180 * time.Second
	udpIdleTimeout  = 2 * time.Second
	tcpReadChunk    = 1440
	pingPayloadSize = 8
)

func sendConn(conn net.Conn, bytesTotal int, chunk int) Result {
	payload := make([]byte, min(chunk, DefaultStreamChunk))
	fillPattern(payload)
	started := time.Now()
	_ = conn.SetWriteDeadline(started.Add(transferTimeout))
	defer conn.SetWriteDeadline(time.Time{})
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
	return Result{SentBytes: sent, ElapsedNS: elapsedNS(started), Packets: packets}
}

func recvConn(conn net.Conn, bytesTotal int) Result {
	buf := make([]byte, tcpReadChunk)
	started := time.Now()
	_ = conn.SetReadDeadline(started.Add(transferTimeout))
	defer conn.SetReadDeadline(time.Time{})
	var received int
	var packets uint32
	for received < bytesTotal {
		n, err := conn.Read(buf[:min(len(buf), bytesTotal-received)])
		if n > 0 {
			received += n
			packets++
		}
		if err != nil {
			if errors.Is(err, io.EOF) && received >= bytesTotal {
				break
			}
			return Result{ReceivedBytes: received, ElapsedNS: elapsedNS(started), Errors: 1, Packets: packets}
		}
	}
	return Result{ReceivedBytes: received, ElapsedNS: elapsedNS(started), Packets: packets}
}

func duplexConn(conn net.Conn, bytesTotal int, chunk int) Result {
	type out struct {
		res Result
	}
	sendCh := make(chan out, 1)
	recvCh := make(chan out, 1)
	go func() { sendCh <- out{res: sendConn(conn, bytesTotal, chunk)} }()
	go func() { recvCh <- out{res: recvConn(conn, bytesTotal)} }()
	sendRes := (<-sendCh).res
	recvRes := (<-recvCh).res
	return mergeResults(sendRes, recvRes)
}

func pingConnServer(conn net.Conn) Result {
	started := time.Now()
	_ = conn.SetDeadline(started.Add(transferTimeout))
	defer conn.SetDeadline(time.Time{})
	first := []byte{0xa5}
	if _, err := conn.Write(first); err != nil {
		return Result{SentBytes: 0, ElapsedNS: elapsedNS(started), Errors: 1}
	}
	payload := make([]byte, pingPayloadSize)
	if _, err := io.ReadFull(conn, payload); err != nil {
		return Result{SentBytes: 1, ElapsedNS: elapsedNS(started), Errors: 1, Packets: 1}
	}
	if _, err := conn.Write(payload); err != nil {
		return Result{SentBytes: 1, ReceivedBytes: len(payload), ElapsedNS: elapsedNS(started), Errors: 1, Packets: 1}
	}
	return Result{SentBytes: len(first) + len(payload), ReceivedBytes: len(payload), ElapsedNS: elapsedNS(started), Packets: 2}
}

func pingConnClient(conn net.Conn, started time.Time) Result {
	_ = conn.SetDeadline(started.Add(transferTimeout))
	defer conn.SetDeadline(time.Time{})
	first := make([]byte, 1)
	if _, err := io.ReadFull(conn, first); err != nil {
		return Result{ElapsedNS: elapsedNS(started), Errors: 1}
	}
	firstByteNS := elapsedNS(started)
	payload := make([]byte, pingPayloadSize)
	fillPattern(payload)
	echo := make([]byte, pingPayloadSize)
	rttStarted := time.Now()
	if _, err := conn.Write(payload); err != nil {
		return Result{SentBytes: len(payload), ReceivedBytes: len(first), ElapsedNS: elapsedNS(started), Errors: 1, Packets: 1, FirstByteNS: firstByteNS}
	}
	if _, err := io.ReadFull(conn, echo); err != nil {
		return Result{SentBytes: len(payload), ReceivedBytes: len(first), ElapsedNS: elapsedNS(started), Errors: 1, Packets: 1, FirstByteNS: firstByteNS}
	}
	if !bytes.Equal(payload, echo) {
		return Result{SentBytes: len(payload), ReceivedBytes: len(first) + len(echo), ElapsedNS: elapsedNS(started), Errors: 1, Packets: 2, FirstByteNS: firstByteNS}
	}
	return Result{SentBytes: len(payload), ReceivedBytes: len(first) + len(echo), ElapsedNS: elapsedNS(started), Packets: 2, FirstByteNS: firstByteNS, RTTNS: elapsedNS(rttStarted)}
}

func pingKCPServer(conn net.Conn) Result {
	started := time.Now()
	_ = conn.SetDeadline(started.Add(transferTimeout))
	defer conn.SetDeadline(time.Time{})
	payload := make([]byte, pingPayloadSize)
	if _, err := io.ReadFull(conn, payload); err != nil {
		return Result{ElapsedNS: elapsedNS(started), Errors: 1}
	}
	echo := make([]byte, 1+len(payload))
	echo[0] = 0xaa
	copy(echo[1:], payload)
	if _, err := conn.Write(echo); err != nil {
		return Result{ReceivedBytes: len(payload), ElapsedNS: elapsedNS(started), Errors: 1, Packets: 1}
	}
	return Result{SentBytes: len(echo), ReceivedBytes: len(payload), ElapsedNS: elapsedNS(started), Packets: 2}
}

func pingKCPClient(conn net.Conn, started time.Time) Result {
	_ = conn.SetDeadline(started.Add(transferTimeout))
	defer conn.SetDeadline(time.Time{})
	payload := make([]byte, pingPayloadSize)
	fillPattern(payload)
	echo := make([]byte, 1+len(payload))
	rttStarted := time.Now()
	if _, err := conn.Write(payload); err != nil {
		return Result{SentBytes: len(payload), ElapsedNS: elapsedNS(started), Errors: 1}
	}
	firstByteNS := elapsedNS(started)
	if _, err := io.ReadFull(conn, echo); err != nil {
		return Result{SentBytes: len(payload), ElapsedNS: elapsedNS(started), Errors: 1, Packets: 1, FirstByteNS: firstByteNS}
	}
	if echo[0] != 0xaa || !bytes.Equal(payload, echo[1:]) {
		return Result{SentBytes: len(payload), ReceivedBytes: len(echo), ElapsedNS: elapsedNS(started), Errors: 1, Packets: 2, FirstByteNS: firstByteNS}
	}
	return Result{SentBytes: len(payload), ReceivedBytes: len(echo), ElapsedNS: elapsedNS(started), Packets: 2, FirstByteNS: firstByteNS, RTTNS: elapsedNS(rttStarted)}
}

func pingPacketServer(conn *net.UDPConn, remote *net.UDPAddr) Result {
	started := time.Now()
	first := []byte{0xa5}
	if _, err := conn.WriteToUDP(first, remote); err != nil {
		return Result{ElapsedNS: elapsedNS(started), Errors: 1}
	}
	payload := make([]byte, pingPayloadSize)
	_ = conn.SetReadDeadline(started.Add(transferTimeout))
	n, addr, err := conn.ReadFromUDP(payload)
	_ = conn.SetReadDeadline(time.Time{})
	if err != nil {
		return Result{SentBytes: len(first), ElapsedNS: elapsedNS(started), Errors: 1, Packets: 1}
	}
	if !addr.IP.Equal(remote.IP) || addr.Port != remote.Port {
		return Result{SentBytes: len(first), ElapsedNS: elapsedNS(started), Errors: 1, Packets: 1}
	}
	if _, err := conn.WriteToUDP(payload[:n], remote); err != nil {
		return Result{SentBytes: len(first), ReceivedBytes: n, ElapsedNS: elapsedNS(started), Errors: 1, Packets: 1}
	}
	return Result{SentBytes: len(first) + n, ReceivedBytes: n, ElapsedNS: elapsedNS(started), Packets: 2}
}

func pingPacketClient(conn *net.UDPConn, remote *net.UDPAddr, started time.Time) Result {
	first := make([]byte, 1)
	_ = conn.SetReadDeadline(started.Add(transferTimeout))
	n, addr, err := conn.ReadFromUDP(first)
	if err != nil || n != 1 || !addr.IP.Equal(remote.IP) || addr.Port != remote.Port {
		_ = conn.SetReadDeadline(time.Time{})
		return Result{ElapsedNS: elapsedNS(started), Errors: 1}
	}
	firstByteNS := elapsedNS(started)
	payload := make([]byte, pingPayloadSize)
	fillPattern(payload)
	echo := make([]byte, pingPayloadSize)
	rttStarted := time.Now()
	if _, err := conn.WriteToUDP(payload, remote); err != nil {
		_ = conn.SetReadDeadline(time.Time{})
		return Result{SentBytes: len(payload), ReceivedBytes: 1, ElapsedNS: elapsedNS(started), Errors: 1, Packets: 1, FirstByteNS: firstByteNS}
	}
	n, addr, err = conn.ReadFromUDP(echo)
	_ = conn.SetReadDeadline(time.Time{})
	if err != nil || !addr.IP.Equal(remote.IP) || addr.Port != remote.Port || !bytes.Equal(payload, echo[:n]) {
		return Result{SentBytes: len(payload), ReceivedBytes: 1 + n, ElapsedNS: elapsedNS(started), Errors: 1, Packets: 2, FirstByteNS: firstByteNS}
	}
	return Result{SentBytes: len(payload), ReceivedBytes: 1 + n, ElapsedNS: elapsedNS(started), Packets: 2, FirstByteNS: firstByteNS, RTTNS: elapsedNS(rttStarted)}
}

func sendPacket(conn *net.UDPConn, remote *net.UDPAddr, bytesTotal int, chunk int, udpPPS uint32) Result {
	payload := make([]byte, chunk)
	fillPattern(payload)
	started := time.Now()
	var sent int
	var packets uint32
	for sent < bytesTotal {
		n := min(len(payload), bytesTotal-sent)
		written, err := conn.WriteToUDP(payload[:n], remote)
		sent += written
		packets++
		if err != nil {
			return Result{SentBytes: sent, ElapsedNS: elapsedNS(started), Errors: 1, Packets: packets}
		}
		paceUDP(started, packets, udpPPS)
	}
	return Result{SentBytes: sent, ElapsedNS: elapsedNS(started), Packets: packets}
}

func recvPacket(conn *net.UDPConn, bytesTotal int, chunk int) Result {
	payload := make([]byte, chunk)
	started := time.Now()
	var received int
	var packets uint32
	var errors uint32
	var activeElapsed int64
	for received < bytesTotal {
		if time.Since(started) > transferTimeout {
			errors++
			break
		}
		_ = conn.SetReadDeadline(time.Now().Add(udpIdleTimeout))
		n, _, err := conn.ReadFromUDP(payload)
		if err != nil {
			errors++
			break
		}
		received += n
		packets++
		activeElapsed = elapsedNS(started)
	}
	_ = conn.SetReadDeadline(time.Time{})
	if activeElapsed == 0 {
		activeElapsed = elapsedNS(started)
	}
	return Result{ReceivedBytes: received, ElapsedNS: activeElapsed, Errors: errors, Packets: packets}
}

func duplexPacket(conn *net.UDPConn, remote *net.UDPAddr, bytesTotal int, chunk int, udpPPS uint32) Result {
	type out struct {
		res Result
	}
	sendCh := make(chan out, 1)
	recvCh := make(chan out, 1)
	go func() { sendCh <- out{res: sendPacket(conn, remote, bytesTotal, chunk, udpPPS)} }()
	go func() { recvCh <- out{res: recvPacket(conn, bytesTotal, chunk)} }()
	sendRes := (<-sendCh).res
	recvRes := (<-recvCh).res
	return mergeResults(sendRes, recvRes)
}

func waitHello(conn *net.UDPConn, conv uint32, timeout time.Duration) (*net.UDPAddr, error) {
	buf := make([]byte, MaxLineLen)
	_ = conn.SetReadDeadline(time.Now().Add(timeout))
	defer conn.SetReadDeadline(time.Time{})
	n, remote, err := conn.ReadFromUDP(buf)
	if err != nil {
		return nil, err
	}
	got := stringsTrimLine(string(buf[:n]))
	want := stringsTrimLine(HelloLine(conv))
	if got != want {
		return nil, fmt.Errorf("invalid hello got=%q want=%q", got, want)
	}
	return remote, nil
}

func sendHello(conn *net.UDPConn, remote *net.UDPAddr, conv uint32) error {
	line := []byte(HelloLine(conv))
	for i := 0; i < 4; i++ {
		if _, err := conn.WriteToUDP(line, remote); err != nil {
			return err
		}
	}
	time.Sleep(100 * time.Millisecond)
	return nil
}

func paceUDP(started time.Time, packets uint32, udpPPS uint32) {
	if udpPPS == 0 {
		return
	}
	target := time.Duration(uint64(packets) * uint64(time.Second) / uint64(udpPPS))
	elapsed := time.Since(started)
	if target <= elapsed {
		return
	}
	wait := target - elapsed
	if wait < time.Millisecond {
		return
	}
	time.Sleep(wait)
}

func mergeResults(sendRes Result, recvRes Result) Result {
	elapsed := sendRes.ElapsedNS
	if recvRes.ElapsedNS > elapsed {
		elapsed = recvRes.ElapsedNS
	}
	return Result{
		SentBytes:     sendRes.SentBytes,
		ReceivedBytes: recvRes.ReceivedBytes,
		ElapsedNS:     elapsed,
		Errors:        sendRes.Errors + recvRes.Errors,
		Packets:       sendRes.Packets + recvRes.Packets,
	}
}

func fillPattern(buf []byte) {
	for i := range buf {
		buf[i] = byte(i * 31)
	}
}

func elapsedNS(started time.Time) int64 {
	return time.Since(started).Nanoseconds()
}

func stringsTrimLine(line string) string {
	return strings.TrimRight(line, "\r\n")
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
