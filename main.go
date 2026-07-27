// ci — the dashboard behind ci.hanzo.ai.
//
// It owns no build state. Run truth lives in Hanzo Git (git.hanzo.ai), which
// schedules the jobs and holds every log; this reads that and presents it. The
// alternative — a CI service with its own run database — would put two answers
// to "did the build pass" in the fleet, and the one users look at would be the
// one that can drift. So: git.hanzo.ai is the store, ci.hanzo.ai is the view.
//
// This is the CI half of the pair. cd.hanzo.ai reconciles image pins from
// hanzoai/universe and is the delivery view; the two are deliberately separate
// surfaces over separate systems, not one console pretending build and deploy
// are the same event.
//
// Tenancy is the same value everywhere: an org slug. Hanzo Git namespaces repos
// by org, IAM issues that slug in the `owner` claim, and Hanzo CD fences
// projects by it. Filtering here by `org` is therefore the same boundary those
// enforce, not a parallel notion of who-sees-what.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stderr, nil))

	cfg, err := loadConfig()
	if err != nil {
		logger.Error("config", "err", err)
		os.Exit(1)
	}

	src := &gitSource{base: cfg.gitBase, token: cfg.gitToken, http: &http.Client{Timeout: 20 * time.Second}}
	cache := &runCache{}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// One poller, one cache. Every viewer reads the same snapshot, so N open
	// dashboards cost Hanzo Git exactly as much as one — a dashboard that
	// fanned each page load into upstream calls is how a status page takes the
	// system it reports on down.
	go poll(ctx, logger, src, cache, cfg)

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		// Liveness only: up means "serving". Readiness deliberately does NOT
		// gate on having a snapshot — a Hanzo Git outage must show as a stale
		// dashboard saying so, not as ci.hanzo.ai disappearing from the LB too.
		writeJSON(w, http.StatusOK, map[string]any{"status": "ok"})
	})
	mux.HandleFunc("/v1/runs", func(w http.ResponseWriter, r *http.Request) {
		snap := cache.get()
		writeJSON(w, http.StatusOK, map[string]any{
			"runs":      filterByOrg(snap.Runs, r.URL.Query().Get("org")),
			"fetchedAt": snap.FetchedAt,
			"stale":     snap.stale(cfg.staleAfter),
			"sourceErr": snap.errString(),
			"repos":     snap.Repos,
			"orgs":      orgsOf(snap.Runs),
		})
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		renderDashboard(w, cache.get(), r.URL.Query().Get("org"), cfg)
	})

	srv := &http.Server{
		Addr:              cfg.listen,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	go func() {
		<-ctx.Done()
		sh, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(sh)
	}()

	logger.Info("ci dashboard listening", "addr", cfg.listen, "source", cfg.gitBase, "refresh", cfg.refresh.String())
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Error("serve", "err", err)
		os.Exit(1)
	}
}

// ───────────────────────────── config ─────────────────────────────

type config struct {
	listen     string
	gitBase    string
	gitToken   string
	refresh    time.Duration
	staleAfter time.Duration
	scanRepos  int
	runsPer    int
}

