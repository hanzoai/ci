package main

import (
	"context"
	"log/slog"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// fleet.go answers one question per service: is what we wrote what is running?
//
// Four values answer it, and they are one causal line rather than four opinions.
// A push moves HEAD; the run on that commit builds and proves an image, which is
// BUILT; the same run writes the tag and digest into hanzoai/universe, which is
// DECLARED; Hanzo CD reconciles that pin onto the cluster, which is RUNNING.
//
//	head ──build──▶ built ──pin──▶ declared ──reconcile──▶ running
//
// Every arrow is a job of the pipeline this repo publishes, so a service is
// current exactly when all four agree, and each way they can disagree names the
// arrow that did not happen. Reading all four from the systems that own them —
// the forge, the universe repo, the cluster — is what makes this a measurement
// rather than a restatement of the last log line the pipeline wrote about itself.
//
// Three matching values are NOT health, which is the whole reason head is read:
// built, declared and running can agree perfectly while main has moved on and
// nothing since has produced an image.

// The ways the line can break. Each names a missing arrow, not a severity: a
// service can be several at once and the page says which.
const (
	unbuilt   = "unbuilt"   // head produced no image
	unshipped = "unshipped" // an image was proved that the pin never named
	unsynced  = "unsynced"  // the pin and the cluster disagree
	untested  = "untested"  // a passing build whose tests did not execute
)

// Version is one image as the registry answers for it: the tag a human reads and
// the digest the kubelet pulls. Both are carried because they answer different
// questions — a tag can be moved onto other bytes, a digest cannot.
type Version struct {
	Tag    string `json:"tag"`
	Digest string `json:"digest"`
}

func (v Version) known() bool { return v.Tag != "" || v.Digest != "" }

// Build is what the forge did with one commit.
type Build struct {
	// State is success | failure | running | absent. `absent` is not a kind of
	// failure and is kept apart from one: a failing run is a build that ran and
	// said no, while an absent run is the forge never having constructed a run
	// for the commit at all — a workflow it cannot parse or a reference it
	// cannot resolve. There is no log to open for the second, so a page that
	// draws them the same sends you looking for one that does not exist.
	State string `json:"state"`

	// Job is the job that decided State. A run reports one conclusion for
	// however many jobs it holds, and the jobs are not interchangeable: the
	// pipeline fails at `gate` before it builds anything and at `receipt` after
	// it has already built, pinned and proved the release live. Both read
	// `failure` on the run, and only the first one means nothing shipped.
	Job string `json:"job"`

	Number int       `json:"number"`
	URL    string    `json:"url"`
	At     time.Time `json:"at"`

	// Tested reports that the run's tests executed; Verdict reports that the run
	// said anything about tests at all. They are separate because the interesting
	// case is a run that passed while its test step was skipped — a green build
	// that proved nothing — and that is invisible if the two are one flag.
	Tested  bool `json:"tested"`
	Verdict bool `json:"verdict"`
}

func (b Build) passed() bool { return b.State == "success" }

// green is passed AND proved. A run that reported success without executing its
// tests is not a green build, and this is the one place that distinction is made.
func (b Build) green() bool { return b.passed() && (!b.Verdict || b.Tested) }

// Head is the tip of the default branch — what we wrote.
type Head struct {
	SHA   string    `json:"sha"`
	Title string    `json:"title"`
	At    time.Time `json:"at"`
	Build Build     `json:"build"`
}

// Service is one declared workload and the chain behind it.
type Service struct {
	Name      string `json:"name"`      // cloud
	Namespace string `json:"namespace"` // hanzo
	Image     string `json:"image"`     // ghcr.io/hanzoai/cloud
	Org       string `json:"org"`       // forge owner; empty when the repo is unresolved
	Repo      string `json:"repo"`      // hanzo-inc/cloud

	Head     Head    `json:"head"`
	Built    Version `json:"built"`
	Declared Version `json:"declared"`
	Running  Version `json:"running"`

	Ready int `json:"ready"`
	Want  int `json:"want"`

	// Behind counts commits after the one that last produced an image whose own
	// build has FINISHED without producing one, and Since is when the oldest of
	// them landed. A commit still building is not counted, so a push in flight is
	// not drift and a service appears here only once something has actually
	// stopped without shipping. How long that has stood is the number worth
	// acting on; that it is true says nothing about whether anyone should move.
	Behind   int       `json:"behind"`
	Since    time.Time `json:"since"`
	PinnedAt time.Time `json:"pinnedAt"`

	Drift []string `json:"drift"`
}

// current reports a service whose four values agree.
func (s Service) current() bool { return len(s.Drift) == 0 }

// alike reports whether two versions name the same image, and whether that could
// be decided at all. The second result is what keeps an unread source from
// rendering as a difference: a value we failed to fetch is not a value that
// disagrees, and a board that conflates them cries wolf on its own outages.
func alike(a, b Version) (same, decided bool) {
	switch {
	case a.Digest != "" && b.Digest != "":
		return a.Digest == b.Digest, true
	case a.Tag != "" && b.Tag != "":
		return a.Tag == b.Tag, true
	}
	return false, false
}

// order parses a tag as dotted numbers with an optional leading v. It reports
// false for anything else — a commit tag, a date stamp — so that tags which have
// no order are never given one.
func order(tag string) ([]int, bool) {
	t := strings.TrimPrefix(strings.TrimSpace(tag), "v")
	if t == "" {
		return nil, false
	}
	parts := strings.Split(t, ".")
	out := make([]int, 0, len(parts))
	for _, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil || n < 0 {
			return nil, false
		}
		out = append(out, n)
	}
	return out, true
}

