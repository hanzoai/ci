package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/url"
	"strings"
	"sync"
	"time"
)

// forge.go reads the two things the forge knows that the run list does not: what
// hanzoai/universe declares, and which commit last produced a proved image.
//
// Both come from the same host over the same token this service already holds.
// The universe repo lives on the forge, so the declared state of the fleet is a
// file read — no second credential, no checkout, no clone on disk.

// A commit that has just landed has no run for a moment. Below this age a
// missing run is the forge still constructing one, and calling that absent would
// alarm on every push.
const settling = 5 * time.Minute

// How far back the walk looks for the last commit that built. Every step is a
// read against the forge, and past this depth the answer is already "this has not
// built in a long time", which the count says without another call.
const reach = 12

const valuesRoot = "charts/app/values"

// The names the pipeline this repo publishes gives to the work that matters.
// They are a contract INSIDE this repo — the reusable and this view ship
// together — so reading them is reading our own declaration, not guessing at
// someone else's.
const (
	imageJob = "image"
	// Both are the moment an artifact is produced; a repo has one or the other.
	imageStep = "Build & push images"
	// Exactly one of these two runs on every build: the gate, or the caller's
	// explicit opt-out. Reading both is what separates a build that was tested
	// from one that merely reported success.
	testStep   = "Test (per hanzo.yml)"
	testOptOut = "Tests not run"
)

// pins reads the declared fleet: charts/app/values/<namespace>/<name>.yaml, one
// file per service, each naming the image tag and digest Hanzo CD applies.
//
// The whole read is keyed on the universe head commit. The declared state only
// changes when someone commits to universe, so re-reading a hundred unchanged
// files every cycle would spend the budget confirming that nothing moved.
func (g *gitSource) pins(ctx context.Context, repo string) (map[string]pin, error) {
	head, err := g.head(ctx, repo, "")
	if err != nil {
		return nil, err
	}

	g.mu.Lock()
	if g.pinsAt == head.SHA && g.pinned != nil {
		out := g.pinned
		g.mu.Unlock()
		return out, nil
	}
	g.mu.Unlock()

	spaces, err := g.list(ctx, repo, valuesRoot)
	if err != nil {
		return nil, err
	}

	out := map[string]pin{}
	var mu sync.Mutex
	err = each(ctx, spaces, func(ctx context.Context, space entry) error {
		if space.Type != "dir" {
			return nil
		}
		files, err := g.list(ctx, repo, valuesRoot+"/"+space.Name)
		if err != nil {
			return err
		}
		return each(ctx, files, func(ctx context.Context, f entry) error {
			if !strings.HasSuffix(f.Name, ".yaml") {
				return nil
			}
			path := valuesRoot + "/" + space.Name + "/" + f.Name
			body, err := g.raw(ctx, repo, path)
			if err != nil {
				return err
			}
			image, v := declared(body)
			if image == "" {
				// A values file with no image block declares no image — a chart
				// that renders configuration, routes or a set of static hosts.
				return nil
			}
			at, _ := g.touched(ctx, repo, path)
			mu.Lock()
			out[space.Name+"/"+strings.TrimSuffix(f.Name, ".yaml")] = pin{
				Name:      strings.TrimSuffix(f.Name, ".yaml"),
				Namespace: space.Name,
				Image:     image,
				Version:   v,
				At:        at,
			}
			mu.Unlock()
			return nil
		})
	})
	if err != nil {
		return nil, err
	}

	g.mu.Lock()
	g.pinsAt, g.pinned = head.SHA, out
	g.mu.Unlock()
	return out, nil
}

type entry struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

func (g *gitSource) list(ctx context.Context, repo, path string) ([]entry, error) {
	var out []entry
	err := g.getJSON(ctx, "/v1/repos/"+repo+"/contents/"+path, &out)
	return out, err
}

// touched reports when a path was last committed — for a values file, when the
// pin it holds was written. Age is what makes drift actionable: a service one
// release behind for a minute is a deploy in flight, and the same service one
// release behind since this morning is a deploy that never happened.
func (g *gitSource) touched(ctx context.Context, repo, path string) (time.Time, error) {
	var out []struct {
		Commit struct {
			Committer struct {
				Date string `json:"date"`
			} `json:"committer"`
		} `json:"commit"`
	}
	q := url.Values{"limit": {"1"}, "path": {path}}
	if err := g.getJSON(ctx, "/v1/repos/"+repo+"/commits?"+q.Encode(), &out); err != nil || len(out) == 0 {
		return time.Time{}, err
	}
	return parseTime(out[0].Commit.Committer.Date), nil
}

