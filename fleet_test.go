package main

import (
	"testing"
	"time"
)

// fleet_test.go pins the reading of the four values.
//
// The tests are weighted toward the cases where the values AGREE and the service
// is still not serving what we wrote, because that is the shape a board misses:
// three matching numbers look like health, and a page that only compares them
// says nothing while the tip of main goes unbuilt for a day.

// TestAgreeingVersionsAreNotHealth is the case the whole view exists for.
//
// built, declared and running can all name the same release while main has moved
// on and nothing since has produced an image. Every version comparison holds and
// the service is still not running what we wrote, so the head of the branch has
// to be one of the values read — comparing the other three to each other cannot
// see this at all.
func TestAgreeingVersionsAreNotHealth(t *testing.T) {
	v := Version{Tag: "v1.801.548", Digest: "sha256:8830c2b1"}
	s := Service{
		Name: "cloud", Image: "ghcr.io/hanzoai/cloud", Repo: "hanzo-inc/cloud",
		Built: v, Declared: v, Running: v,
		Behind: 5, Since: time.Now().Add(-7 * time.Hour),
		Head: Head{SHA: "727d2934", Build: Build{State: "failure", Job: "gate"}},
	}
	s.assess()

	if s.current() {
		t.Fatal("a service whose head has produced no image reads as current")
	}
	if !hasDrift(s, unbuilt) {
		t.Errorf("drift = %v; want %s", s.Drift, unbuilt)
	}
	for _, wrong := range []string{unsynced, unshipped} {
		if hasDrift(s, wrong) {
			t.Errorf("drift = %v; %s is wrong when all three versions agree", s.Drift, wrong)
		}
	}
}

// TestShippedRunStillCountsAsBuilt separates the two ways a run goes red.
//
// The pipeline fails at `gate` before it builds anything, and at `receipt` after
// it has already built, pinned and proved the release live. The run reports
// `failure` for both. Only the first means nothing shipped, so the artifact — not
// the run's conclusion — is what decides whether a commit was built.
func TestShippedRunStillCountsAsBuilt(t *testing.T) {
	red := Run{ID: 1, Status: "completed", Conclusion: "failure"}

	shipped := verdict(red, []job{
		{Name: "gate", Conclusion: "success"},
		{Name: "image", Conclusion: "success"},
		{Name: "rollout", Conclusion: "success"},
		{Name: "receipt", Conclusion: "failure"},
	}, time.Now())
	if !shipped.passed() {
		t.Errorf("a run whose image job succeeded reads as %q — the artifact exists", shipped.State)
	}
	if shipped.Job != "receipt" {
		t.Errorf("deciding job = %q; want receipt, so the page can say what failed after it shipped", shipped.Job)
	}

	stopped := verdict(red, []job{
		{Name: "gate", Conclusion: "failure"},
		{Name: "image", Conclusion: "skipped"},
		{Name: "rollout", Conclusion: "skipped"},
	}, time.Now())
	if stopped.passed() {
		t.Error("a run that skipped its image job reads as built")
	}
	if stopped.Job != "gate" {
		t.Errorf("deciding job = %q; want gate", stopped.Job)
	}
}

// TestAbsentIsNotFailure keeps the two apart. A failing run can be opened and
// read; a commit Hanzo Git never built a run for cannot, and sending someone to
// look for a log that does not exist is its own delay.
func TestAbsentIsNotFailure(t *testing.T) {
	old := time.Now().Add(-time.Hour)
	if got := verdict(Run{}, nil, old); got.State != "absent" {
		t.Errorf("no run for an hour-old commit = %q; want absent", got.State)
	}
	// A commit that has only just landed has no run yet because Hanzo Git is
	// still constructing one. Calling that absent would alarm on every push.
	if got := verdict(Run{}, nil, time.Now()); got.State != "running" {
		t.Errorf("no run for a commit pushed seconds ago = %q; want running", got.State)
	}
}

// steps builds the anonymous step shape the jobs API decodes into.
func steps(pairs ...string) []struct {
	Name       string `json:"name"`
	Conclusion string `json:"conclusion"`
} {
	out := make([]struct {
		Name       string `json:"name"`
		Conclusion string `json:"conclusion"`
	}, 0, len(pairs)/2)
	for i := 0; i+1 < len(pairs); i += 2 {
		out = append(out, struct {
			Name       string `json:"name"`
			Conclusion string `json:"conclusion"`
		}{pairs[i], pairs[i+1]})
	}
	return out
}

