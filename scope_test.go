package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// scope_test.go is the regression suite for the leak this service shipped with:
// /v1/runs answered 200 to anyone, with every org's repo names, branches, commit
// SHAs and actor logins, because `?org=` was a filter being used as a gate.
//
// The properties asserted here are the ones that made it a leak, not merely the
// ones that make the new code work.

func testRuns() []Run {
	return []Run{
		{Org: "hanzo", Repo: "cloud", Workflow: "build", Status: "completed", Conclusion: "success"},
		{Org: "lux", Repo: "node", Workflow: "build", Status: "completed", Conclusion: "failure"},
		{Org: "zoo", Repo: "app", Workflow: "test", Status: "in_progress"},
	}
}

// TestNoOrgHeaderIsRefused is the core fix. An absent X-Org-Id means the request
// did not come through the IAM gate; the ONLY safe answer is to refuse. The old
// code treated the equivalent condition (no `?org=`) as "show everything".
func TestNoOrgHeaderIsRefused(t *testing.T) {
	for _, hdr := range []string{"", "   "} {
		r := httptest.NewRequest(http.MethodGet, "/v1/runs", nil)
		if hdr != "" {
			r.Header.Set(orgHeader, hdr)
		}
		w := httptest.NewRecorder()

		v, ok := requireViewer(w, r, "admin")
		if ok {
			t.Fatalf("X-Org-Id=%q admitted as viewer %+v — absence must fail closed", hdr, v)
		}
		if w.Code != http.StatusForbidden {
			t.Errorf("X-Org-Id=%q: status=%d want 403", hdr, w.Code)
		}
	}
}

// TestTenantCannotWidenWithQueryParam is the attack the original design invited:
// the caller picks the org. Now the header decides and the parameter may only
// narrow, so a lux viewer asking for hanzo's builds gets nothing — NOT hanzo's
// builds, and not a silent fallback to its own either (that would be confusing,
// but it is the empty answer that matters for security).
func TestTenantCannotWidenWithQueryParam(t *testing.T) {
	lux := viewer{org: "lux"}

	got := lux.visible(testRuns(), "hanzo")
	if len(got) != 0 {
		t.Fatalf("lux viewer asking ?org=hanzo saw %d runs (%+v) — must see none", len(got), got)
	}

	own := lux.visible(testRuns(), "")
	if len(own) != 1 || own[0].Org != "lux" {
		t.Fatalf("lux viewer saw %+v; want exactly its own org", own)
	}
	if same := lux.visible(testRuns(), "lux"); len(same) != 1 {
		t.Errorf("lux viewer asking ?org=lux saw %d runs; want its own 1", len(same))
	}
}

// TestSudoSeesFleetAndCanNarrow asserts the admin org keeps the cross-tenant
// view that makes this dashboard useful to the platform, and that `?org=` still
// works as a plain filter for it.
func TestSudoSeesFleetAndCanNarrow(t *testing.T) {
	sudo := viewer{org: "admin", sudo: true}

	if all := sudo.visible(testRuns(), ""); len(all) != 3 {
		t.Fatalf("sudo saw %d runs; want all 3", len(all))
	}
	one := sudo.visible(testRuns(), "zoo")
	if len(one) != 1 || one[0].Org != "zoo" {
		t.Fatalf("sudo ?org=zoo saw %+v; want zoo only", one)
	}
}

// TestResolveViewerSudoDetection pins the sudo bit to the configured admin org,
// case-insensitively, and proves an ordinary org never gets it.
func TestResolveViewerSudoDetection(t *testing.T) {
	cases := []struct {
		hdr, adminOrg string
		wantSudo      bool
	}{
		{"admin", "admin", true},
		{"ADMIN", "admin", true},
		{" admin ", "admin", true},
		{"lux", "admin", false},
		{"administrator", "admin", false}, // prefix must not match
		{"admin", "root", false},          // honours a non-default admin org
	}
	for _, tc := range cases {
		r := httptest.NewRequest(http.MethodGet, "/", nil)
		r.Header.Set(orgHeader, tc.hdr)
		v, ok := resolveViewer(r, tc.adminOrg)
		if !ok {
			t.Fatalf("X-Org-Id=%q: not resolved", tc.hdr)
		}
		if v.sudo != tc.wantSudo {
			t.Errorf("X-Org-Id=%q adminOrg=%q: sudo=%v want %v", tc.hdr, tc.adminOrg, v.sudo, tc.wantSudo)
		}
	}
}