// raw fetches a file's bytes from the default branch.
func (g *gitSource) raw(ctx context.Context, repo, path string) (string, error) {
	return g.getText(ctx, "/v1/repos/"+repo+"/raw/"+path)
}

// ───────────────────────────── the built end ─────────────────────────────

// links accounts for each declared image against the repo that builds it. One
// repo can publish an image several services run, so the answer is keyed by
// image and shared by all of them.
func (g *gitSource) links(ctx context.Context, logger *slog.Logger, pins []pin) map[string]link {
	seen := map[string]pin{}
	for _, p := range pins {
		if _, ok := seen[p.Image]; !ok {
			seen[p.Image] = p
		}
	}
	want := make([]pin, 0, len(seen))
	for _, p := range seen {
		want = append(want, p)
	}

	out := map[string]link{}
	var mu sync.Mutex
	_ = each(ctx, want, func(ctx context.Context, p pin) error {
		repo, branch, err := g.locate(ctx, p)
		if err != nil || repo == "" {
			return nil
		}
		c, err := g.link(ctx, repo, branch)
		if err != nil {
			logger.Warn("chain read failed", "repo", repo, "err", err)
			return nil
		}
		mu.Lock()
		out[p.Image] = c
		mu.Unlock()
		return nil
	})
	return out
}

// locate finds the repo that publishes an image.
//
// An image reference already names its publisher: ghcr.io/hanzoai/analytics is
// the hanzoai org's analytics. So a repo at exactly that org and name IS the
// publisher, and nothing further needs proving.
//
// Where that repo does not exist the publisher sits in another org — ghcr.io/
// hanzoai/cloud is built by hanzo-inc/cloud — and there the name alone is
// ambiguous, because half a dozen orgs on this forge hold a repo called cloud.
// Then the declared tag decides: the repo carrying the tag the fleet is running
// is the repo that cut it. An image no candidate can be shown to publish stays
// unlinked, and the page says so rather than showing a guess.
func (g *gitSource) locate(ctx context.Context, p pin) (repo, branch string, err error) {
	g.mu.Lock()
	if r, ok := g.located[p.Image]; ok {
		g.mu.Unlock()
		return r.repo, r.branch, nil
	}
	g.mu.Unlock()

	name := imageName(p.Image)
	if parts := strings.Split(p.Image, "/"); len(parts) >= 3 {
		direct := parts[len(parts)-2] + "/" + name
		if b, ok := g.branchOf(ctx, direct); ok {
			return g.remember(p.Image, direct, b)
		}
	}
	var body struct {
		Data []struct {
			FullName string `json:"full_name"`
			Branch   string `json:"default_branch"`
		} `json:"data"`
	}
	q := url.Values{"q": {name}, "limit": {"30"}}
	if err := g.getJSON(ctx, "/v1/repos/search?"+q.Encode(), &body); err == nil {
		for _, r := range body.Data {
			if _, n := splitFullName(r.FullName); n == name && g.holds(ctx, r.FullName, p.Version.Tag) {
				return g.remember(p.Image, r.FullName, r.Branch)
			}
		}
	}
	return g.remember(p.Image, "", "")
}

type place struct{ repo, branch string }

func (g *gitSource) remember(image, repo, branch string) (string, string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.located == nil {
		g.located = map[string]place{}
	}
	g.located[image] = place{repo: repo, branch: branch}
	return repo, branch, nil
}

// branchOf reports a repo's default branch, and whether the repo exists at all.
func (g *gitSource) branchOf(ctx context.Context, repo string) (string, bool) {
	var out struct {
		Branch string `json:"default_branch"`
	}
	if err := g.getJSON(ctx, "/v1/repos/"+repo, &out); err != nil {
		return "", false
	}
	return out.Branch, true
}

// holds reports whether a repo carries the given tag.
func (g *gitSource) holds(ctx context.Context, repo, tag string) bool {
	if tag == "" {
		return false
	}
	var out struct {
		Name string `json:"name"`
	}
	return g.getJSON(ctx, "/v1/repos/"+repo+"/tags/"+url.PathEscape(tag), &out) == nil && out.Name != ""
}

