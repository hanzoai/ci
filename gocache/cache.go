package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// cache is one job's view of the org's Go cache: what the store holds (remote,
// from its index), what this job has on disk (dir), and what this job made that
// the store lacks (fresh). Every remote byte is fetched on the first ask for it.
type cache struct {
	dir    string // dir/o/<id> holds bytes, dir/a/<action> names an action's output
	mods   string // GOMODCACHE, whose cache/download a save carries
	st     *store // nil: this job reads and writes its own disk only
	prefix string
	scope  string // which gate this job runs; names the list of what its last run used
	write  bool

	mu      sync.Mutex
	remote  map[string]*entry
	byID    map[string]*entry // one stored copy per content, for reuse
	frags   []string          // index objects loaded
	fresh   map[string]*entry // this job's entries whose bytes the store lacks
	used    map[string]bool
	pending map[string]*call

	hits, misses, fetched, puts atomic.Int64
	fetchedBytes                atomic.Int64
	fetchErrs                   atomic.Int64
	prefetched                  atomic.Int64
}

// usedKey is where a scope's last saving run recorded the entries it used.
func (c *cache) usedKey() string { return c.prefix + "/u/" + c.scope + ".gz" }

// prefetch reads, in the background, every entry the last run of this scope
// used. A gate asks for its compiled packages a few at a time, each a round
// trip, so on its own it waits on latency; fetched ahead on many connections,
// most are on disk before it asks, and a get for one still in flight waits for
// that fetch rather than starting another.
func (c *cache) prefetch(ctx context.Context, workers int) {
	if c.st == nil || c.scope == "" {
		return
	}
	b, err := c.st.read(ctx, c.usedKey(), 0, -1)
	if err != nil {
		return
	}
	es := map[string]*entry{}
	if decodeIndex(b, es) != nil {
		return
	}
	work := make(chan *entry)
	for i := 0; i < workers; i++ {
		go func() {
			for e := range work {
				if _, err := os.Stat(c.outPath(e.id)); err == nil {
					continue
				}
				if c.fetch(ctx, e) == nil {
					c.prefetched.Add(1)
				}
			}
		}()
	}
	go func() {
		defer close(work)
		for k := range es {
			c.mu.Lock()
			e := c.remote[k]
			c.mu.Unlock()
			if e != nil {
				work <- e
			}
		}
	}()
}

type call struct {
	done chan struct{}
	err  error
}

func newCache(dir, mods string, st *store, prefix string, write bool) (*cache, error) {
	for _, d := range []string{"o", "a"} {
		if err := os.MkdirAll(filepath.Join(dir, d), 0o755); err != nil {
			return nil, err
		}
	}
	return &cache{
		dir: dir, mods: mods, st: st, prefix: prefix, write: write && st != nil,
		remote: map[string]*entry{}, byID: map[string]*entry{},
		fresh: map[string]*entry{}, used: map[string]bool{}, pending: map[string]*call{},
	}, nil
}

// load reads every index the store holds for this prefix.
func (c *cache) load(ctx context.Context) error {
	if c.st == nil {
		return nil
	}
	objs, err := c.st.list(ctx, c.prefix+"/i")
	if err != nil {
		return err
	}
	return c.loadIndexes(ctx, objs)
}

func (c *cache) loadIndexes(ctx context.Context, objs []object) error {
	c.mu.Lock()
	have := map[string]bool{}
	for _, k := range c.frags {
		have[k] = true
	}
	c.mu.Unlock()
	var firstErr error
	for _, o := range objs {
		if have[o.Key] || !strings.HasSuffix(o.Key, ".gz") {
			continue
		}
		b, err := c.st.read(ctx, o.Key, 0, -1)
		if errors.Is(err, errNotFound) {
			continue // merged and deleted by a save since it was listed
		}
		if err == nil {
			es := map[string]*entry{}
			if err = decodeIndex(b, es); err == nil {
				c.mu.Lock()
				for k, e := range es {
					if old, ok := c.remote[k]; !ok || e.used > old.used {
						c.remote[k] = e
						c.byID[e.id] = e
					}
				}
				c.frags = append(c.frags, o.Key)
				c.mu.Unlock()
				continue
			}
		}
		if firstErr == nil {
			firstErr = fmt.Errorf("index %s: %w", o.Key, err)
		}
	}
	return firstErr
}

