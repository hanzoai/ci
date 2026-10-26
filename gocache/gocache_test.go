package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeStore is cloud's /v1/s3 as bin/cache and gocache use it: presign a GET
// or a PUT for one key, list a prefix, delete a key. The presigned URLs point
// back at it, under /blob/, and honour Range as S3 does.
type fakeStore struct {
	mu      sync.Mutex
	objs    map[string][]byte
	mod     map[string]time.Time
	presign int
	srv     *httptest.Server
}

func newFakeStore(t *testing.T) *fakeStore {
	f := &fakeStore{objs: map[string][]byte{}, mod: map[string]time.Time{}}
	f.srv = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeStore) serve(w http.ResponseWriter, r *http.Request) {
	const objs = "/v1/s3/buckets/ci-cache/objects"
	p := r.URL.Path
	switch {
	case strings.HasPrefix(p, "/blob/"):
		key := strings.TrimPrefix(p, "/blob/")
		f.mu.Lock()
		defer f.mu.Unlock()
		switch r.Method {
		case http.MethodPut:
			b, _ := io.ReadAll(r.Body)
			f.objs[key], f.mod[key] = b, time.Now()
		case http.MethodGet:
			b, ok := f.objs[key]
			if !ok {
				http.NotFound(w, r)
				return
			}
			if rg := r.Header.Get("Range"); rg != "" {
				var a, z int
				fmt.Sscanf(rg, "bytes=%d-%d", &a, &z)
				if a < 0 || z >= len(b) || a > z {
					w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
					return
				}
				w.WriteHeader(http.StatusPartialContent)
				w.Write(b[a : z+1])
				return
			}
			w.Write(b)
		}
	case p == "/v1/s3/buckets" && r.Method == http.MethodPost:
		w.WriteHeader(http.StatusConflict)
	case p == objs && r.Method == http.MethodPost:
		var in struct{ Key string }
		json.NewDecoder(r.Body).Decode(&in)
		f.mu.Lock()
		f.presign++
		f.mu.Unlock()
		json.NewEncoder(w).Encode(map[string]string{"url": f.srv.URL + "/blob/" + in.Key})
	case p == objs && r.Method == http.MethodGet:
		prefix := r.URL.Query().Get("prefix")
		f.mu.Lock()
		var out []object
		for k, b := range f.objs {
			if strings.HasPrefix(k, prefix) {
				out = append(out, object{Key: strings.TrimPrefix(k, prefix), Size: int64(len(b)), LastModified: f.mod[k].Unix()})
			}
		}
		f.mu.Unlock()
		sort.Slice(out, func(i, j int) bool { return out[i].Key < out[j].Key })
		json.NewEncoder(w).Encode(map[string]any{"objects": out})
	case strings.HasPrefix(p, objs+"/") && r.Method == http.MethodGet:
		f.mu.Lock()
		f.presign++
		f.mu.Unlock()
		json.NewEncoder(w).Encode(map[string]string{"url": f.srv.URL + "/blob/" + strings.TrimPrefix(p, objs+"/")})
	case strings.HasPrefix(p, objs+"/") && r.Method == http.MethodDelete:
		f.mu.Lock()
		delete(f.objs, strings.TrimPrefix(p, objs+"/"))
		f.mu.Unlock()
	default:
		http.Error(w, "no such route "+r.Method+" "+p, http.StatusTeapot)
	}
}