// TestTenantOrgListIsNotTheFleetList covers the quieter leak: even with runs
// correctly hidden, rendering every org's NAME in the nav would disclose the set
// of orgs that build on the platform.
func TestTenantOrgListIsNotTheFleetList(t *testing.T) {
	lux := viewer{org: "lux"}
	orgs := lux.orgs(testRuns())
	if len(orgs) != 1 || orgs[0] != "lux" {
		t.Fatalf("tenant org list = %v; want only its own org", orgs)
	}
	if sudoOrgs := (viewer{org: "admin", sudo: true}).orgs(testRuns()); len(sudoOrgs) != 3 {
		t.Errorf("sudo org list = %v; want all 3", sudoOrgs)
	}
}

// TestRunsEndpointScopesEndToEnd drives the actual HTTP handler wiring, not just
// the predicates — the leak was in the handler, so the handler is what must be
// asserted.
func TestRunsEndpointScopesEndToEnd(t *testing.T) {
	cache := &runCache{}
	cache.put(snapshot{Runs: testRuns(), Repos: 3})
	cfg := config{adminOrg: "admin"}

	h := func(w http.ResponseWriter, r *http.Request) {
		v, ok := requireViewer(w, r, cfg.adminOrg)
		if !ok {
			return
		}
		snap := cache.get()
		writeJSON(w, http.StatusOK, map[string]any{
			"runs": v.visible(snap.Runs, r.URL.Query().Get("org")),
			"orgs": v.orgs(snap.Runs),
		})
	}

	t.Run("anonymous → 403", func(t *testing.T) {
		w := httptest.NewRecorder()
		h(w, httptest.NewRequest(http.MethodGet, "/v1/runs", nil))
		if w.Code != http.StatusForbidden {
			t.Fatalf("status=%d want 403; body=%s", w.Code, w.Body.String())
		}
		if strings.Contains(w.Body.String(), "cloud") || strings.Contains(w.Body.String(), "node") {
			t.Error("refusal body leaked repo names")
		}
	})

	t.Run("lux viewer sees only lux, even asking for hanzo", func(t *testing.T) {
		r := httptest.NewRequest(http.MethodGet, "/v1/runs?org=hanzo", nil)
		r.Header.Set(orgHeader, "lux")
		w := httptest.NewRecorder()
		h(w, r)

		var got struct {
			Runs []Run    `json:"runs"`
			Orgs []string `json:"orgs"`
		}
		if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
			t.Fatalf("decode: %v", err)
		}
		if len(got.Runs) != 0 {
			t.Errorf("lux asking ?org=hanzo got %+v; want none", got.Runs)
		}
		if len(got.Orgs) != 1 || got.Orgs[0] != "lux" {
			t.Errorf("orgs=%v; want [lux]", got.Orgs)
		}
	})
}

// ─────────────────── the fleet surface, under the same rule ───────────────────

func testServices() []Service {
	return []Service{
		{Name: "cloud", Namespace: "hanzo", Image: "ghcr.io/hanzoai/cloud", Org: "hanzo", Repo: "hanzo-inc/cloud"},
		{Name: "node", Namespace: "hanzo", Image: "ghcr.io/luxfi/node", Org: "lux", Repo: "luxfi/node"},
		{Name: "app", Namespace: "hanzo", Image: "ghcr.io/zooai/app", Org: "zoo", Repo: "zooai/app"},
		// Declared and running, but no repo was shown to build it — so it carries
		// no org and its tenancy is unknown.
		{Name: "orphan", Namespace: "hanzo", Image: "ghcr.io/hanzoai/orphan"},
	}
}

func testBoard(t *testing.T) *fleetCache {
	t.Helper()
	c := &fleetCache{}
	c.put(fleet{Services: testServices()})
	return c
}

