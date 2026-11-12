// Package rpc serves the engine to the macOS app: JSON-RPC 2.0, one message
// per line, requests on stdin and responses on stdout. Requests run
// concurrently, so a slow fetch does not hold up a status call.
package rpc

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sync"
)

// Handler answers one method. params is the raw "params" member (may be nil).
type Handler func(ctx context.Context, params json.RawMessage) (any, error)

type request struct {
	JSONRPC string           `json:"jsonrpc"`
	ID      *json.RawMessage `json:"id"`
	Method  string           `json:"method"`
	Params  json.RawMessage  `json:"params"`
}

// Error is a JSON-RPC error object.
type Error struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (e *Error) Error() string { return e.Message }

type response struct {
	JSONRPC string           `json:"jsonrpc"`
	ID      *json.RawMessage `json:"id"`
	Result  any              `json:"result,omitempty"`
	Error   *Error           `json:"error,omitempty"`
}

const (
	codeParse    = -32700
	codeNoMethod = -32601
	codeParams   = -32602
	codeFailed   = -32000 // the method ran and failed (git said no, ...)
	maxLine      = 16 << 20
)

// Server dispatches requests to registered handlers.
type Server struct {
	handlers map[string]Handler
	mu       sync.Mutex // guards writes to out
	out      *bufio.Writer
}

func NewServer() *Server { return &Server{handlers: map[string]Handler{}} }

// Handle registers fn for method.
func (s *Server) Handle(method string, fn Handler) { s.handlers[method] = fn }

// Methods lists what the server answers, for core.methods.
func (s *Server) Methods() []string {
	names := make([]string, 0, len(s.handlers))
	for n := range s.handlers {
		names = append(names, n)
	}
	return names
}

// Params decodes a request's params into v; a missing params member leaves v
// at its zero value.
func Params(raw json.RawMessage, v any) error {
	if len(raw) == 0 || string(raw) == "null" {
		return nil
	}
	if err := json.Unmarshal(raw, v); err != nil {
		return &Error{Code: codeParams, Message: "invalid params: " + err.Error()}
	}
	return nil
}

// Serve reads requests from in until it ends, and returns after every
// request in flight has been answered.
func (s *Server) Serve(ctx context.Context, in io.Reader, out io.Writer) error {
	s.out = bufio.NewWriter(out)
	sc := bufio.NewScanner(in)
	sc.Buffer(make([]byte, 0, 64<<10), maxLine)
	var wg sync.WaitGroup
	for sc.Scan() {
		line := append([]byte(nil), sc.Bytes()...)
		if len(line) == 0 {
			continue
		}
		var req request
		if err := json.Unmarshal(line, &req); err != nil {
			s.write(response{JSONRPC: "2.0", Error: &Error{Code: codeParse, Message: "parse error: " + err.Error()}})
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			s.dispatch(ctx, req)
		}()
	}
	wg.Wait()
	return sc.Err()
}

func (s *Server) dispatch(ctx context.Context, req request) {
	resp := response{JSONRPC: "2.0", ID: req.ID}
	fn, ok := s.handlers[req.Method]
	if !ok {
		resp.Error = &Error{Code: codeNoMethod, Message: "unknown method: " + req.Method}
	} else if result, err := call(ctx, fn, req.Params); err != nil {
		var rpcErr *Error
		if errors.As(err, &rpcErr) {
			resp.Error = rpcErr
		} else {
			resp.Error = &Error{Code: codeFailed, Message: err.Error()}
		}
	} else if result == nil {
		resp.Result = struct{}{}
	} else {
		resp.Result = result
	}
	if req.ID == nil {
		return // a notification gets no answer
	}
	s.write(resp)
}

// call runs fn and turns a panic into an error, so one bad request cannot
// take the engine down with every repository's state.
func call(ctx context.Context, fn Handler, params json.RawMessage) (result any, err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("internal error: %v", r)
		}
	}()
	return fn(ctx, params)
}

func (s *Server) write(resp response) {
	b, err := json.Marshal(resp)
	if err != nil {
		b, _ = json.Marshal(response{JSONRPC: "2.0", ID: resp.ID,
			Error: &Error{Code: codeFailed, Message: "cannot encode result: " + err.Error()}})
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.out.Write(b)
	s.out.WriteByte('\n')
	s.out.Flush()
}