func (c *cache) outPath(id string) string { return filepath.Join(c.dir, "o", id) }

// local answers from this job's disk: dir/a/<action> holds "<id> <size> <unixnano>".
func (c *cache) local(action string) (id string, size int64, t time.Time, ok bool) {
	b, err := os.ReadFile(filepath.Join(c.dir, "a", action))
	if err != nil {
		return "", 0, time.Time{}, false
	}
	f := strings.Fields(string(b))
	if len(f) != 3 || len(f[0]) != 64 {
		return "", 0, time.Time{}, false
	}
	size, err1 := strconv.ParseInt(f[1], 10, 64)
	ns, err2 := strconv.ParseInt(f[2], 10, 64)
	if err1 != nil || err2 != nil {
		return "", 0, time.Time{}, false
	}
	if st, err := os.Stat(c.outPath(f[0])); err != nil || st.Size() != size {
		return "", 0, time.Time{}, false
	}
	return f[0], size, time.Unix(0, ns), true
}

func (c *cache) remember(action, id string, size int64, t time.Time) error {
	return writeAtomic(filepath.Join(c.dir, "a", action), []byte(fmt.Sprintf("%s %d %d\n", id, size, t.UnixNano())))
}

func writeAtomic(path string, b []byte) error {
	f, err := os.CreateTemp(filepath.Dir(path), ".tmp-*")
	if err != nil {
		return err
	}
	if _, err := f.Write(b); err != nil {
		f.Close()
		os.Remove(f.Name())
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(f.Name())
		return err
	}
	return os.Rename(f.Name(), path)
}

func (c *cache) markUsed(name string) {
	c.mu.Lock()
	c.used[name] = true
	c.mu.Unlock()
}

// get returns the output of an action: its content id, size, when it was made
// and the file that holds it. ok is false on a miss, which Go answers by
// building, so a fetch that fails is a miss and never an error.
func (c *cache) get(ctx context.Context, action string) (id string, size int64, t time.Time, path string, ok bool) {
	name := "a:" + action
	if id, size, t, ok := c.local(action); ok {
		c.markUsed(name)
		c.hits.Add(1)
		return id, size, t, c.outPath(id), true
	}
	c.mu.Lock()
	e := c.remote[name]
	c.mu.Unlock()
	if e == nil {
		c.misses.Add(1)
		return "", 0, time.Time{}, "", false
	}
	if err := c.fetch(ctx, e); err != nil {
		c.fetchErrs.Add(1)
		c.misses.Add(1)
		log.Printf("fetch %s: %v", name, err)
		return "", 0, time.Time{}, "", false
	}
	t = time.Unix(e.used, 0)
	if err := c.remember(action, e.id, e.size, t); err != nil {
		log.Printf("remember %s: %v", action, err)
	}
	c.markUsed(name)
	c.hits.Add(1)
	return e.id, e.size, t, c.outPath(e.id), true
}

// fetch puts an entry's bytes at dir/o/<id>, once however many ask at once.
func (c *cache) fetch(ctx context.Context, e *entry) error {
	path := c.outPath(e.id)
	if st, err := os.Stat(path); err == nil && st.Size() == e.size {
		return nil
	}
	c.mu.Lock()
	if p, ok := c.pending[e.id]; ok {
		c.mu.Unlock()
		<-p.done
		return p.err
	}
	p := &call{done: make(chan struct{})}
	c.pending[e.id] = p
	c.mu.Unlock()

	b, err := readEntry(ctx, c.st, c.prefix, e)
	if err == nil {
		err = writeAtomic(path, b)
		c.fetched.Add(1)
		c.fetchedBytes.Add(int64(len(b)))
	}
	p.err = err
	c.mu.Lock()
	delete(c.pending, e.id)
	c.mu.Unlock()
	close(p.done)
	return err
}

