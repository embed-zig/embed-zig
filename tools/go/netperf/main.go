package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"strconv"

	"embed-zig/tools/go/netperf/netperf"
)

func main() {
	log.SetFlags(0)
	if err := run(context.Background(), os.Args[1:]); err != nil {
		log.Fatalf("netperf-go: %v", err)
	}
}

func run(ctx context.Context, args []string) error {
	if len(args) == 0 {
		usage()
		return fmt.Errorf("missing command")
	}
	switch args[0] {
	case "server":
		addr := "0.0.0.0:9821"
		if len(args) > 1 {
			addr = args[1]
		}
		return netperf.Serve(ctx, addr)
	case "client":
		if len(args) < 5 {
			usage()
			return fmt.Errorf("client requires host port protocol direction")
		}
		port, err := strconv.Atoi(args[2])
		if err != nil {
			return fmt.Errorf("invalid port %q: %w", args[2], err)
		}
		req := netperf.DefaultRequest()
		req.Protocol = args[3]
		req.Direction = args[4]
		if len(args) > 5 {
			req.Bytes, err = strconv.Atoi(args[5])
			if err != nil {
				return fmt.Errorf("invalid bytes %q: %w", args[5], err)
			}
		}
		if len(args) > 6 {
			req.KCP.SendWindow, err = strconv.Atoi(args[6])
			if err != nil {
				return fmt.Errorf("invalid send window %q: %w", args[6], err)
			}
		}
		if len(args) > 7 {
			req.KCP.RecvWindow, err = strconv.Atoi(args[7])
			if err != nil {
				return fmt.Errorf("invalid recv window %q: %w", args[7], err)
			}
		}
		if len(args) > 8 {
			req.KCP.NoDelay, err = strconv.Atoi(args[8])
			if err != nil {
				return fmt.Errorf("invalid nodelay %q: %w", args[8], err)
			}
		}
		if len(args) > 9 {
			req.KCP.IntervalMS, err = strconv.Atoi(args[9])
			if err != nil {
				return fmt.Errorf("invalid interval %q: %w", args[9], err)
			}
		}
		if len(args) > 10 {
			req.KCP.Resend, err = strconv.Atoi(args[10])
			if err != nil {
				return fmt.Errorf("invalid resend %q: %w", args[10], err)
			}
		}
		if len(args) > 11 {
			req.KCP.NoCongestionControl, err = strconv.Atoi(args[11])
			if err != nil {
				return fmt.Errorf("invalid nc %q: %w", args[11], err)
			}
		}
		if len(args) > 12 {
			udpPPS, err := strconv.ParseUint(args[12], 10, 32)
			if err != nil {
				return fmt.Errorf("invalid udp_pps %q: %w", args[12], err)
			}
			req.UDPPPS = uint32(udpPPS)
		}
		return netperf.RunClient(ctx, args[1], port, req)
	default:
		usage()
		return fmt.Errorf("unknown command %q", args[0])
	}
}

func usage() {
	fmt.Fprintf(os.Stderr, `usage:
  netperf-go server [listen_addr]
  netperf-go client <host> <port> <protocol> <direction> [bytes] [snd_wnd] [rcv_wnd] [nodelay] [interval_ms] [resend] [nc] [udp_pps]

protocol:
  tcp | udp | ikcp-stream | ikcp-packet

direction:
  up | down | duplex | ping | all

notes:
  KCP transport uses github.com/xtaci/kcp-go/v5 UDPSession.
`)
}