// TestPassingWithoutTestsIsNotGreen covers a run that reports success while the
// step that would have proved anything did not execute.
func TestPassingWithoutTestsIsNotGreen(t *testing.T) {
	green := Run{ID: 1, Status: "completed", Conclusion: "success"}
	skipped := verdict(green, []job{
		{Name: "cicd", Conclusion: "success", Steps: steps(testStep, "skipped")},
		{Name: "image", Conclusion: "success"},
	}, time.Now())

	if !skipped.Verdict {
		t.Fatal("the test step was present and no verdict was recorded")
	}
	if skipped.Tested {
		t.Error("a skipped test step reads as tested")
	}
	if skipped.green() {
		t.Error("a passing run that never executed its tests reads as green")
	}

	s := Service{Repo: "hanzoai/ci", Head: Head{Build: skipped}}
	s.assess()
	if !hasDrift(s, untested) {
		t.Errorf("drift = %v; want %s", s.Drift, untested)
	}
}

// TestOptingOutOfTestsIsRecorded — the caller's `tests: 'false'` asserts the
// commit was proved elsewhere. It is a claim about another run, so this one still
// did not test, and the page says so rather than drawing it green.
func TestOptingOutOfTestsIsRecorded(t *testing.T) {
	green := Run{ID: 1, Status: "completed", Conclusion: "success"}
	out := verdict(green, []job{{Name: "cicd", Conclusion: "success",
		Steps: steps(testOptOut+" (declared by caller)", "success")},
		{Name: "image", Conclusion: "success"}}, time.Now())

	if !out.Verdict || out.Tested {
		t.Fatalf("opt-out read as verdict=%v tested=%v; want a verdict that did not test", out.Verdict, out.Tested)
	}
	if out.green() {
		t.Error("a build that declared itself untested reads as green")
	}
}

// TestArtifactIsReadFromEitherShape — a repo publishes its image either from a
// job of its own or from the reusable's step, and both are the same fact. A view
// that knew only one shape would report every repo built the other way as never
// having produced anything.
func TestArtifactIsReadFromEitherShape(t *testing.T) {
	green := Run{ID: 1, Status: "completed", Conclusion: "success"}

	byJob := verdict(green, []job{{Name: "image", Conclusion: "success"}}, time.Now())
	if !byJob.passed() {
		t.Error("a pipeline with its own image job reads as not built")
	}

	byStep := verdict(green, []job{{Name: "cicd", Conclusion: "success",
		Steps: steps(imageStep+" (per hanzo.yml)", "success")}}, time.Now())
	if !byStep.passed() {
		t.Error("the reusable's own build step reads as not built")
	}

	// Skipped is a real answer: the run finished without producing the artifact.
	skipped := verdict(green, []job{{Name: "cicd", Conclusion: "success",
		Steps: steps(imageStep+" (per hanzo.yml)", "skipped")}}, time.Now())
	if skipped.passed() {
		t.Error("a run that skipped its build step reads as built")
	}
}

// TestSilenceAboutAnArtifactIsNotFailure — a run that reports no build step at
// all says nothing about one, so its own conclusion stands. Reading silence as
// failure marks every pipeline shaped unlike the first one as broken, which on
// this fleet is most of them.
func TestSilenceAboutAnArtifactIsNotFailure(t *testing.T) {
	quiet := []job{{Name: "cicd", Conclusion: "success", Steps: steps("Lint", "success")}}
	if got := verdict(Run{ID: 1, Status: "completed", Conclusion: "success"}, quiet, time.Now()); !got.passed() {
		t.Errorf("green run with no build step = %q; want success", got.State)
	}
	red := []job{{Name: "cicd", Conclusion: "failure", Steps: steps("Lint", "failure")}}
	if got := verdict(Run{ID: 1, Status: "completed", Conclusion: "failure"}, red, time.Now()); got.passed() {
		t.Error("a failed run with no build step reads as built")
	}
}

