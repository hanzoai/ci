package main

import (
	"bufio"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"sync"
	"time"
)

// The GOCACHEPROG protocol (cmd/go/internal/cacheprog): the go command writes
// one JSON request per line, a "put" followed by its body as a base64 JSON
// string, and reads JSON responses in any order, matched by ID. The program
// speaks first, with ID 0 and the commands it knows.
type request struct {
	ID       int64
	Command  string
	ActionID []byte `json:",omitempty"`
	OutputID []byte `json:",omitempty"`
	BodySize int64  `json:",omitempty"`
}

type response struct {
	ID            int64
	Err           string     `json:",omitempty"`
	KnownCommands []string   `json:",omitempty"`
	Miss          bool       `json:",omitempty"`
	OutputID      []byte     `json:",omitempty"`
	Size          int64      `json:",omitempty"`
	Time          *time.Time `json:",omitempty"`
	DiskPath      string     `json:",omitempty"`
}

// session serves one go command until it sends "close" or hangs up. Requests
// are answered concurrently, because the go command keeps many in flight.
func (c *cache) session(ctx context.Context, r io.Reader, w io.Writer) error {
	bw := bufio.NewWriter(w)
	enc := json.NewEncoder(bw)
	var wmu sync.Mutex
	send := func(res *response) {
		wmu.Lock()
		defer wmu.Unlock()
		if err := enc.Encode(res); err == nil {
			bw.Flush()
		}
	}
	send(&response{KnownCommands: []string{"get", "put", "close"}})

	dec := json.NewDecoder(bufio.NewReaderSize(r, 1<<20))
	var wg sync.WaitGroup
	defer wg.Wait()
	for {
		var req request
		if err := dec.Decode(&req); err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return fmt.Errorf("read request: %w", err)
		}
		var body []byte
		if req.Command == "put" && req.BodySize > 0 {
			if err := dec.Decode(&body); err != nil {
				return fmt.Errorf("read body of request %d: %w", req.ID, err)
			}
			if int64(len(body)) != req.BodySize {
				return fmt.Errorf("request %d: body of %d bytes, declared %d", req.ID, len(body), req.BodySize)
			}
		}
		if req.Command == "close" {
			wg.Wait()
			send(&response{ID: req.ID})
			return nil
		}
		wg.Add(1)
		go func(req request, body []byte) {
			defer wg.Done()
			send(c.handle(ctx, &req, body))
		}(req, body)
	}
}

func (c *cache) handle(ctx context.Context, req *request, body []byte) (res *response) {
	res = &response{ID: req.ID}
	defer func() {
		if p := recover(); p != nil {
			log.Printf("request %d %s: panic: %v", req.ID, req.Command, p)
			res = &response{ID: req.ID, Err: fmt.Sprint(p)}
		}
	}()
	switch req.Command {
	case "get":
		id, size, t, path, ok := c.get(ctx, hex.EncodeToString(req.ActionID))
		if !ok {
			res.Miss = true
			return res
		}
		out, _ := hex.DecodeString(id)
		res.OutputID, res.Size, res.Time, res.DiskPath = out, size, &t, path
	case "put":
		if body == nil {
			body = []byte{}
		}
		path, err := c.put(hex.EncodeToString(req.ActionID), req.OutputID, body)
		if err != nil {
			res.Err = err.Error()
			return res
		}
		res.DiskPath = path
	default:
		res.Err = "unknown command " + req.Command
	}
	return res
}
