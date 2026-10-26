package main

import (
	"bufio"
	"bytes"
	"compress/flate"
	"compress/gzip"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// THE LAYOUT, under <prefix> = <owner>/<repo>/gocache/<go version>-<os>-<arch>:
//
//	p/<pack>.<NNN>   a pack: the compressed bytes of many entries, one stream cut
//	                 into parts of partSize (the public name refuses a request
//	                 body over 100 MB), read back one entry at a time by range
//	i/<pack>.gz      an index: one line per entry, naming where its bytes live
//
// A pack is written before the index that names it, so a reader never finds
// an entry whose bytes are not all there. Each save writes ONE index that
// merges every index it read, then deletes those, so a reader normally loads
// one small file. Two saves at once leave two indexes; the next save merges them.
//
// A pack id starts with the time it was cut, zero-padded, so the store's
// name order is age order.
var partSize int64 = 90 << 20 // a var so a test can cross a part with small data

// ttl is how long an entry no run has used stays in the index. A save stamps
// every entry its run read or wrote; past three days an entry is code main no
// longer builds, and a pack no index names is deleted.
const ttl = 72 * time.Hour

// grace is how old a pack must be before a save may delete it unnamed: a pack
// younger than this may belong to a save that has not written its index yet.
const grace = 2 * time.Hour

// An entry is one cached file: an action's output (kind 'a', keyed by the
// action ID in hex) or a module download (kind 'm', keyed by its path under
// GOMODCACHE/cache/download). id is the SHA-256 of its bytes — what Go names
// an output by — so every fetch is checked against the name it was asked for.
type entry struct {
	kind byte
	key  string
	id   string
	size int64
	pack string
	off  int64
	clen int64
	used int64 // unix seconds of the last saving run that read or wrote it

	src string // where this job holds the bytes, when not under dir/o
}

func (e *entry) name() string { return string(e.kind) + ":" + e.key }

func packID() string {
	var b [4]byte
	rand.Read(b[:])
	return fmt.Sprintf("%019d-%s", time.Now().UnixNano(), hex.EncodeToString(b[:]))
}

// packAge reads the time a pack was cut from its id; an id that does not
// start with one is treated as new, so it is never deleted by mistake.
func packAge(id string, now time.Time) time.Duration {
	n, err := strconv.ParseInt(strings.SplitN(id, "-", 2)[0], 10, 64)
	if err != nil {
		return 0
	}
	return now.Sub(time.Unix(0, n))
}

func encodeIndex(es map[string]*entry) []byte {
	keys := make([]string, 0, len(es))
	for k := range es {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var buf bytes.Buffer
	zw, _ := gzip.NewWriterLevel(&buf, gzip.BestSpeed)
	w := bufio.NewWriter(zw)
	for _, k := range keys {
		e := es[k]
		fmt.Fprintf(w, "%c %s %s %d %s %d %d %d\n", e.kind, e.key, e.id, e.size, e.pack, e.off, e.clen, e.used)
	}
	w.Flush()
	zw.Close()
	return buf.Bytes()
}

// decodeIndex reads an index into es, keeping the more recently used of two
// entries for one key. A line it cannot read is skipped, never trusted.
func decodeIndex(b []byte, es map[string]*entry) error {
	zr, err := gzip.NewReader(bytes.NewReader(b))
	if err != nil {
		return err
	}
	sc := bufio.NewScanner(zr)
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) != 8 || len(f[0]) != 1 || (f[0] != "a" && f[0] != "m") || len(f[2]) != 64 {
			continue
		}
		e := &entry{kind: f[0][0], key: f[1], id: f[2], pack: f[4]}
		var err1, err2, err3, err4 error
		e.size, err1 = strconv.ParseInt(f[3], 10, 64)
		e.off, err2 = strconv.ParseInt(f[5], 10, 64)
		e.clen, err3 = strconv.ParseInt(f[6], 10, 64)
		e.used, err4 = strconv.ParseInt(f[7], 10, 64)
		if err1 != nil || err2 != nil || err3 != nil || err4 != nil || e.off < 0 || e.clen <= 0 || e.size < 0 {
			continue
		}
		if old, ok := es[e.name()]; !ok || e.used > old.used {
			es[e.name()] = e
		}
	}
	return sc.Err()
}

func partKey(prefix, pack string, n int64) string {
	return fmt.Sprintf("%s/p/%s.%03d", prefix, pack, n)
}

// readEntry fetches an entry's compressed bytes, which may cross a part
// boundary, inflates them and checks them against the entry's id.
func readEntry(ctx context.Context, st *store, prefix string, e *entry) ([]byte, error) {
	var z []byte
	for off, left := e.off, e.clen; left > 0; {
		part, in := off/partSize, off%partSize
		n := min(left, partSize-in)
		b, err := st.read(ctx, partKey(prefix, e.pack, part), in, n)
		if err != nil {
			return nil, err
		}
		z = append(z, b...)
		off += n
		left -= n
	}
	b, err := io.ReadAll(io.LimitReader(flate.NewReader(bytes.NewReader(z)), e.size+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) != e.size {
		return nil, fmt.Errorf("%s: %d bytes, the index says %d", e.name(), len(b), e.size)
	}
	if sum := sha256.Sum256(b); hex.EncodeToString(sum[:]) != e.id {
		return nil, fmt.Errorf("%s: its bytes do not hash to its id", e.name())
	}
	return b, nil
}

// packer writes one pack: each entry compressed on its own, appended to one
// stream, and every full part uploaded while the next is being filled.
type packer struct {
	ctx    context.Context
	st     *store
	prefix string
	id     string

	buf  []byte
	part int64
	off  int64

	wg   sync.WaitGroup
	sem  chan struct{}
	mu   sync.Mutex
	err  error
	sent int64
}

func newPacker(ctx context.Context, st *store, prefix string) *packer {
	return &packer{ctx: ctx, st: st, prefix: prefix, id: packID(), sem: make(chan struct{}, 4)}
}

// add compresses b into the pack and records where it went in e.
func (p *packer) add(e *entry, b []byte) error {
	var z bytes.Buffer
	fw, _ := flate.NewWriter(&z, flate.BestSpeed)
	fw.Write(b)
	fw.Close()
	e.pack, e.off, e.clen = p.id, p.off, int64(z.Len())
	p.off += int64(z.Len())
	for zb := z.Bytes(); len(zb) > 0; {
		n := min(len(zb), int(partSize)-len(p.buf))
		p.buf = append(p.buf, zb[:n]...)
		zb = zb[n:]
		if len(p.buf) == int(partSize) {
			p.flushPart()
		}
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.err
}

func (p *packer) flushPart() {
	b, n := p.buf, p.part
	p.buf, p.part = make([]byte, 0, partSize), p.part+1
	p.sem <- struct{}{}
	p.wg.Add(1)
	go func() {
		defer func() { <-p.sem; p.wg.Done() }()
		err := p.st.write(p.ctx, partKey(p.prefix, p.id, n), b)
		p.mu.Lock()
		if err != nil && p.err == nil {
			p.err = err
		}
		p.sent += int64(len(b))
		p.mu.Unlock()
	}()
}

// close uploads the last part and waits for all of them.
func (p *packer) close() (int64, error) {
	if len(p.buf) > 0 {
		p.flushPart()
	}
	p.wg.Wait()
	return p.sent, p.err
}