// after reports whether tag a orders strictly after tag b, and whether both
// could be ordered. Deciding "different" would be easy and wrong: a rollback
// pins a tag deliberately older than the newest build, and calling that a
// missing release trains people to ignore the one that is real.
func after(a, b string) (yes, decided bool) {
	x, ok := order(a)
	if !ok {
		return false, false
	}
	y, ok := order(b)
	if !ok {
		return false, false
	}
	for i := 0; i < len(x) || i < len(y); i++ {
		var xi, yi int
		if i < len(x) {
			xi = x[i]
		}
		if i < len(y) {
			yi = y[i]
		}
		if xi != yi {
			return xi > yi, true
		}
	}
	return false, true
}

// assess names every broken arrow in the line. Each test is written so that an
// undecidable comparison adds nothing.
func (s *Service) assess() {
	s.Drift = nil

	// The cluster is not running what universe declares: Hanzo CD is behind,
	// stuck, or failing to apply the pin.
	if same, decided := alike(s.Declared, s.Running); decided && !same {
		s.Drift = append(s.Drift, unsynced)
	}

	// An image was built and proved that the pin never named.
	if ahead, decided := after(s.Built.Tag, s.Declared.Tag); decided && ahead {
		s.Drift = append(s.Drift, unshipped)
	}

	// Head produced no image. Behind counts only commits whose build has stopped,
	// so this holds whether the run failed or was never constructed, and not
	// while one is still going.
	if s.Repo != "" && s.Behind > 0 {
		s.Drift = append(s.Drift, unbuilt)
	}

	// A passing build that did not execute its tests. Kept separate from the
	// three version comparisons because the versions all agree in this case —
	// the line is intact and what flowed down it was never proved.
	if s.Head.Build.passed() && s.Head.Build.Verdict && !s.Head.Build.Tested {
		s.Drift = append(s.Drift, untested)
	}
}

// ───────────────────────────── assembly ─────────────────────────────

// pin is one service as hanzoai/universe declares it.
type pin struct {
	Name      string
	Namespace string
	Image     string
	Version   Version
	At        time.Time
}

// live is one service as the cluster runs it.
type live struct {
	Name      string
	Namespace string
	Image     string
	Version   Version
	Ready     int
	Want      int
}

// link is one repo as the forge accounts for it.
type link struct {
	Repo   string
	Org    string
	Head   Head
	Built  Version
	Behind int
	Since  time.Time
}

// assemble joins the three reads.
//
// A SERVICE is one declared workload — its namespace and name — and NOT its
// image, because one image runs as several services at once: ghcr.io/hanzoai/
// static is cdn, tabs and zen-landing, on three different versions. Keying rows
// by image would collapse those into one row and then compare one service's pin
// against another's running version, which manufactures drift that is not there.
//
// So the namespace and name carry the row, the cluster is matched on the same
// pair, and the IMAGE is what joins to the forge — several services legitimately
// share one repo, and then they share its head and its last build too.
func assemble(pins []pin, lives []live, links map[string]link) []Service {
	at := func(namespace, name string) string { return namespace + "/" + name }
	byName := make(map[string]*Service, len(pins))
	for _, p := range pins {
		byName[at(p.Namespace, p.Name)] = &Service{
			Name: p.Name, Namespace: p.Namespace, Image: p.Image,
			Declared: p.Version, PinnedAt: p.At,
		}
	}
	for _, l := range lives {
		// The declared set decides which rows exist. A running image nothing
		// declares is a sidecar or a workload from another chart, and inventing a
		// row for it would fill the board with things nobody promised.
		s, ok := byName[at(l.Namespace, l.Name)]
		if !ok || l.Image != s.Image {
			// A workload of the right name still has to be running the image the
			// service declares; its sidecars are not the service.
			continue
		}
		// A workload runs the declared version if ANY of its containers does.
		// Two containers can share the repository and hold different versions on
		// purpose — a sidecar pinned back while the app moves on — and taking
		// whichever the loop reached last reported the pin unapplied on a service
		// whose app container was carrying it. Preferring the match answers the
		// question the column asks: is what we declared running here. For the
		// single-container case, which is nearly every row, nothing changes.
		if same, decided := alike(s.Running, s.Declared); decided && same {
			continue
		}
		s.Running, s.Ready, s.Want = l.Version, l.Ready, l.Want
	}
	for _, s := range byName {
		if c, ok := links[s.Image]; ok {
			s.Repo, s.Org, s.Head, s.Built, s.Behind, s.Since = c.Repo, c.Org, c.Head, c.Built, c.Behind, c.Since
		}
	}

	out := make([]Service, 0, len(byName))
	for _, s := range byName {
		s.assess()
		out = append(out, *s)
	}
	sort.Slice(out, func(i, j int) bool {
		// Drifting services first, longest-drifting at the top: the page is read
		// to find what needs doing, and the oldest break is the one that has been
		// unattended longest.
		a, b := out[i], out[j]
		if a.current() != b.current() {
			return b.current()
		}
		if !a.current() && !a.Since.Equal(b.Since) {
			return a.Since.Before(b.Since)
		}
		if a.Namespace != b.Namespace {
			return a.Namespace < b.Namespace
		}
		return a.Name < b.Name
	})
	return out
}