func (f *fakeStore) keys(prefix string) []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []string
	for k := range f.objs {
		if strings.HasPrefix(k, prefix) {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}

func newTestCache(t *testing.T, f *fakeStore, write bool) *cache {
	t.Helper()
	c, err := newCache(t.TempDir(), "", newStore(f.srv.URL, "tok", "ci-cache"), "o/r/gocache/go-test", write)
	if err != nil {
		t.Fatal(err)
	}
	if err := c.load(context.Background()); err != nil {
		t.Fatal(err)
	}
	return c
}

func sum(b []byte) []byte { s := sha256.Sum256(b); return s[:] }

func TestAnEntryCrossesPartsAndComesBackWhole(t *testing.T) {
	defer func(n int64) { partSize = n }(partSize)
	partSize = 64
	f := newFakeStore(t)
	ctx := context.Background()
	w := newTestCache(t, f, true)
	var bodies [][]byte
	for i := 0; i < 20; i++ {
		b := bytes.Repeat([]byte(strconv.Itoa(i)), 50+i*13) // compresses, and still spans parts
		b = append(b, []byte(fmt.Sprint(time.Now().UnixNano()))...)
		bodies = append(bodies, b)
		if _, err := w.put(fmt.Sprintf("%064x", i), sum(b), b); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := w.save(ctx); err != nil {
		t.Fatal(err)
	}
	if n := len(f.keys("o/r/gocache/go-test/p/")); n < 3 {
		t.Fatalf("%d parts; the test means to cross part boundaries", n)
	}
	r := newTestCache(t, f, false)
	for i, b := range bodies {
		id, size, _, path, ok := r.get(ctx, fmt.Sprintf("%064x", i))
		if !ok {
			t.Fatalf("entry %d missed", i)
		}
		got, _ := os.ReadFile(path)
		if !bytes.Equal(got, b) || size != int64(len(b)) || id != hex.EncodeToString(sum(b)) {
			t.Fatalf("entry %d came back as %d bytes, want %d", i, len(got), len(b))
		}
	}
	if r.fetchErrs.Load() != 0 {
		t.Fatalf("%d fetch errors", r.fetchErrs.Load())
	}
}

func TestBytesThatDoNotMatchTheirNameAreAMiss(t *testing.T) {
	f := newFakeStore(t)
	ctx := context.Background()
	w := newTestCache(t, f, true)
	b := []byte("the real output")
	w.put(strings.Repeat("ab", 32), sum(b), b)
	if _, err := w.save(ctx); err != nil {
		t.Fatal(err)
	}
	// Corrupt the pack: same length, other bytes.
	for _, k := range f.keys("o/r/gocache/go-test/p/") {
		f.mu.Lock()
		f.objs[k] = bytes.Repeat([]byte{0}, len(f.objs[k]))
		f.mu.Unlock()
	}
	r := newTestCache(t, f, false)
	if _, _, _, _, ok := r.get(ctx, strings.Repeat("ab", 32)); ok {
		t.Fatal("a corrupt pack answered a hit")
	}
	if r.fetchErrs.Load() != 1 {
		t.Fatalf("fetch errors %d, want 1", r.fetchErrs.Load())
	}
}

func TestAPutWhoseBodyIsNotItsOutputIsRefused(t *testing.T) {
	c, _ := newCache(t.TempDir(), "", nil, "", false)
	if _, err := c.put(strings.Repeat("cd", 32), sum([]byte("a")), []byte("b")); err == nil {
		t.Fatal("a body that does not hash to its output id was stored")
	}
}

func TestAReadOnlyJobWritesNothing(t *testing.T) {
	f := newFakeStore(t)
	r := newTestCache(t, f, false)
	b := []byte("x")
	r.put(strings.Repeat("ef", 32), sum(b), b)
	if _, err := r.save(context.Background()); err != nil {
		t.Fatal(err)
	}
	if k := f.keys(""); len(k) != 0 {
		t.Fatalf("a read-only job wrote %v", k)
	}
}

// Two saves at once each write an index; the next save merges both and
// deletes them, and an entry no run has used for ttl leaves the index.
func TestSavesMergeIndexesAndForgetWhatNobodyUses(t *testing.T) {
	f := newFakeStore(t)
	ctx := context.Background()
	a, b := newTestCache(t, f, true), newTestCache(t, f, true)
	ab, bb := []byte("from a"), []byte("from b")
	a.put(strings.Repeat("0a", 32), sum(ab), ab)
	b.put(strings.Repeat("0b", 32), sum(bb), bb)
	if _, err := a.save(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := b.save(ctx); err != nil {
		t.Fatal(err)
	}
	c := newTestCache(t, f, true)
	for _, k := range []string{strings.Repeat("0a", 32), strings.Repeat("0b", 32)} {
		if _, _, _, _, ok := c.get(ctx, k); !ok {
			t.Fatalf("%s missed after two saves", k)
		}
	}
	// Age the index past ttl, then a save that uses only one entry keeps one.
	for _, k := range f.keys("o/r/gocache/go-test/i/") {
		es := map[string]*entry{}
		decodeIndex(f.objs[k], es)
		for _, e := range es {
			e.used -= int64(ttl/time.Second) + 60
		}
		f.objs[k] = encodeIndex(es)
	}
	d := newTestCache(t, f, true)
	d.get(ctx, strings.Repeat("0a", 32))
	if _, err := d.save(ctx); err != nil {
		t.Fatal(err)
	}
	idx := f.keys("o/r/gocache/go-test/i/")
	if len(idx) != 1 {
		t.Fatalf("%d indexes after a save, want the one it wrote", len(idx))
	}
	es := map[string]*entry{}
	decodeIndex(f.objs[idx[0]], es)
	if _, ok := es["a:"+strings.Repeat("0a", 32)]; !ok || len(es) != 1 {
		t.Fatalf("index holds %d entries; want only the one used within ttl", len(es))
	}
}

func TestTheProxyServesStoredModuleFiles(t *testing.T) {
	f := newFakeStore(t)
	ctx := context.Background()
	mods := t.TempDir()
	rel := "example.com/!m/@v/v1.0.0.mod"
	if err := os.MkdirAll(filepath.Join(mods, "cache", "download", filepath.Dir(rel)), 0o755); err != nil {
		t.Fatal(err)
	}
	body := []byte("module example.com/M\n")
	os.WriteFile(filepath.Join(mods, "cache", "download", rel), body, 0o644)
	os.WriteFile(filepath.Join(mods, "cache", "download", "example.com", "!m", "@v", "v1.0.0.lock"), nil, 0o644)
	w, _ := newCache(t.TempDir(), mods, newStore(f.srv.URL, "tok", "ci-cache"), "o/r/gocache/go-test", true)
	if _, err := w.save(ctx); err != nil {
		t.Fatal(err)
	}
	r := newTestCache(t, f, false)
	srv := httptest.NewServer(r.handler(make(chan struct{})))
	defer srv.Close()
	res, err := http.Get(srv.URL + "/" + rel)
	if err != nil {
		t.Fatal(err)
	}
	got, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != 200 || !bytes.Equal(got, body) {
		t.Fatalf("%d %q", res.StatusCode, got)
	}
	for _, miss := range []string{"/example.com/!m/@v/v1.0.0.lock", "/example.com/!m/@v/list", "/example.com/other/@v/v1.0.0.zip"} {
		res, _ := http.Get(srv.URL + miss)
		res.Body.Close()
		if res.StatusCode != http.StatusNotFound {
			t.Fatalf("%s answered %d, want 404 so go asks the next proxy", miss, res.StatusCode)
		}
	}
}

// The whole path, through the go command: a cold build saves, and a fresh job
// with an empty disk then builds the same module compiling nothing.
func TestTheGoCommandBuildsWarmFromTheStore(t *testing.T) {
	if testing.Short() {
		t.Skip("builds the standard library once")
	}
	gobin, err := exec.LookPath("go")
	if err != nil {
		t.Skip("no go command")
	}
	f := newFakeStore(t)
	tmp := t.TempDir()
	bin := filepath.Join(tmp, "gocache")
	if out, err := exec.Command(gobin, "build", "-o", bin, ".").CombinedOutput(); err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	mod := filepath.Join(tmp, "m")
	os.MkdirAll(mod, 0o755)
	os.WriteFile(filepath.Join(mod, "go.mod"), []byte("module example.com/m\n\ngo 1.24\n"), 0o644)
	os.WriteFile(filepath.Join(mod, "main.go"), []byte("package main\n\nimport (\"fmt\"; \"net/url\")\n\nfunc main() { fmt.Println(url.PathEscape(\"a b\")) }\n"), 0o644)

	run := func(name string, write bool) (compiles int, summary string) {
		dir := filepath.Join(tmp, name)
		sock := filepath.Join(tmp, name+".sock")
		ready := filepath.Join(tmp, name+".ready")
		args := []string{"serve", "-dir", dir, "-sock", sock, "-ready", ready, "-prefix", "o/r/gocache/go-test", "-scope", "gate"}
		if write {
			args = append(args, "-write")
		}
		srv := exec.Command(bin, args...)
		srv.Env = append(os.Environ(), "HANZO_API="+f.srv.URL, "HANZO_API_TOKEN=tok")
		var log bytes.Buffer
		srv.Stderr = &log
		if err := srv.Start(); err != nil {
			t.Fatal(err)
		}
		defer srv.Process.Kill()
		var addr string
		for i := 0; i < 200 && addr == ""; i++ {
			b, _ := os.ReadFile(ready)
			addr = strings.TrimSpace(string(b))
			time.Sleep(25 * time.Millisecond)
		}
		if addr == "" {
			t.Fatalf("serve never became ready: %s", log.String())
		}
		cmd := exec.Command(gobin, "build", "-x", "-o", filepath.Join(tmp, name+".out"), ".")
		cmd.Dir = mod
		cmd.Env = append(os.Environ(), "GOCACHEPROG="+bin+" connect "+sock+" "+dir, "GOFLAGS=", "GOWORK=off")
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("go build: %v\n%s\nserve: %s", err, out, log.String())
		}
		compiles = strings.Count(string(out), "/compile ")
		fl, _ := exec.Command(bin, "flush", addr).CombinedOutput()
		srv.Wait()
		return compiles, string(fl)
	}
	cold, s1 := run("cold", true)
	if cold == 0 {
		t.Fatalf("the cold build compiled nothing, so it proves nothing: %s", s1)
	}
	warm, s2 := run("warm", false)
	if warm != 0 {
		t.Fatalf("the warm build compiled %d packages; want 0 (cold compiled %d)\ncold: %s\nwarm: %s", warm, cold, s1, s2)
	}
	if strings.Contains(s2, ", 0 ahead of the build") {
		t.Fatalf("the warm job fetched nothing ahead of the build, though its scope's last run left a list: %s", s2)
	}
	t.Logf("cold compiled %d packages, warm 0\ncold: %s\nwarm: %s", cold, s1, s2)
}

// A connect with no serve to dial answers from its own disk, so a job whose
// serve did not start still builds.
func TestConnectWithoutServeBuildsFromDisk(t *testing.T) {
	c, _ := newCache(t.TempDir(), "", nil, "", false)
	b := []byte("output")
	// Requests in one session are answered concurrently, as the go command
	// sends them, so the put is one go command and the gets the next.
	first := talk(t, c, func(enc *json.Encoder) {
		enc.Encode(request{ID: 1, Command: "put", ActionID: bytes.Repeat([]byte{1}, 32), OutputID: sum(b), BodySize: int64(len(b))})
		enc.Encode(b)
	})
	if len(first[0].KnownCommands) != 3 {
		t.Fatalf("hello %+v", first[0])
	}
	if first[1].DiskPath == "" || first[1].Err != "" {
		t.Fatalf("put %+v", first[1])
	}
	second := talk(t, c, func(enc *json.Encoder) {
		enc.Encode(request{ID: 1, Command: "get", ActionID: bytes.Repeat([]byte{1}, 32)})
		enc.Encode(request{ID: 2, Command: "get", ActionID: bytes.Repeat([]byte{2}, 32)})
	})
	if second[1].Miss || !bytes.Equal(second[1].OutputID, sum(b)) || second[1].Size != int64(len(b)) {
		t.Fatalf("get after put %+v", second[1])
	}
	if got, _ := os.ReadFile(second[1].DiskPath); !bytes.Equal(got, b) {
		t.Fatalf("DiskPath holds %q", got)
	}
	if !second[2].Miss {
		t.Fatalf("get of nothing %+v", second[2])
	}
}

// talk runs one session: the requests write sends, then close, and every answer by ID.
func talk(t *testing.T, c *cache, write func(*json.Encoder)) map[int64]response {
	t.Helper()
	in := &bytes.Buffer{}
	enc := json.NewEncoder(in)
	write(enc)
	enc.Encode(request{ID: 99, Command: "close"})
	var out bytes.Buffer
	if err := c.session(context.Background(), in, &out); err != nil {
		t.Fatal(err)
	}
	got := map[int64]response{}
	dec := json.NewDecoder(&out)
	for {
		var r response
		if dec.Decode(&r) != nil {
			break
		}
		got[r.ID] = r
	}
	if _, ok := got[99]; !ok {
		t.Fatal("close went unanswered")
	}
	return got
}