func loadConfig() (config, error) {
	c := config{
		listen:    env("CI_LISTEN", ":8080"),
		gitBase:   strings.TrimRight(env("CI_GIT_BASE", "https://git.hanzo.ai"), "/"),
		gitToken:  os.Getenv("CI_GIT_TOKEN"),
		scanRepos: envInt("CI_SCAN_REPOS", 60),
		runsPer:   envInt("CI_RUNS_PER_REPO", 8),
	}
	c.refresh = time.Duration(envInt("CI_REFRESH_SECONDS", 45)) * time.Second
	// Stale is a multiple of refresh, not its own knob: the only meaningful
	// definition of stale is "we have missed several refreshes", and deriving
	// it means the two can never be configured into contradiction.
	c.staleAfter = 4 * c.refresh
	if c.gitToken == "" {
		return c, errors.New("CI_GIT_TOKEN required (Hanzo Git API token)")
	}
	return c, nil
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envInt(k string, def int) int {
	if v, err := strconv.Atoi(os.Getenv(k)); err == nil && v > 0 {
		return v
	}
	return def
}

// ───────────────────────────── model ─────────────────────────────

// Run is the projection of a Hanzo Git workflow run this dashboard shows. It is
// deliberately a SUBSET: the upstream object carries a dozen more fields, and
// copying them all would make this a second schema to maintain against theirs.
type Run struct {
	ID       int64  `json:"id"`
	Org      string `json:"org"`
	Repo     string `json:"repo"`
	Workflow string `json:"workflow"`
	Title    string `json:"title"`

	// Status and Conclusion are BOTH required to know how a run went, and
	// reading only one is wrong in a way that looks fine. Status answers
	// "is it over" (queued | in_progress | completed); Conclusion answers
	// "how did it end" and is empty until it is over. A view that buckets on
	// Status alone sees `completed` and cannot tell a pass from a failure —
	// which is exactly the bug this pair replaced: every finished run,
	// including successes and cancellations, was being drawn as failing.
	Status     string `json:"status"`
	Conclusion string `json:"conclusion"`

	Event     string    `json:"event"`
	Branch    string    `json:"branch"`
	SHA       string    `json:"sha"`
	Actor     string    `json:"actor"`
	Number    int       `json:"number"`
	URL       string    `json:"url"`
	StartedAt time.Time `json:"startedAt"`
	EndedAt   time.Time `json:"endedAt"`
}

// Duration is zero-valued rather than negative when a run has not finished —
// callers render "running", and a negative duration would print as one.
func (r Run) Duration() time.Duration {
	if r.StartedAt.IsZero() || r.EndedAt.IsZero() || r.EndedAt.Before(r.StartedAt) {
		return 0
	}
	return r.EndedAt.Sub(r.StartedAt)
}

type snapshot struct {
	Runs      []Run     `json:"runs"`
	Repos     int       `json:"repos"`
	FetchedAt time.Time `json:"fetchedAt"`
	Err       error     `json:"-"`
}

func (s snapshot) stale(after time.Duration) bool {
	return s.FetchedAt.IsZero() || time.Since(s.FetchedAt) > after
}

func (s snapshot) errString() string {
	if s.Err == nil {
		return ""
	}
	return s.Err.Error()
}

type runCache struct {
	mu   sync.RWMutex
	snap snapshot
}

func (c *runCache) get() snapshot {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.snap
}

// put keeps the LAST GOOD run list when a refresh fails, recording the error
// alongside it. A failed poll must not blank the dashboard: "Hanzo Git is
// unreachable, here is what we last saw" is strictly more useful than an empty
// page, which reads as "nothing is building".
func (c *runCache) put(s snapshot) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if s.Err != nil && len(s.Runs) == 0 && len(c.snap.Runs) > 0 {
		prev := c.snap
		prev.Err = s.Err
		c.snap = prev
		return
	}
	c.snap = s
}

// ───────────────────────────── source ─────────────────────────────

type gitSource struct {
	base  string
	token string
	http  *http.Client
}

func (g *gitSource) getJSON(ctx context.Context, path string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, g.base+path, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "token "+g.token)
	req.Header.Set("Accept", "application/json")
	resp, err := g.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s: %s", path, resp.Status)
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

type repoRef struct {
	FullName string `json:"full_name"`
}

// repos returns the most recently ACTIVE repositories. Sorting by activity and
// taking a window is the whole scan strategy: the instance mirrors ~1400 repos
// and almost none of them built in the last hour, so walking all of them would
// spend the entire refresh budget confirming silence.
func (g *gitSource) repos(ctx context.Context, limit int) ([]string, error) {
	var body struct {
		Data []repoRef `json:"data"`
	}
	q := url.Values{}
	q.Set("sort", "updated")
	q.Set("order", "desc")
	q.Set("limit", strconv.Itoa(limit))
	if err := g.getJSON(ctx, "/v1/repos/search?"+q.Encode(), &body); err != nil {
		return nil, err
	}
	names := make([]string, 0, len(body.Data))
	for _, r := range body.Data {
		if r.FullName != "" {
			names = append(names, r.FullName)
		}
	}
	return names, nil
}

type apiRun struct {
	ID           int64  `json:"id"`
	DisplayTitle string `json:"display_title"`
	Path         string `json:"path"`
	Event        string `json:"event"`
	Status       string `json:"status"`
	Conclusion   string `json:"conclusion"`
	HeadBranch   string `json:"head_branch"`
	HeadSHA      string `json:"head_sha"`
	RunNumber    int    `json:"run_number"`
	HTMLURL      string `json:"html_url"`
	StartedAt    string `json:"started_at"`
	CompletedAt  string `json:"completed_at"`
	Actor        struct {
		Login string `json:"login"`
	} `json:"actor"`
}

