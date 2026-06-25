package netperf

import (
	"bufio"
	"fmt"
	"io"
	"strconv"
	"strings"
)

const (
	Magic              = "NP1"
	DefaultBytes       = 5 * 1024 * 1024
	DefaultUDPPayload  = 1400
	DefaultUDPPPS      = 1650
	DefaultStreamChunk = 8192
	DefaultControlPort = 9821
	DefaultConv        = 0x4b435031
	MaxLineLen         = 768
)

type KCPConfig struct {
	SendWindow          int
	RecvWindow          int
	NoDelay             int
	IntervalMS          int
	Resend              int
	NoCongestionControl int
	Stream              bool
}

type Request struct {
	Protocol  string
	Direction string
	Bytes     int
	Conv      uint32
	UDPPPS    uint32
	KCP       KCPConfig
}

type Ready struct {
	TCPPort int
	UDPPort int
	Conv    uint32
}

type Result struct {
	SentBytes     int
	ReceivedBytes int
	ElapsedNS     int64
	Errors        uint32
	Packets       uint32
	FirstByteNS   int64
	RTTNS         int64
}

type RunResult struct {
	Client Result
	Server Result
}

func DefaultRequest() Request {
	return Request{
		Protocol:  "tcp",
		Direction: "down",
		Bytes:     DefaultBytes,
		Conv:      DefaultConv,
		UDPPPS:    DefaultUDPPPS,
		KCP: KCPConfig{
			SendWindow:          32,
			RecvWindow:          32,
			NoDelay:             1,
			IntervalMS:          10,
			Resend:              2,
			NoCongestionControl: 1,
			Stream:              true,
		},
	}
}

func (r Request) StreamChunk() int { return DefaultStreamChunk }
func (r Request) UDPPayload() int  { return DefaultUDPPayload }

func (r Request) WireProtocol() string {
	switch r.Protocol {
	case "kcp", "ikcp_stream":
		return "ikcp-stream"
	case "ikcp_packet":
		return "ikcp-packet"
	default:
		return r.Protocol
	}
}

func (r Request) RequestLine() string {
	stream := 0
	if r.WireProtocol() == "ikcp-stream" {
		stream = 1
	}
	return fmt.Sprintf(
		"%s REQ %s %s %d %d %d %d %d %d %d %d %d %d\n",
		Magic,
		r.WireProtocol(),
		r.Direction,
		r.Bytes,
		r.Conv,
		r.UDPPPS,
		r.KCP.SendWindow,
		r.KCP.RecvWindow,
		r.KCP.NoDelay,
		r.KCP.IntervalMS,
		r.KCP.Resend,
		r.KCP.NoCongestionControl,
		stream,
	)
}

func (r Ready) Line() string {
	return fmt.Sprintf("%s READY %d %d %d\n", Magic, r.TCPPort, r.UDPPort, r.Conv)
}

func (r Result) StopLine() string {
	return fmt.Sprintf("%s STOP %d %d %d %d %d %d %d\n", Magic, r.SentBytes, r.ReceivedBytes, r.ElapsedNS, r.Errors, r.Packets, r.FirstByteNS, r.RTTNS)
}

func (r Result) ResultLine(role string) string {
	return fmt.Sprintf("%s RESULT %s %d %d %d %d %d %d %d\n", Magic, role, r.SentBytes, r.ReceivedBytes, r.ElapsedNS, r.Errors, r.Packets, r.FirstByteNS, r.RTTNS)
}

func HelloLine(conv uint32) string {
	return fmt.Sprintf("%s HELLO %d\n", Magic, conv)
}

func (r Result) Mbps() float64 {
	if r.ElapsedNS == 0 {
		return 0
	}
	return float64(r.ReceivedBytes) * 8 * 1000 / float64(r.ElapsedNS)
}