// link reads the forge end of the line: what we wrote, and what was last proved.
func (g *gitSource) link(ctx context.Context, repo, branch string) (link, error) {
	org, _ := splitFullName(repo)
	c := link{Repo: repo, Org: org}

	commits, err := g.commits(ctx, repo, branch, 30)
	if err != nil || len(commits) == 0 {
		return c, err
	}
	c.Head = Head{SHA: commits[0].SHA, Title: commits[0].Title, At: commits[0].At}

	runs, err := g.runs(ctx, repo, 20)
	if err != nil {
		return c, err
	}
	byCommit := map[string]Run{}
	for _, r := range runs {
		// The first run listed for a commit is its newest attempt.
		if _, seen := byCommit[r.SHA]; !seen {
			byCommit[r.SHA] = r
		}
	}

	// Walk back from the tip until a commit is found whose run actually produced
	// an image. That commit is what the fleet could be running, the tag sitting
	// on it is what to call it, and the distance is how far main has moved since.
	//
	// The walk is what makes the count true rather than approximate: tags are
	// claimed BEFORE a build runs, so the newest tag is not evidence of anything
	// having been built, and reading it as `built` would name a release that does
	// not exist.
	tags, _ := g.tags(ctx, repo, 40)
	window := min(len(commits), reach)
	built := -1
	var stuck []commit
	for i := 0; i < window; i++ {
		b := g.built(ctx, repo, byCommit[shortSHA(commits[i].SHA)], commits[i].At)
		if i == 0 {
			c.Head.Build = b
		}
		if b.passed() {
			built = i
			break
		}
		// Counted only once it has stopped. A commit still building has not
		// failed to produce an image, it has not finished producing one, and
		// counting it would put every service on this board for the length of
		// its own build.
		if b.State != "running" {
			stuck = append(stuck, commits[i])
		}
	}
	c.Behind = len(stuck)
	if len(stuck) > 0 {
		c.Since = stuck[len(stuck)-1].At
	}
	// Whether a commit built and what to CALL what it built are two questions.
	// A pipeline that builds without claiming a tag leaves the version unnamed —
	// which the page shows as unknown — while the commit still counts as built,
	// so an untagged build must not read as nothing having been built at all.
	if built >= 0 {
		c.Built = Version{Tag: tags[commits[built].SHA]}
	}
	return c, nil
}

type commit struct {
	SHA   string
	Title string
	At    time.Time
}

func (g *gitSource) commits(ctx context.Context, repo, branch string, limit int) ([]commit, error) {
	var out []struct {
		SHA    string `json:"sha"`
		Commit struct {
			Message   string `json:"message"`
			Committer struct {
				Date string `json:"date"`
			} `json:"committer"`
		} `json:"commit"`
	}
	q := url.Values{"limit": {fmt.Sprint(limit)}}
	if branch != "" {
		q.Set("sha", branch)
	}
	if err := g.getJSON(ctx, "/v1/repos/"+repo+"/commits?"+q.Encode(), &out); err != nil {
		return nil, err
	}
	cs := make([]commit, 0, len(out))
	for _, c := range out {
		title, _, _ := strings.Cut(c.Commit.Message, "\n")
		cs = append(cs, commit{SHA: c.SHA, Title: title, At: parseTime(c.Commit.Committer.Date)})
	}
	return cs, nil
}

// head reports the tip commit of a repo's default branch.
func (g *gitSource) head(ctx context.Context, repo, branch string) (commit, error) {
	cs, err := g.commits(ctx, repo, branch, 1)
	if err != nil {
		return commit{}, err
	}
	if len(cs) == 0 {
		return commit{}, fmt.Errorf("%s: no commits", repo)
	}
	return cs[0], nil
}

// tags maps commit sha to the tag naming it.
func (g *gitSource) tags(ctx context.Context, repo string, limit int) (map[string]string, error) {
	var out []struct {
		Name   string `json:"name"`
		Commit struct {
			SHA string `json:"sha"`
		} `json:"commit"`
	}
	if err := g.getJSON(ctx, fmt.Sprintf("/v1/repos/%s/tags?limit=%d", repo, limit), &out); err != nil {
		return nil, err
	}
	m := map[string]string{}
	for _, t := range out {
		if _, seen := m[t.Commit.SHA]; !seen {
			m[t.Commit.SHA] = t.Name
		}
	}
	return m, nil
}