// put stores an action's output, which Go names by the SHA-256 of its bytes;
// bytes that do not hash to that name are refused rather than cached.
func (c *cache) put(action string, output []byte, body []byte) (string, error) {
	id := hex.EncodeToString(output)
	if sum := sha256.Sum256(body); hex.EncodeToString(sum[:]) != id {
		return "", fmt.Errorf("put %s: the body does not hash to its output id", action)
	}
	path := c.outPath(id)
	if st, err := os.Stat(path); err != nil || st.Size() != int64(len(body)) {
		if err := writeAtomic(path, body); err != nil {
			return "", err
		}
	}
	if err := c.remember(action, id, int64(len(body)), time.Now()); err != nil {
		return "", err
	}
	name := "a:" + action
	c.mu.Lock()
	c.used[name] = true
	if e := c.remote[name]; e == nil || e.id != id {
		c.fresh[name] = &entry{kind: 'a', key: action, id: id, size: int64(len(body))}
	}
	c.mu.Unlock()
	c.puts.Add(1)
	return path, nil
}

// module answers the proxy: the bytes of one file under cache/download, or
// errNotFound, which sends the go command on to the next proxy.
func (c *cache) module(ctx context.Context, rel string) (string, error) {
	name := "m:" + rel
	c.mu.Lock()
	e := c.remote[name]
	c.mu.Unlock()
	if e == nil {
		c.misses.Add(1)
		return "", errNotFound
	}
	if err := c.fetch(ctx, e); err != nil {
		c.fetchErrs.Add(1)
		c.misses.Add(1)
		log.Printf("fetch %s: %v", name, err)
		return "", errNotFound
	}
	c.markUsed(name)
	c.hits.Add(1)
	return c.outPath(e.id), nil
}

// downloads walks GOMODCACHE/cache/download for what a proxy serves (.info,
// .mod, .zip): every one is used by this run, and any the store lacks is fresh.
func (c *cache) downloads() error {
	if c.mods == "" {
		return nil
	}
	root := filepath.Join(c.mods, "cache", "download")
	return filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				return nil
			}
			return err
		}
		if d.IsDir() {
			if path != root && d.Name() == "sumdb" && filepath.Dir(path) == root {
				return filepath.SkipDir
			}
			return nil
		}
		ext := filepath.Ext(path)
		if ext != ".info" && ext != ".mod" && ext != ".zip" {
			return nil
		}
		rel, _ := filepath.Rel(root, path)
		rel = filepath.ToSlash(rel)
		if !strings.Contains(rel, "/@v/") {
			return nil
		}
		name := "m:" + rel
		c.mu.Lock()
		c.used[name] = true
		_, stored := c.remote[name]
		c.mu.Unlock()
		if stored {
			return nil
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return nil
		}
		sum := sha256.Sum256(b)
		c.mu.Lock()
		c.fresh[name] = &entry{kind: 'm', key: rel, id: hex.EncodeToString(sum[:]), size: int64(len(b)), src: path}
		c.mu.Unlock()
		return nil
	})
}