// TestUnreadableValueIsNotDrift keeps a failed read from being drawn as a
// difference. A source that did not answer is not a source that disagrees, and a
// board that conflates them cries wolf during its own outages.
func TestUnreadableValueIsNotDrift(t *testing.T) {
	cases := []struct {
		name              string
		declared, running Version
	}{
		{"nothing read at all", Version{}, Version{}},
		{"cluster unread", Version{Tag: "v1.2.3", Digest: "sha256:aa"}, Version{}},
		{"universe unread", Version{}, Version{Tag: "v1.2.3", Digest: "sha256:aa"}},
	}
	for _, tc := range cases {
		s := Service{Declared: tc.declared, Running: tc.running}
		s.assess()
		if hasDrift(s, unsynced) {
			t.Errorf("%s: drift = %v; an unread value must not read as a difference", tc.name, s.Drift)
		}
	}
}

// TestDigestDecidesOverTag is why both are carried. A tag can be moved onto
// other bytes; a digest cannot, so when both sides publish one it settles the
// question and a matching tag does not paper over different bytes.
func TestDigestDecidesOverTag(t *testing.T) {
	s := Service{
		Declared: Version{Tag: "v1.0.0", Digest: "sha256:aaaa"},
		Running:  Version{Tag: "v1.0.0", Digest: "sha256:bbbb"},
	}
	s.assess()
	if !hasDrift(s, unsynced) {
		t.Error("same tag, different digest — the cluster is running other bytes and it is not reported")
	}
}

// TestUnshippedIsDirectional fixes which way the comparison runs.
//
// A proved image newer than the pin is reported however it came about, including
// while a rollback is in force — "we have built something the fleet is not
// running" is true then, and hiding it would also hide the fix that follows the
// rollback, which is the case that matters most. It is reported as a caution
// rather than an alarm (see tone) so that standing on an older pin deliberately
// does not read like an outage.
//
// The other direction says nothing: a pin naming a release no known build
// produced is a build older than the window this reads, not a missing deploy.
func TestUnshippedIsDirectional(t *testing.T) {
	ahead := Service{Built: Version{Tag: "v1.801.549"}, Declared: Version{Tag: "v1.801.548"}}
	ahead.assess()
	if !hasDrift(ahead, unshipped) {
		t.Errorf("drift = %v; a proved image the pin never named is exactly %s", ahead.Drift, unshipped)
	}
	if tone(ahead) != "warning" {
		t.Errorf("tone = %q; an unshipped build is a caution, not an outage", tone(ahead))
	}

	behind := Service{Built: Version{Tag: "v1.801.357"}, Declared: Version{Tag: "v1.801.548"}}
	behind.assess()
	if hasDrift(behind, unshipped) {
		t.Errorf("drift = %v; a pin ahead of the newest build we can see claims nothing", behind.Drift)
	}
}

// TestUnorderableTagsMakeNoClaim covers the tags that are not versions. A commit
// tag has no order, and inventing one would report drift on every service that
// ships by digest or by date.
func TestUnorderableTagsMakeNoClaim(t *testing.T) {
	for _, tc := range []struct{ built, declared string }{
		{"sha-8d37743", "sha-1a2b3c4"},
		{"v1.2.3", "sha-1a2b3c4"},
		{"latest", "v1.2.3"},
		{"", "v1.2.3"},
	} {
		s := Service{Built: Version{Tag: tc.built}, Declared: Version{Tag: tc.declared}}
		s.assess()
		if hasDrift(s, unshipped) {
			t.Errorf("built=%q declared=%q: drift = %v; neither orders, so nothing may be claimed",
				tc.built, tc.declared, s.Drift)
		}
	}
}

func TestOrderOfVersions(t *testing.T) {
	cases := []struct {
		a, b            string
		want, decidable bool
	}{
		{"v1.801.548", "v1.801.547", true, true},
		{"v1.801.547", "v1.801.548", false, true},
		{"v1.801.548", "v1.801.548", false, true},
		{"v1.802.0", "v1.801.999", true, true},
		{"1.3.4", "v1.3.4", false, true}, // the v is spelling, not version
		{"v2.0", "v1.9.9", true, true},   // shorter is padded, not shorter-is-less
		{"v1.0.1", "v1.0", true, true},
		{"sha-abc", "v1.0.0", false, false},
		{"v1.0.0-rc1", "v1.0.0", false, false},
	}
	for _, tc := range cases {
		got, ok := after(tc.a, tc.b)
		if ok != tc.decidable {
			t.Errorf("after(%q,%q) decidable=%v want %v", tc.a, tc.b, ok, tc.decidable)
		}
		if ok && got != tc.want {
			t.Errorf("after(%q,%q) = %v want %v", tc.a, tc.b, got, tc.want)
		}
	}
}