func (g *gitSource) built(ctx context.Context, repo string, r Run, at time.Time) Build {
	if r.ID == 0 {
		return verdict(Run{}, nil, at)
	}
	jobs, err := g.jobs(ctx, repo, r.ID)
	if err != nil {
		// The run is known even when its jobs are not; report what the run says
		// rather than nothing.
		return Build{Number: r.Number, URL: r.URL, At: r.StartedAt, State: outcome(r)}
	}
	return verdict(r, jobs, at)
}

// verdict reads how one commit fared, from its jobs rather than its run.
//
// A run carries ONE conclusion for all of its jobs, and on this pipeline that
// single value cannot distinguish a build that never started from one that
// finished, shipped and then failed a trailing step. The jobs can: the artifact
// step is what produces the image, so it is what decides whether a commit became
// something shippable.
//
// It is separated from the fetch because the decision is the part worth pinning:
// which job failed, and whether an artifact exists, is what the page turns on.
func verdict(r Run, jobs []job, at time.Time) Build {
	if r.ID == 0 {
		// No run for this commit. A push that has only just landed is the forge
		// still constructing one; older than that, the run is genuinely absent —
		// a workflow that could not be parsed or a reference that would not
		// resolve, which leaves no failed run to open.
		if time.Since(at) < settling {
			return Build{State: "running"}
		}
		return Build{State: "absent"}
	}
	b := Build{Number: r.Number, URL: r.URL, At: r.StartedAt, State: outcome(r)}

	// A repo publishes its image one of two ways, and both are read: a pipeline
	// with a job of its own for the artifact, or the reusable's lane, which
	// builds inside its `cicd` job as a step. A dedicated job wins where both
	// appear, because then the job is the pipeline's own answer.
	var byJob, byStep, failed string
	for _, j := range jobs {
		for _, s := range j.Steps {
			switch {
			case strings.HasPrefix(s.Name, testStep):
				b.Verdict = true
				b.Tested = strings.EqualFold(s.Conclusion, "success")
			case strings.HasPrefix(s.Name, testOptOut):
				// The complement of the gate: it runs only when the caller
				// declared the commit already proven elsewhere. Recorded as a
				// verdict that this build did not test.
				if strings.EqualFold(s.Conclusion, "success") {
					b.Verdict = true
				}
			case strings.HasPrefix(s.Name, imageStep):
				byStep = strings.ToLower(s.Conclusion)
			}
		}
		switch {
		case j.Name == imageJob:
			byJob = strings.ToLower(j.Conclusion)
		case strings.EqualFold(j.Conclusion, "failure") && failed == "":
			failed = j.Name
		}
	}
	b.Job = failed

	image := byJob
	if image == "" {
		image = byStep
	}
	switch image {
	case "success":
		// The artifact exists, so the commit shipped something. A later job may
		// still have failed; its name is kept so the page can say the build
		// shipped and something after it did not.
		b.State = "success"
	case "skipped":
		if b.State == "success" {
			// Green without producing the artifact it exists to produce.
			b.State = "failure"
		}
	}
	// An empty answer means the run reported no artifact step at all, which is no
	// evidence either way — so the run's own conclusion stands. Reading silence
	// as failure would mark every pipeline shaped unlike this one as broken.
	return b
}

type job struct {
	Name       string `json:"name"`
	Conclusion string `json:"conclusion"`
	Steps      []struct {
		Name       string `json:"name"`
		Conclusion string `json:"conclusion"`
	} `json:"steps"`
}

func (g *gitSource) jobs(ctx context.Context, repo string, run int64) ([]job, error) {
	var body struct {
		Jobs []job `json:"jobs"`
	}
	err := g.getJSON(ctx, fmt.Sprintf("/v1/repos/%s/actions/runs/%d/jobs", repo, run), &body)
	return body.Jobs, err
}

// each runs fn over items with a small fixed fan-out. The cap is deliberately
// low: these are reads against the forge that schedules every build in the
// fleet, and a dashboard is never worth degrading it.
func each[T any](ctx context.Context, items []T, fn func(context.Context, T) error) error {
	const workers = 4
	var (
		wg   sync.WaitGroup
		mu   sync.Mutex
		errs error
	)
	in := make(chan T)
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for it := range in {
				if err := fn(ctx, it); err != nil {
					mu.Lock()
					errs = err
					mu.Unlock()
				}
			}
		}()
	}
	for _, it := range items {
		select {
		case in <- it:
		case <-ctx.Done():
		}
	}
	close(in)
	wg.Wait()
	return errs
}