// imageName reduces ghcr.io/hanzoai/cloud to cloud.
func imageName(image string) string {
	if i := strings.LastIndexByte(image, '/'); i >= 0 {
		return image[i+1:]
	}
	return image
}

// ───────────────────────────── snapshot ─────────────────────────────

type fleet struct {
	Services  []Service `json:"services"`
	FetchedAt time.Time `json:"fetchedAt"`
	Err       error     `json:"-"`
}

func (f fleet) stale(after time.Duration) bool {
	return f.FetchedAt.IsZero() || time.Since(f.FetchedAt) > after
}

func (f fleet) errString() string {
	if f.Err == nil {
		return ""
	}
	return f.Err.Error()
}

type fleetCache struct {
	mu   sync.RWMutex
	snap fleet
}

func (c *fleetCache) get() fleet {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.snap
}

// put keeps the last good service list when a refresh fails, for the same reason
// the run cache does: "we could not read, here is what we last saw" is a true
// statement, and an empty board is a false one that reads as "nothing is wrong".
func (c *fleetCache) put(f fleet) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if f.Err != nil && len(f.Services) == 0 && len(c.snap.Services) > 0 {
		prev := c.snap
		prev.Err = f.Err
		c.snap = prev
		return
	}
	c.snap = f
}

// visible narrows services to what v may see, then applies want within that
// permission — the same ordering scope.go applies to runs, for the same reason.
//
// A service whose repo could not be resolved carries no org, and only the admin
// org sees it. That falls out of the same match rather than needing a rule of its
// own: a tenant is always narrowed to its own org slug, which is never empty, so
// an unattributed row matches no tenant. Tenancy we could not establish is
// therefore never granted to a tenant by default.
func (v viewer) services(all []Service, want string) []Service {
	want = strings.TrimSpace(want)
	if !v.sudo {
		if want != "" && !strings.EqualFold(want, v.org) {
			return nil
		}
		want = v.org
	}
	out := make([]Service, 0, len(all))
	for _, s := range all {
		if want != "" && !strings.EqualFold(s.Org, want) {
			continue
		}
		out = append(out, s)
	}
	return out
}

// orgsOfServices lists the orgs present in a service list. It is called with a
// list that has ALREADY passed v.services, so a tenant's nav is built from a
// tenant's rows and cannot name an org whose rows were filtered out.
func orgsOfServices(services []Service) []string {
	seen := map[string]bool{}
	for _, s := range services {
		if s.Org != "" {
			seen[s.Org] = true
		}
	}
	out := make([]string, 0, len(seen))
	for o := range seen {
		out = append(out, o)
	}
	sort.Strings(out)
	return out
}

// ───────────────────────────── poller ─────────────────────────────

// watch refreshes the fleet snapshot on its own interval.
//
// It is slower than the run poll because the values it reads move on deploy
// cadence rather than push cadence, and each cycle costs the forge a read per
// service. Nothing about a dashboard justifies loading the forge that schedules
// every build in the fleet harder than the fleet itself does.
func watch(ctx context.Context, logger *slog.Logger, src *gitSource, cl *cluster, cache *fleetCache, cfg config) {
	refresh := func() {
		rctx, cancel := context.WithTimeout(ctx, 10*time.Minute)
		defer cancel()

		pins, err := src.pins(rctx, cfg.universe)
		if err != nil {
			logger.Warn("universe read failed", "err", err)
			cache.put(fleet{FetchedAt: time.Now().UTC(), Err: err})
			return
		}
		lives, err := cl.running(rctx)
		if err != nil {
			logger.Warn("cluster read failed", "err", err)
			cache.put(fleet{FetchedAt: time.Now().UTC(), Err: err})
			return
		}

		want := make([]pin, 0, len(pins))
		for _, p := range pins {
			want = append(want, p)
		}
		services := assemble(want, lives, src.links(rctx, logger, want))
		cache.put(fleet{Services: services, FetchedAt: time.Now().UTC()})

		var drifting int
		for _, s := range services {
			if !s.current() {
				drifting++
			}
		}
		logger.Info("fleet refreshed", "services", len(services),
			"running", len(lives), "drifting", drifting)
	}

	refresh()
	t := time.NewTicker(cfg.fleetRefresh)
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