// TestOneImageIsSeveralServices is the join, and the reason it is not the image.
//
// ghcr.io/hanzoai/static runs as cdn, tabs and zen-landing at three different
// versions at once. Keyed by image these collapse to one row, and that row then
// compares one service's pin against another's running version — drift reported
// where there is none, and real drift hidden behind whichever row won.
func TestOneImageIsSeveralServices(t *testing.T) {
	static := "ghcr.io/hanzoai/static"
	pins := []pin{
		{Name: "cdn", Namespace: "hanzo", Image: static, Version: Version{Tag: "v0.3.0"}},
		{Name: "tabs", Namespace: "hanzo", Image: static, Version: Version{Tag: "v0.5.9"}},
		{Name: "zen-landing", Namespace: "zen", Image: static, Version: Version{Tag: "0.4.1"}},
	}
	lives := []live{
		{Name: "cdn", Namespace: "hanzo", Image: static, Version: Version{Tag: "v0.3.0"}, Ready: 1, Want: 1},
		{Name: "tabs", Namespace: "hanzo", Image: static, Version: Version{Tag: "v0.5.9"}, Ready: 1, Want: 1},
		{Name: "zen-landing", Namespace: "zen", Image: static, Version: Version{Tag: "0.4.1"}, Ready: 1, Want: 1},
	}
	// One repo builds the image all three run, so all three share its chain.
	links := map[string]link{static: {Repo: "hanzoai/static", Org: "hanzoai"}}

	got := assemble(pins, lives, links)
	if len(got) != 3 {
		t.Fatalf("assembled %d rows from three declarations: %+v", len(got), got)
	}
	for _, s := range got {
		if !s.current() {
			t.Errorf("%s/%s: drift = %v; it runs exactly what it declares", s.Namespace, s.Name, s.Drift)
		}
		if s.Repo != "hanzoai/static" {
			t.Errorf("%s: repo = %q; every service of one image shares its chain", s.Name, s.Repo)
		}
	}
}

// TestSidecarOnTheSameImageDoesNotHideThePin — two containers can share the
// repository and hold different versions deliberately, and taking whichever the
// loop reached last reported the pin unapplied on a service whose app container
// was carrying it. studio pins its build-manifest sidecar back to v0.19.26 while
// the app runs v0.19.31; the board called that drift and named a service that was
// in fact current.
func TestSidecarOnTheSameImageDoesNotHideThePin(t *testing.T) {
	studio := "ghcr.io/hanzoai/studio"
	pins := []pin{{Name: "studio", Namespace: "hanzo", Image: studio,
		Version: Version{Tag: "v0.19.31"}}}
	// Sidecar last, so a last-writer-wins read takes the pinned-back one.
	lives := []live{
		{Name: "studio", Namespace: "hanzo", Image: studio, Version: Version{Tag: "v0.19.31"}, Ready: 1, Want: 1},
		{Name: "studio", Namespace: "hanzo", Image: studio, Version: Version{Tag: "v0.19.26"}, Ready: 1, Want: 1},
	}

	got := assemble(pins, lives, map[string]link{})
	if len(got) != 1 {
		t.Fatalf("assembled %d rows from one declaration: %+v", len(got), got)
	}
	if got[0].Running.Tag != "v0.19.31" {
		t.Errorf("running = %q; a workload runs the declared version if any container does",
			got[0].Running.Tag)
	}
	if !got[0].current() {
		t.Errorf("drift = %v; the pin was applied and the app container carries it", got[0].Drift)
	}
}

