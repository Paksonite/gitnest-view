package rpc

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func serve(t *testing.T, s *Server, input string) map[string]map[string]any {
	t.Helper()
	var out bytes.Buffer
	if err := s.Serve(context.Background(), strings.NewReader(input), &out); err != nil {
		t.Fatal(err)
	}
	byID := map[string]map[string]any{}
	for _, line := range strings.Split(strings.TrimSpace(out.String()), "\n") {
		if line == "" {
			continue
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			t.Fatalf("bad response line %q: %v", line, err)
		}
		id, _ := json.Marshal(m["id"])
		byID[string(id)] = m
	}
	return byID
}

func TestServe(t *testing.T) {
	s := NewServer()
	s.Handle("echo", func(_ context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			Text string `json:"text"`
		}
		if err := Params(raw, &p); err != nil {
			return nil, err
		}
		return map[string]string{"text": p.Text}, nil
	})
	s.Handle("fail", func(context.Context, json.RawMessage) (any, error) { return nil, errors.New("git said no") })
	s.Handle("panic", func(context.Context, json.RawMessage) (any, error) { panic("boom") })
	s.Handle("nothing", func(context.Context, json.RawMessage) (any, error) { return nil, nil })

	got := serve(t, s, strings.Join([]string{
		`{"jsonrpc":"2.0","id":1,"method":"echo","params":{"text":"zażółć"}}`,
		`{"jsonrpc":"2.0","id":2,"method":"fail"}`,
		`{"jsonrpc":"2.0","id":3,"method":"panic"}`,
		`{"jsonrpc":"2.0","id":4,"method":"missing"}`,
		`{"jsonrpc":"2.0","id":5,"method":"echo","params":{"text":7}}`,
		`{"jsonrpc":"2.0","id":6,"method":"nothing"}`,
		`{"jsonrpc":"2.0","method":"echo","params":{"text":"notification"}}`,
		`not json`,
		``,
	}, "\n"))

	if r := got["1"]["result"].(map[string]any); r["text"] != "zażółć" {
		t.Errorf("echo: %v", got["1"])
	}
	for id, want := range map[string]float64{"2": codeFailed, "3": codeFailed, "4": codeNoMethod, "5": codeParams, "null": codeParse} {
		e, ok := got[id]["error"].(map[string]any)
		if !ok || e["code"] != want {
			t.Errorf("id %s: want error %v, got %v", id, want, got[id])
		}
	}
	if _, ok := got["6"]["result"].(map[string]any); !ok {
		t.Errorf("a nil result must still be an object: %v", got["6"])
	}
	if len(got) != 7 {
		t.Errorf("want 7 responses (none for the notification), got %d: %v", len(got), got)
	}
}