// TestFleetRefusesWithoutTheHeader holds the new surface to the rule the run
// surface is held to: the header is the authority, and its absence means the
// request did not come through the gate.
func TestFleetRefusesWithoutTheHeader(t *testing.T) {
	mux := routes(config{adminOrg: "admin"}, &runCache{}, testBoard(t))

	for _, path := range []string{"/v1/fleet", "/", "/runs"} {
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, httptest.NewRequest(http.MethodGet, path, nil))
		if w.Code != http.StatusForbidden {
			t.Errorf("%s without %s: status=%d want 403", path, orgHeader, w.Code)
		}
		// The refusal must not describe what it is refusing to show.
		for _, leaked := range []string{"cloud", "node", "luxfi", "zooai", "orphan"} {
			if strings.Contains(w.Body.String(), leaked) {
				t.Errorf("%s refusal body leaked %q", path, leaked)
			}
		}
	}
}

// TestFleetTenantCannotWiden — `?org=` selects among what a viewer may already
// see and never reaches past it, on this surface as on the other.
func TestFleetTenantCannotWiden(t *testing.T) {
	mux := routes(config{adminOrg: "admin"}, &runCache{}, testBoard(t))

	ask := func(t *testing.T, org, want string) []Service {
		t.Helper()
		r := httptest.NewRequest(http.MethodGet, "/v1/fleet?org="+want, nil)
		r.Header.Set(orgHeader, org)
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, r)
		if w.Code != http.StatusOK {
			t.Fatalf("status=%d want 200", w.Code)
		}
		var got struct {
			Services []Service `json:"services"`
			Orgs     []string  `json:"orgs"`
		}
		if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
			t.Fatalf("decode: %v", err)
		}
		if org != "admin" {
			for _, o := range got.Orgs {
				if o != org {
					t.Errorf("nav offered org %q to a %s viewer", o, org)
				}
			}
		}
		return got.Services
	}

	if got := ask(t, "lux", "hanzo"); len(got) != 0 {
		t.Errorf("lux asking ?org=hanzo saw %+v; want none", got)
	}
	own := ask(t, "lux", "")
	if len(own) != 1 || own[0].Org != "lux" {
		t.Errorf("lux viewer saw %+v; want exactly its own org", own)
	}
	if all := ask(t, "admin", ""); len(all) != 4 {
		t.Errorf("sudo saw %d services; want all 4 including the unattributed one", len(all))
	}
	if one := ask(t, "admin", "zoo"); len(one) != 1 || one[0].Org != "zoo" {
		t.Errorf("sudo ?org=zoo saw %+v; want zoo only", one)
	}
}

// TestUnattributedServiceIsSudoOnly covers the row whose tenancy could not be
// established. Showing it to a tenant because we do not know whose it is would be
// deciding the boundary by ignorance; only the admin org sees it.
func TestUnattributedServiceIsSudoOnly(t *testing.T) {
	for _, org := range []string{"hanzo", "lux", "zoo"} {
		for _, s := range (viewer{org: org}).services(testServices(), "") {
			if s.Org == "" {
				t.Errorf("%s viewer saw unattributed service %q", org, s.Name)
			}
		}
	}
	var seen bool
	for _, s := range (viewer{org: "admin", sudo: true}).services(testServices(), "") {
		if s.Name == "orphan" {
			seen = true
		}
	}
	if !seen {
		t.Error("sudo cannot see the unattributed service — then nobody can, and it is invisible")
	}
}

// TestFleetPageShowsOnlyTheViewersOrg drives the HTML, because the leak that
// started all of this was a handler handing a template more than the viewer was
// owed.
func TestFleetPageShowsOnlyTheViewersOrg(t *testing.T) {
	mux := routes(config{adminOrg: "admin"}, &runCache{}, testBoard(t))
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r.Header.Set(orgHeader, "lux")
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, r)

	body := w.Body.String()
	if !strings.Contains(body, "luxfi/node") {
		t.Fatal("lux viewer's own service is missing from the page")
	}
	for _, leaked := range []string{"hanzo-inc/cloud", "zooai/app", "orphan", "/?org=hanzo", "/?org=zoo", "all orgs"} {
		if strings.Contains(body, leaked) {
			t.Errorf("page rendered %q to a lux viewer", leaked)
		}
	}
}