// TestRunningMatchesOnNameAndImage — a workload of the right name still has to be
// running the image the service declares, so a sidecar is never read as the
// service.
func TestRunningMatchesOnNameAndImage(t *testing.T) {
	pins := []pin{{Name: "cloud", Namespace: "hanzo", Image: "ghcr.io/hanzoai/cloud",
		Version: Version{Tag: "v1.801.548", Digest: "sha256:8830"}}}
	lives := []live{
		{Name: "cloud", Namespace: "hanzo", Image: "docker.io/library/redis", Version: Version{Tag: "7"}},
		{Name: "cloud", Namespace: "hanzo", Image: "ghcr.io/hanzoai/cloud",
			Version: Version{Tag: "v1.801.548", Digest: "sha256:8830"}, Ready: 1, Want: 1},
	}
	got := assemble(pins, lives, map[string]link{})
	if len(got) != 1 {
		t.Fatalf("assembled %d rows: %+v", len(got), got)
	}
	if got[0].Running.Digest != "sha256:8830" || got[0].Ready != 1 {
		t.Errorf("running = %+v ready=%d; the sidecar was read as the service", got[0].Running, got[0].Ready)
	}
	if !got[0].current() {
		t.Errorf("drift = %v; every value agrees", got[0].Drift)
	}
}

// TestDriftingSortsFirstAndOldestOnTop — the page is read to find what needs
// doing, so the break that has stood longest is the one at the top.
func TestDriftingSortsFirstAndOldestOnTop(t *testing.T) {
	old, recent := time.Now().Add(-9*time.Hour), time.Now().Add(-20*time.Minute)
	pins := []pin{
		{Name: "calm", Namespace: "hanzo", Image: "a", Version: Version{Tag: "v1"}},
		{Name: "recent", Namespace: "hanzo", Image: "b", Version: Version{Tag: "v1"}},
		{Name: "old", Namespace: "hanzo", Image: "c", Version: Version{Tag: "v1"}},
	}
	links := map[string]link{
		"a": {Repo: "o/calm"},
		"b": {Repo: "o/recent", Behind: 1, Since: recent},
		"c": {Repo: "o/old", Behind: 4, Since: old},
	}
	got := assemble(pins, nil, links)
	order := []string{got[0].Name, got[1].Name, got[2].Name}
	want := []string{"old", "recent", "calm"}
	for i := range want {
		if order[i] != want[i] {
			t.Fatalf("order = %v; want %v", order, want)
		}
	}
}

// TestUntaggedBuildIsStillABuild — whether a commit built and what to call what
// it built are two questions. A pipeline that builds without claiming a tag
// leaves the version unnamed; reading that as "nothing has built" would report
// every such repo as behind by its whole history.
func TestUntaggedBuildIsStillABuild(t *testing.T) {
	s := Service{Repo: "hanzoai/ci", Behind: 0, Built: Version{}, Declared: Version{Tag: "v0.2.0"}}
	s.assess()
	if hasDrift(s, unbuilt) {
		t.Errorf("drift = %v; head built, it merely carries no tag", s.Drift)
	}
	if hasDrift(s, unshipped) {
		t.Errorf("drift = %v; an unnamed build cannot be ordered against the pin", s.Drift)
	}
}

// TestBuildInFlightIsNotDrift — a push whose build is still going has not failed
// to produce an image, it has not finished producing one. Counting it would put
// every service on the board for the length of its own build, which is how a
// board becomes something people scroll past.
//
// Behind counts only commits whose build has STOPPED without producing an
// artifact, so this is enforced where that count is made rather than by a clock
// here.
func TestBuildInFlightIsNotDrift(t *testing.T) {
	inFlight := Service{Repo: "hanzoai/ui", Behind: 0,
		Head: Head{Build: Build{State: "running"}}}
	inFlight.assess()
	if !inFlight.current() {
		t.Errorf("drift = %v; a build still running is not a service that failed to ship", inFlight.Drift)
	}

	stopped := Service{Repo: "hanzoai/pay", Behind: 1, Since: time.Now().Add(-2 * time.Hour),
		Head: Head{Build: Build{State: "failure", Job: "cicd"}}}
	stopped.assess()
	if !hasDrift(stopped, unbuilt) {
		t.Errorf("drift = %v; a build that stopped without an artifact is %s", stopped.Drift, unbuilt)
	}
}

func hasDrift(s Service, d string) bool {
	for _, x := range s.Drift {
		if x == d {
			return true
		}
	}
	return false
}