func ParseRequest(line string) (Request, error) {
	fields := strings.Fields(strings.TrimRight(line, "\r\n"))
	if len(fields) != 14 || fields[0] != Magic || fields[1] != "REQ" {
		return Request{}, fmt.Errorf("invalid request line %q", line)
	}
	req := DefaultRequest()
	req.Protocol = normalizeProtocol(fields[2])
	req.Direction = fields[3]
	var err error
	if req.Bytes, err = atoi(fields[4]); err != nil {
		return Request{}, err
	}
	conv, err := parseUint32(fields[5])
	if err != nil {
		return Request{}, err
	}
	req.Conv = conv
	pps, err := parseUint32(fields[6])
	if err != nil {
		return Request{}, err
	}
	req.UDPPPS = pps
	if req.KCP.SendWindow, err = atoi(fields[7]); err != nil {
		return Request{}, err
	}
	if req.KCP.RecvWindow, err = atoi(fields[8]); err != nil {
		return Request{}, err
	}
	if req.KCP.NoDelay, err = atoi(fields[9]); err != nil {
		return Request{}, err
	}
	if req.KCP.IntervalMS, err = atoi(fields[10]); err != nil {
		return Request{}, err
	}
	if req.KCP.Resend, err = atoi(fields[11]); err != nil {
		return Request{}, err
	}
	if req.KCP.NoCongestionControl, err = atoi(fields[12]); err != nil {
		return Request{}, err
	}
	req.KCP.Stream = fields[13] != "0"
	return req, nil
}

func ParseReady(line string) (Ready, error) {
	fields := strings.Fields(strings.TrimRight(line, "\r\n"))
	if len(fields) != 5 || fields[0] != Magic || fields[1] != "READY" {
		return Ready{}, fmt.Errorf("invalid ready line %q", line)
	}
	tcpPort, err := atoi(fields[2])
	if err != nil {
		return Ready{}, err
	}
	udpPort, err := atoi(fields[3])
	if err != nil {
		return Ready{}, err
	}
	conv, err := parseUint32(fields[4])
	if err != nil {
		return Ready{}, err
	}
	return Ready{TCPPort: tcpPort, UDPPort: udpPort, Conv: conv}, nil
}

func ParseStop(line string) (Result, error) {
	fields := strings.Fields(strings.TrimRight(line, "\r\n"))
	if len(fields) != 9 || fields[0] != Magic || fields[1] != "STOP" {
		return Result{}, fmt.Errorf("invalid stop line %q", line)
	}
	return parseResultFields(fields[2:])
}

func ParseResult(line string) (Result, error) {
	fields := strings.Fields(strings.TrimRight(line, "\r\n"))
	if len(fields) != 10 || fields[0] != Magic || fields[1] != "RESULT" {
		return Result{}, fmt.Errorf("invalid result line %q", line)
	}
	return parseResultFields(fields[3:])
}

func IsDiagLine(line string) bool {
	return strings.HasPrefix(strings.TrimRight(line, "\r\n"), Magic+" DIAG ")
}

func ReadLine(r *bufio.Reader) (string, error) {
	line, err := r.ReadString('\n')
	if err != nil {
		if err == io.EOF && line != "" {
			return line, nil
		}
		return "", err
	}
	if len(line) > MaxLineLen {
		return "", fmt.Errorf("control line too long")
	}
	return line, nil
}

func parseResultFields(fields []string) (Result, error) {
	if len(fields) != 7 {
		return Result{}, fmt.Errorf("invalid result field count")
	}
	sent, err := atoi(fields[0])
	if err != nil {
		return Result{}, err
	}
	received, err := atoi(fields[1])
	if err != nil {
		return Result{}, err
	}
	elapsed, err := strconv.ParseInt(fields[2], 10, 64)
	if err != nil {
		return Result{}, err
	}
	errors, err := parseUint32(fields[3])
	if err != nil {
		return Result{}, err
	}
	packets, err := parseUint32(fields[4])
	if err != nil {
		return Result{}, err
	}
	first, err := strconv.ParseInt(fields[5], 10, 64)
	if err != nil {
		return Result{}, err
	}
	rtt, err := strconv.ParseInt(fields[6], 10, 64)
	if err != nil {
		return Result{}, err
	}
	return Result{SentBytes: sent, ReceivedBytes: received, ElapsedNS: elapsed, Errors: errors, Packets: packets, FirstByteNS: first, RTTNS: rtt}, nil
}

func normalizeProtocol(value string) string {
	switch value {
	case "kcp", "ikcp_stream":
		return "ikcp-stream"
	case "ikcp_packet":
		return "ikcp-packet"
	default:
		return value
	}
}

func atoi(value string) (int, error) {
	return strconv.Atoi(value)
}

func parseUint32(value string) (uint32, error) {
	parsed, err := strconv.ParseUint(value, 10, 32)
	return uint32(parsed), err
}