func (g *gitSource) runs(ctx context.Context, fullName string, limit int) ([]Run, error) {
	var body struct {
		WorkflowRuns []apiRun `json:"workflow_runs"`
	}
	path := fmt.Sprintf("/v1/repos/%s/actions/runs?limit=%d", fullName, limit)
	if err := g.getJSON(ctx, path, &body); err != nil {
		return nil, err
	}
	org, repo := splitFullName(fullName)
	out := make([]Run, 0, len(body.WorkflowRuns))
	for _, r := range body.WorkflowRuns {
		out = append(out, Run{
			ID:         r.ID,
			Org:        org,
			Repo:       repo,
			Workflow:   workflowOf(r.Path),
			Title:      r.DisplayTitle,
			Status:     r.Status,
			Conclusion: r.Conclusion,
			Event:      r.Event,
			Branch:     r.HeadBranch,
			SHA:        shortSHA(r.HeadSHA),
			Actor:      r.Actor.Login,
			Number:     r.RunNumber,
			URL:        r.HTMLURL,
			StartedAt:  parseTime(r.StartedAt),
			EndedAt:    parseTime(r.CompletedAt),
		})
	}
	return out, nil
}

// poll refreshes the snapshot on an interval, forever.
func poll(ctx context.Context, logger *slog.Logger, src *gitSource, cache *runCache, cfg config) {
	refresh := func() {
		rctx, cancel := context.WithTimeout(ctx, 90*time.Second)
		defer cancel()

		names, err := src.repos(rctx, cfg.scanRepos)
		if err != nil {
			logger.Warn("repo scan failed", "err", err)
			cache.put(snapshot{FetchedAt: time.Now().UTC(), Err: err})
			return
		}

		// Fan out, bounded. The cap is small on purpose: this is a read against
		// the forge that schedules every build in the fleet, and a dashboard is
		// never worth degrading it.
		const workers = 6
		var (
			mu   sync.Mutex
			all  []Run
			errs []string
			wg   sync.WaitGroup
		)
		jobs := make(chan string)
		for i := 0; i < workers; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				for name := range jobs {
					rs, err := src.runs(rctx, name, cfg.runsPer)
					mu.Lock()
					if err != nil {
						// A repo with Actions disabled 404s. That is normal and
						// not worth surfacing as a dashboard-level failure, so
						// it is counted, not shown.
						errs = append(errs, name)
					} else {
						all = append(all, rs...)
					}
					mu.Unlock()
				}
			}()
		}
		for _, n := range names {
			select {
			case jobs <- n:
			case <-rctx.Done():
			}
		}
		close(jobs)
		wg.Wait()

		sort.Slice(all, func(i, j int) bool { return all[i].StartedAt.After(all[j].StartedAt) })
		cache.put(snapshot{Runs: all, Repos: len(names) - len(errs), FetchedAt: time.Now().UTC()})
		logger.Info("refreshed", "repos", len(names), "withRuns", len(names)-len(errs), "runs", len(all))
	}

	refresh()
	t := time.NewTicker(cfg.refresh)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			refresh()
		}
	}
}

// ───────────────────────────── helpers ─────────────────────────────

func splitFullName(s string) (org, repo string) {
	if i := strings.IndexByte(s, '/'); i > 0 {
		return s[:i], s[i+1:]
	}
	return "", s
}

// workflowOf reduces "e2e.yml@refs/heads/main" to "e2e.yml".
func workflowOf(path string) string {
	if i := strings.IndexByte(path, '@'); i > 0 {
		return path[:i]
	}
	return path
}

func shortSHA(s string) string {
	if len(s) > 7 {
		return s[:7]
	}
	return s
}

func parseTime(s string) time.Time {
	if s == "" {
		return time.Time{}
	}
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return time.Time{}
	}
	// Hanzo Git reports an unset timestamp as the Unix epoch rather than null;
	// treated as absent so the UI shows "—" instead of 1970.
	if t.Year() < 2000 {
		return time.Time{}
	}
	return t.UTC()
}

func filterByOrg(runs []Run, org string) []Run {
	if org == "" {
		return runs
	}
	out := make([]Run, 0, len(runs))
	for _, r := range runs {
		if r.Org == org {
			out = append(out, r)
		}
	}
	return out
}

func orgsOf(runs []Run) []string {
	seen := map[string]bool{}
	for _, r := range runs {
		if r.Org != "" {
			seen[r.Org] = true
		}
	}
	out := make([]string, 0, len(seen))
	for o := range seen {
		out = append(out, o)
	}
	sort.Strings(out)
	return out
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
