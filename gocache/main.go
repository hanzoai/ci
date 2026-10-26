// Command gocache carries Go's build cache and module downloads between CI
// runners through this org's object store, fetching each entry when the build
// asks for it instead of restoring an archive before the build may start.
//
//	gocache serve -dir D -sock S -ready F [-prefix P -scope G -mods M -write]
//	gocache connect S D       the GOCACHEPROG command: bridges one go command to serve
//	gocache flush ADDR        saves what this job made (serve -write), then stops serve
//
// One serve runs per job and outlives the steps that start it: every go command
// the job runs reaches it through `connect`, so the store's index is read once
// and each entry is fetched at most once. Its HTTP listener is also a module
// proxy (GOPROXY) for the module files the store holds; a miss there answers
// 404, and the go command goes on to the next proxy in GOPROXY.
//
// Nothing here can fail a build. A store that cannot be read is a cold build,
// a fetch that fails is a miss, and a serve that is not running is a `connect`
// that answers from this job's own disk.
//
// ENV: HANZO_API (https://api.hanzo.ai), HANZO_API_TOKEN (the org's IAM bearer;
// without it nothing is read from or written to the store), CACHE_BUCKET (ci-cache).
// See bin/gocache for how a job runs it, and which jobs may write.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func main() {
	log.SetFlags(log.Ltime | log.Lmicroseconds)
	log.SetPrefix("gocache: ")
	if len(os.Args) < 2 {
		usage()
	}
	switch os.Args[1] {
	case "serve":
		serve(os.Args[2:])
	case "connect":
		if len(os.Args) != 4 {
			usage()
		}
		connect(os.Args[2], os.Args[3])
	case "flush":
		if len(os.Args) != 3 {
			usage()
		}
		flush(os.Args[2])
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: gocache serve -dir D -sock S -ready F [-prefix P -scope G -mods M -write] | connect S D | flush ADDR")
	os.Exit(2)
}

func serve(args []string) {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	dir := fs.String("dir", "", "where this job keeps the bytes it holds")
	sock := fs.String("sock", "", "unix socket the GOCACHEPROG bridge dials")
	ready := fs.String("ready", "", "file written with the proxy address once the index is loaded")
	prefix := fs.String("prefix", "", "<owner>/<repo>/gocache/<go version>-<os>-<arch>")
	mods := fs.String("mods", "", "GOMODCACHE, whose downloads a save carries")
	scope := fs.String("scope", "", "the gate this job runs: its last run's used entries are fetched ahead")
	write := fs.Bool("write", false, "save what this job made (a trusted ref only)")
	fs.Parse(args)
	if *dir == "" || *sock == "" || *ready == "" {
		usage()
	}

	var st *store
	if tok := os.Getenv("HANZO_API_TOKEN"); tok != "" && *prefix != "" {
		st = newStore(env("HANZO_API", "https://api.hanzo.ai"), tok, env("CACHE_BUCKET", "ci-cache"))
	} else {
		log.Printf("no HANZO_API_TOKEN or prefix: this job's own disk only")
	}
	c, err := newCache(*dir, *mods, st, *prefix, *write)
	if err != nil {
		log.Fatalf("%v", err)
	}
	c.scope = *scope
	t0 := time.Now()
	ctx := context.Background()
	lctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	if err := c.load(lctx); err != nil {
		log.Printf("index: %v (what loaded is used, the rest builds)", err)
	}
	cancel()
	c.mu.Lock()
	n, frags := len(c.remote), len(c.frags)
	c.mu.Unlock()
	log.Printf("index: %d entries from %d index file(s) in %s", n, frags, time.Since(t0).Round(time.Millisecond))
	c.prefetch(ctx, 48)

	os.Remove(*sock)
	ul, err := net.Listen("unix", *sock)
	if err != nil {
		log.Fatalf("%v", err)
	}
	tl, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		log.Fatalf("%v", err)
	}
	go func() {
		for {
			conn, err := ul.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				if err := c.session(ctx, conn, conn); err != nil {
					log.Printf("session: %v", err)
				}
			}()
		}
	}()
	done := make(chan struct{})
	srv := &http.Server{Handler: c.handler(done)}
	go srv.Serve(tl)
	if err := writeAtomic(*ready, []byte(tl.Addr().String()+"\n")); err != nil {
		log.Fatalf("%v", err)
	}
	<-done
	ul.Close()
	srv.Close()
}

// handler is the module proxy, and POST /.flush, which no module path can
// spell (a module path's first element names a host, so it holds a dot).
func (c *cache) handler(done chan struct{}) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/.flush" && r.Method == http.MethodPost {
			t0 := time.Now()
			msg, err := c.save(r.Context())
			if err != nil {
				msg = "nothing saved: " + err.Error()
			}
			fmt.Fprintf(w, "%s; saved in %s: %s\n", c.summary(), time.Since(t0).Round(time.Second), msg)
			close(done)
			return
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		rel := strings.TrimPrefix(r.URL.Path, "/")
		ext := filepath.Ext(rel)
		if !strings.Contains(rel, "/@v/") || (ext != ".info" && ext != ".mod" && ext != ".zip") || strings.Contains(rel, "..") {
			http.NotFound(w, r)
			return
		}
		path, err := c.module(r.Context(), rel)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		f, err := os.Open(path)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		defer f.Close()
		switch ext {
		case ".info":
			w.Header().Set("Content-Type", "application/json")
		case ".mod":
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		default:
			w.Header().Set("Content-Type", "application/zip")
		}
		if st, err := f.Stat(); err == nil {
			w.Header().Set("Content-Length", fmt.Sprint(st.Size()))
		}
		if r.Method == http.MethodGet {
			io.Copy(w, f)
		}
	})
}

// connect is what GOCACHEPROG runs: one per go command. It bridges stdin and
// stdout to serve, and when serve is not there it answers from dir itself, so a
// job whose serve did not start builds from its own disk instead of failing.
func connect(sock, dir string) {
	conn, err := net.Dial("unix", sock)
	if err != nil {
		c, err := newCache(dir, "", nil, "", false)
		if err != nil {
			log.Fatalf("%v", err)
		}
		if err := c.session(context.Background(), os.Stdin, os.Stdout); err != nil {
			log.Fatalf("%v", err)
		}
		return
	}
	uc := conn.(*net.UnixConn)
	go func() {
		io.Copy(uc, os.Stdin)
		uc.CloseWrite()
	}()
	io.Copy(os.Stdout, uc)
}

func flush(addr string) {
	hc := &http.Client{Timeout: 30 * time.Minute}
	res, err := hc.Post("http://"+addr+"/.flush", "text/plain", nil)
	if err != nil {
		fmt.Printf("gocache: serve did not answer the flush (%v); nothing saved\n", err)
		return
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(res.Body)
	fmt.Printf("gocache: %s", b)
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
