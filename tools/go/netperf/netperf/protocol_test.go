package netperf

import "testing"

func TestRequestLineUsesProtocolStreamMode(t *testing.T) {
	req := DefaultRequest()
	req.Protocol = "ikcp-packet"
	req.KCP.Stream = true

	parsed, err := ParseRequest(req.RequestLine())
	if err != nil {
		t.Fatal(err)
	}
	if parsed.KCP.Stream {
		t.Fatalf("ikcp-packet request should not set stream mode: %+v", parsed)
	}

	req.Protocol = "ikcp-stream"
	req.KCP.Stream = false
	parsed, err = ParseRequest(req.RequestLine())
	if err != nil {
		t.Fatal(err)
	}
	if !parsed.KCP.Stream {
		t.Fatalf("ikcp-stream request should set stream mode: %+v", parsed)
	}
}