// save is the end of a job that may write: upload the bytes the store lacks as
// one pack, then one index that merges every index the store holds with what
// this job used, then delete what that index replaced.
func (c *cache) save(ctx context.Context) (string, error) {
	if !c.write {
		return "read only, nothing written", nil
	}
	if err := c.downloads(); err != nil {
		log.Printf("module downloads: %v", err)
	}
	now := time.Now()
	c.mu.Lock()
	fresh := make([]*entry, 0, len(c.fresh))
	for _, e := range c.fresh {
		fresh = append(fresh, e)
	}
	c.mu.Unlock()
	sort.Slice(fresh, func(i, j int) bool { return fresh[i].name() < fresh[j].name() })

	c.st.ensure(ctx)
	p := newPacker(ctx, c.st, c.prefix)
	packed := map[string]*entry{} // id -> where this pack put it
	reused := 0
	for _, e := range fresh {
		c.mu.Lock()
		have := c.byID[e.id]
		c.mu.Unlock()
		if have != nil {
			e.pack, e.off, e.clen = have.pack, have.off, have.clen
			reused++
			continue
		}
		if q := packed[e.id]; q != nil {
			e.pack, e.off, e.clen = q.pack, q.off, q.clen
			continue
		}
		src := e.src
		if src == "" {
			src = c.outPath(e.id)
		}
		b, err := os.ReadFile(src)
		if err != nil || int64(len(b)) != e.size {
			e.pack = ""
			continue
		}
		if err := p.add(e, b); err != nil {
			break
		}
		packed[e.id] = e
	}
	sent, err := p.close()
	if err != nil {
		return "", fmt.Errorf("pack %s: %w; no index names it, so nothing half-written is read", p.id, err)
	}

	// Every index the store holds now, so this one replaces them all.
	objs, err := c.st.list(ctx, c.prefix+"/i")
	if err != nil {
		return "", fmt.Errorf("list indexes: %w", err)
	}
	if err := c.loadIndexes(ctx, objs); err != nil {
		log.Printf("%v", err)
	}
	c.mu.Lock()
	merged := make(map[string]*entry, len(c.remote)+len(fresh))
	for k, e := range c.remote {
		merged[k] = e
	}
	for _, e := range fresh {
		if e.pack != "" {
			merged[e.name()] = e
		}
	}
	for k := range c.used {
		if e := merged[k]; e != nil {
			cp := *e
			cp.used = now.Unix()
			merged[k] = &cp
		}
	}
	loaded := map[string]bool{}
	for _, k := range c.frags {
		loaded[k] = true
	}
	c.mu.Unlock()
	cut := now.Add(-ttl).Unix()
	for k, e := range merged {
		if e.used < cut {
			delete(merged, k)
		}
	}
	idx := c.prefix + "/i/" + p.id + ".gz"
	if err := c.st.write(ctx, idx, encodeIndex(merged)); err != nil {
		return "", fmt.Errorf("index: %w", err)
	}
	if c.scope != "" {
		c.mu.Lock()
		mine := map[string]*entry{}
		for k := range c.used {
			if e := merged[k]; e != nil {
				mine[k] = e
			}
		}
		c.mu.Unlock()
		if err := c.st.write(ctx, c.usedKey(), encodeIndex(mine)); err != nil {
			log.Printf("used list: %v", err)
		}
	}
	dropped := 0
	for _, o := range objs {
		if loaded[o.Key] && o.Key != idx && c.st.remove(ctx, o.Key) == nil {
			dropped++
		}
	}
	gone := c.sweep(ctx, merged, now)
	return fmt.Sprintf("%d new entries (%d already stored under another name) in %d MiB, index of %d entries replaces %d, %d unnamed pack(s) deleted",
		len(packed), reused, sent>>20, len(merged), dropped, gone), nil
}

// sweep deletes the packs no index names that are older than grace.
func (c *cache) sweep(ctx context.Context, merged map[string]*entry, now time.Time) int {
	named := map[string]bool{}
	for _, e := range merged {
		named[e.pack] = true
	}
	// An index another save wrote since this one listed names packs too.
	if objs, err := c.st.list(ctx, c.prefix+"/i"); err == nil {
		c.loadIndexes(ctx, objs)
		c.mu.Lock()
		for _, e := range c.remote {
			named[e.pack] = true
		}
		c.mu.Unlock()
	} else {
		return 0
	}
	objs, err := c.st.list(ctx, c.prefix+"/p")
	if err != nil {
		return 0
	}
	gone := map[string]bool{}
	for _, o := range objs {
		base := strings.TrimPrefix(o.Key, c.prefix+"/p/")
		i := strings.LastIndexByte(base, '.')
		if i < 0 {
			continue
		}
		pack := base[:i]
		if named[pack] || packAge(pack, now) < grace {
			continue
		}
		if c.st.remove(ctx, o.Key) == nil {
			gone[pack] = true
		}
	}
	return len(gone)
}

func (c *cache) summary() string {
	return fmt.Sprintf("%d hits, %d misses, %d fetched (%d MiB, %d ahead of the build), %d fetch errors, %d puts",
		c.hits.Load(), c.misses.Load(), c.fetched.Load(), c.fetchedBytes.Load()>>20, c.prefetched.Load(), c.fetchErrs.Load(), c.puts.Load())
}
