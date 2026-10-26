package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// store is this org's bucket in cloud's object store (/v1/s3), reached with the
// IAM bearer the job's KMS login minted. cloud derives the bucket's physical
// name from that identity's org, so one org never reads another's cache, and
// CI holds no bucket credential: every object moves over a URL cloud presigns
// for that one key, for five minutes.
type store struct {
	base, token, bucket string
	hc                  *http.Client

	mu   sync.Mutex
	urls map[string]signed // presigned GET URLs, reused while they live
}

type signed struct {
	url   string
	until time.Time
}

type object struct {
	Key          string `json:"key"`
	Size         int64  `json:"size"`
	LastModified int64  `json:"lastModified"`
}

var errNotFound = errors.New("not found")

func newStore(base, token, bucket string) *store {
	t := http.DefaultTransport.(*http.Transport).Clone()
	t.MaxIdleConns = 256
	t.MaxIdleConnsPerHost = 64
	return &store{
		base: strings.TrimRight(base, "/"), token: token, bucket: bucket,
		hc:   &http.Client{Transport: t},
		urls: map[string]signed{},
	}
}

// escape renders a key as a path under /objects/, one segment at a time, so a
// module path's `!`, `@` and `+` arrive as the key they are.
func escape(key string) string {
	segs := strings.Split(key, "/")
	for i, s := range segs {
		segs[i] = url.PathEscape(s)
	}
	return strings.Join(segs, "/")
}

// api calls cloud and decodes a 2xx answer into out. A lost answer, a 429 or a
// 5xx is asked again; anything else is the store answering.
func (s *store) api(ctx context.Context, method, path string, in, out any) error {
	var body []byte
	if in != nil {
		body, _ = json.Marshal(in)
	}
	var last error
	for _, wait := range []time.Duration{0, 2 * time.Second, 5 * time.Second} {
		if wait > 0 {
			select {
			case <-time.After(wait):
			case <-ctx.Done():
				return ctx.Err()
			}
		}
		req, err := http.NewRequestWithContext(ctx, method, s.base+path, bytes.NewReader(body))
		if err != nil {
			return err
		}
		req.Header.Set("Authorization", "Bearer "+s.token)
		req.Header.Set("Content-Type", "application/json")
		res, err := s.hc.Do(req)
		if err != nil {
			last = err
			continue
		}
		b, _ := io.ReadAll(io.LimitReader(res.Body, 64<<20))
		res.Body.Close()
		switch {
		case res.StatusCode/100 == 2:
			if out == nil {
				return nil
			}
			return json.Unmarshal(b, out)
		case res.StatusCode == http.StatusNotFound:
			return errNotFound
		case res.StatusCode == 429 || res.StatusCode >= 500:
			last = fmt.Errorf("%s %s: %d", method, path, res.StatusCode)
			continue
		default:
			return fmt.Errorf("%s %s: %d %s", method, path, res.StatusCode, firstLine(b))
		}
	}
	return last
}

func firstLine(b []byte) string {
	s := string(b)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	if len(s) > 200 {
		s = s[:200]
	}
	return s
}

func (s *store) objects() string { return "/v1/s3/buckets/" + url.PathEscape(s.bucket) + "/objects" }

// getURL presigns a download, and reuses one for four of its five minutes.
func (s *store) getURL(ctx context.Context, key string) (string, error) {
	s.mu.Lock()
	u, ok := s.urls[key]
	s.mu.Unlock()
	if ok && time.Now().Before(u.until) {
		return u.url, nil
	}
	var r struct {
		URL string `json:"url"`
	}
	if err := s.api(ctx, http.MethodGet, s.objects()+"/"+escape(key), nil, &r); err != nil {
		return "", err
	}
	if r.URL == "" {
		return "", fmt.Errorf("presign %s: no url", key)
	}
	s.mu.Lock()
	s.urls[key] = signed{r.URL, time.Now().Add(4 * time.Minute)}
	s.mu.Unlock()
	return r.URL, nil
}

// read returns n bytes of key from off, or the whole object when n < 0.
func (s *store) read(ctx context.Context, key string, off, n int64) ([]byte, error) {
	for attempt := 0; ; attempt++ {
		u, err := s.getURL(ctx, key)
		if err != nil {
			return nil, err
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
		if err != nil {
			return nil, err
		}
		if n >= 0 {
			req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", off, off+n-1))
		}
		res, err := s.hc.Do(req)
		if err == nil {
			b, rerr := io.ReadAll(res.Body)
			res.Body.Close()
			switch {
			case rerr != nil:
				err = rerr
			case res.StatusCode == http.StatusNotFound:
				return nil, errNotFound
			case res.StatusCode == http.StatusForbidden:
				// A presigned URL that outlived its signature: sign again once.
				s.mu.Lock()
				delete(s.urls, key)
				s.mu.Unlock()
				err = fmt.Errorf("GET %s: 403", key)
			case res.StatusCode/100 != 2:
				err = fmt.Errorf("GET %s: %d", key, res.StatusCode)
			case n >= 0 && int64(len(b)) != n:
				err = fmt.Errorf("GET %s: %d bytes of %d", key, len(b), n)
			default:
				return b, nil
			}
		}
		if attempt == 2 || ctx.Err() != nil {
			return nil, err
		}
		time.Sleep(time.Duration(attempt+1) * time.Second)
	}
}

// write uploads b to key over a presigned PUT, signed just before it is spent.
func (s *store) write(ctx context.Context, key string, b []byte) error {
	var last error
	for attempt := 0; attempt < 3; attempt++ {
		var r struct {
			URL string `json:"url"`
		}
		if err := s.api(ctx, http.MethodPost, s.objects(), map[string]string{"key": key}, &r); err != nil {
			return err
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodPut, r.URL, bytes.NewReader(b))
		if err != nil {
			return err
		}
		req.ContentLength = int64(len(b))
		res, err := s.hc.Do(req)
		if err == nil {
			io.Copy(io.Discard, res.Body)
			res.Body.Close()
			if res.StatusCode/100 == 2 {
				return nil
			}
			err = fmt.Errorf("PUT %s: %d", key, res.StatusCode)
		}
		last = err
		time.Sleep(time.Duration(attempt+1) * time.Second)
	}
	return last
}

// list returns the objects under prefix, keys relative to the bucket. The
// store answers at most 1000, oldest-named first; every key here starts with
// its creation time, so a truncated listing is the oldest thousand.
func (s *store) list(ctx context.Context, prefix string) ([]object, error) {
	var r struct {
		Objects []object `json:"objects"`
	}
	q := url.Values{"prefix": {prefix + "/"}, "recursive": {"true"}}
	if err := s.api(ctx, http.MethodGet, s.objects()+"?"+q.Encode(), nil, &r); err != nil {
		if errors.Is(err, errNotFound) {
			return nil, nil
		}
		return nil, err
	}
	out := r.Objects[:0]
	for _, o := range r.Objects {
		if o.Key == "" || strings.HasSuffix(o.Key, "/") {
			continue
		}
		o.Key = prefix + "/" + o.Key
		out = append(out, o)
	}
	return out, nil
}

func (s *store) remove(ctx context.Context, key string) error {
	err := s.api(ctx, http.MethodDelete, s.objects()+"/"+escape(key), nil, nil)
	if errors.Is(err, errNotFound) {
		return nil
	}
	return err
}

// ensure makes the bucket; 409 (already there) is the usual answer.
func (s *store) ensure(ctx context.Context) {
	_ = s.api(ctx, http.MethodPost, "/v1/s3/buckets", map[string]string{"name": s.bucket}, nil)
}
