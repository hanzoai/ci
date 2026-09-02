package ci

import (
	"net/http"
	"strings"

	"github.com/hanzoai/authz"
)

// scope.go answers exactly one question: whose builds may THIS request see?
//
// It exists to keep a FILTER and a GATE apart. `?org=lux` narrows what is
// rendered and reads like tenancy, but it decides nothing about who may ask: a
// query parameter is a request for a view, never the authority for one. Conflate
// the two and every org's repo names, branches, commit SHAs and actor logins are
// one URL away from an unauthenticated caller.
//
// The authority is X-Org-Id, minted by admin-guard from the IAM-verified `owner`
// claim and written onto the request by the ingress middleware's
// authResponseHeaders. Traefik OVERWRITES any client-sent X-Org-Id with the
// guard's value, so on the wired path the header cannot be forged. This file
// still treats its ABSENCE as fatal rather than as "no filter", because absence
// is the signal that the request did not come through the guard at all.

// orgHeader is the identity the whole surface is scoped by. One name, one
// meaning, platform-wide (see the X-* header convention: X-Org-Id is the org
// slug from the JWT `owner` claim).
const orgHeader = "X-Org-Id"

// viewer is the resolved, trusted answer. Constructed only from headers the
// guard controls — never from the query string, never from a cookie.
type viewer struct {
	// org is the caller's home org slug, from the verified `owner` claim.
	org string
	// sudo reports whether org is the reserved admin org, which is the ONE
	// identity that may see across tenants (the fleet view).
	sudo bool
}

// resolveViewer lifts the guard-set header into a viewer. It fails closed: a
// missing or blank X-Org-Id yields ok=false and the caller MUST refuse the
// request.
//
// Defaulting an absent header to "no filter" is the specific bug this function
// exists to prevent — that default is what turns "reached ci without the guard"
// into "rendered every org's builds".
//
// The reserved org is authz.AdminOrg: IAM seeds platform admins into it and
// signs the claim this header is minted from, so the issuer owns the value and
// every reader spells it the same way. A setting here could only ever make this
// surface disagree with the token it is shown, and both directions of that
// disagreement are silent — an ordinary org handed the fleet view, or a real
// SuperAdmin narrowed to one org.
func resolveViewer(r *http.Request) (viewer, bool) {
	org := strings.TrimSpace(r.Header.Get(orgHeader))
	if org == "" {
		return viewer{}, false
	}
	return viewer{org: org, sudo: strings.EqualFold(org, authz.AdminOrg)}, true
}

// visible narrows runs to what v is permitted to see, then applies want (the
// optional `?org=` selection) WITHIN that permission.
//
// The ordering is the whole point: permission is applied first and `want` can
// only ever narrow the result. A lux viewer asking for `?org=hanzo` gets an
// empty list, not hanzo's builds — the parameter selects among what you may
// already see, it never reaches for more.
func (v viewer) visible(runs []Execution, want string) []Execution {
	want = strings.TrimSpace(want)
	if v.sudo {
		// The fleet view: every org, narrowed by the requested one if given.
		return filterByOrg(runs, want)
	}
	if want != "" && !strings.EqualFold(want, v.org) {
		return nil
	}
	return filterByOrg(runs, v.org)
}

// orgs lists the org tabs this viewer may choose between. A tenant gets exactly
// its own org — rendering the full org list to a tenant would leak the set of
// orgs that build on the platform even though their runs are correctly hidden.
func (v viewer) orgs(runs []Execution) []string {
	if v.sudo {
		return orgsOf(runs)
	}
	return []string{v.org}
}

// requireViewer resolves the viewer or writes the refusal. It returns ok=false
// when the request must not proceed.
func requireViewer(w http.ResponseWriter, r *http.Request) (viewer, bool) {
	v, ok := resolveViewer(r)
	if ok {
		return v, true
	}
	// 403, not 401: a 401 invites a credential retry, but there is nothing the
	// CALLER can add to fix this. The header is set by infrastructure, so its
	// absence is a routing fault (ci reached off-guard) and the honest answer is
	// that this path is not authorized to serve, whoever is asking.
	http.Error(w, "forbidden: no "+orgHeader+" (this service is only reachable through the IAM gate)", http.StatusForbidden)
	return viewer{}, false
}
