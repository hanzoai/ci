package main

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"
)

// render_test.go guards the two properties the view has to keep: that its design
// values come from exactly one place, and that it can only ever draw rows the
// viewer was already permitted to see.

// TestBrandCSSIsUpstreamBytes is the pin. The vendored sheet is only a source of
// truth while it is byte-for-byte what @hanzo/brand published; the moment it can
// be edited in place it is a fork wearing an upstream name, which is the exact
// state this repo was in when it carried its own :root block.
func TestBrandCSSIsUpstreamBytes(t *testing.T) {
	sum := sha256.Sum256([]byte(brandCSS))
	got := hex.EncodeToString(sum[:])
	if got != brandCSSSHA256 {
		t.Fatalf("brand/variables.css is not @hanzo/brand@%s\n got  %s\n want %s\n"+
			"A token refresh: re-fetch the sheet and set brandCSSSHA256 to the got value.\n"+
			"A local colour edit: make it in @hanzo/brand and release it, not here.",
			brandCSSVersion, got, brandCSSSHA256)
	}
}

// colourLiteral matches a value that decides an appearance on its own — a hex,
// or an rgb()/hsl() function. `color-mix(in srgb, var(--x) ...)` is deliberately
// not one of these: it derives from a token instead of naming a new colour.
var colourLiteral = regexp.MustCompile(`#[0-9a-fA-F]{3,8}\b|\brgba?\(|\bhsla?\(`)

// TestDashboardCSSNamesNoColours is what makes "one source of truth" a fact
// rather than an intention. Vendoring the sheet is only half the job; if the
// page can still write a hex next to it, the second palette grows back one
// "just this once" at a time — which is how the old :root block came to hold
// GitHub's status colours instead of the house's.
func TestDashboardCSSNamesNoColours(t *testing.T) {
	if m := colourLiteral.FindAllString(dashboardCSS, -1); len(m) > 0 {
		t.Fatalf("dashboard.css names colours directly: %v\n"+
			"Every colour must be a var() into @hanzo/brand; if the token you need "+
			"does not exist, add it there rather than here.", m)
	}
	if !strings.Contains(dashboardCSS, "var(--") {
		t.Fatal("dashboard.css references no tokens at all — it has stopped consuming the design system")
	}
}

// TestRenderedPageShowsOnlyTheViewersOrg drives the HTML, not the predicates.
// scope_test.go proves visible() and orgs() are right; this proves the page is
// actually built from them — the leak that started all of this was a handler
// handing a template more than the viewer was owed, and a template cannot be
// trusted to be careful with a snapshot it can see all of.
func TestRenderedPageShowsOnlyTheViewersOrg(t *testing.T) {
	w := httptest.NewRecorder()
	renderDashboard(w, snapshot{Runs: testRuns(), Repos: 3}, viewer{org: "lux"}, "", config{})
	body := w.Body.String()

	if !strings.Contains(body, ">lux/<") {
		t.Fatal("lux viewer's own run is missing from the page")
	}
	// Rows: no other org's repo may be drawn.
	for _, leaked := range []string{">hanzo/<", ">zoo/<"} {
		if strings.Contains(body, leaked) {
			t.Errorf("page rendered %s to a lux viewer", leaked)
		}
	}
	// Nav: nor may another org's NAME, which discloses who builds here even
	// when their runs are correctly hidden.
	for _, leaked := range []string{"/?org=hanzo", "/?org=zoo", "all orgs"} {
		if strings.Contains(body, leaked) {
			t.Errorf("nav offered %q to a lux viewer", leaked)
		}
	}
}
