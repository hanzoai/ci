package main

import (
	"fmt"
	"html/template"
	"net/http"
	"strings"
	"time"
)

// board.go draws the fleet page — the four values per service, and which arrow
// between them did not happen.
//
// It renders the same way the run page does and for the same reason: this is the
// page you open when the build system is broken, which is the worst moment for
// it to need the build system to draw itself.

// renderFleet writes the page for ONE viewer. Rows pass v.services first, so the
// template only ever holds what this viewer may see.
func renderFleet(w http.ResponseWriter, snap fleet, v viewer, org string, cfg config) {
	services := v.services(snap.Services, org)

	data := struct {
		Services  []Service
		Orgs      []string
		Org       string
		Viewer    string
		Sudo      bool
		Age       string
		Stale     bool
		SourceErr string
		Source    string
		Universe  string
		Counts    map[string]int
	}{
		Services:  services,
		Orgs:      orgsOfServices(services),
		Org:       org,
		Viewer:    v.org,
		Sudo:      v.sudo,
		Age:       humanAge(snap.FetchedAt),
		Stale:     snap.stale(4 * cfg.fleetRefresh),
		SourceErr: snap.errString(),
		Source:    cfg.gitBase,
		Universe:  cfg.universe,
		Counts:    countByDrift(services),
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := fleetTmpl.Execute(w, data); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

func countByDrift(services []Service) map[string]int {
	c := map[string]int{unbuilt: 0, unshipped: 0, unsynced: 0, untested: 0, "current": 0}
	for _, s := range services {
		if s.current() {
			c["current"]++
		}
		for _, d := range s.Drift {
			c[d]++
		}
	}
	return c
}

// tone maps a service to the one colour its row carries. Anything that stops
// what we wrote from running reads the same, because from outside they are the
// same fact: this service is not serving the code we last merged.
func tone(s Service) string {
	for _, d := range s.Drift {
		if d == unbuilt || d == unsynced {
			return "failure"
		}
	}
	if len(s.Drift) > 0 {
		return "warning"
	}
	return "success"
}

// since renders how long a drift has stood. It is the number worth acting on:
// minutes is a release in flight, hours is a release that never happened.
func since(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	d := time.Since(t)
	switch {
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 48*time.Hour:
		return fmt.Sprintf("%dh", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd", int(d.Hours())/24)
	}
}

// short names a version for the table without hiding which release it is.
//
// A version tag is a few characters; a commit tag is forty, and one of those in
// a column is enough to push every other column off the page. Both are cut to
// the width at which a release is still identifiable.
func short(v Version) string {
	if v.Tag != "" {
		return clip(v.Tag, 16)
	}
	if v.Digest != "" {
		return "@" + clip(strings.TrimPrefix(v.Digest, "sha256:"), 12)
	}
	return "—"
}

func clip(s string, n int) string {
	if len(s) > n {
		return s[:n] + "…"
	}
	return s
}

// explain states a drift in the words of the thing that did not happen.
func explain(d string) string {
	switch d {
	case unbuilt:
		return "head produced no image"
	case unshipped:
		return "built, never pinned"
	case unsynced:
		return "pin not applied"
	case untested:
		return "passed without running tests"
	}
	return d
}

var fleetTmpl = template.Must(template.New("fleet").Funcs(template.FuncMap{
	"css":     pageCSS,
	"ago":     humanAge,
	"since":   since,
	"short":   short,
	"tone":    tone,
	"explain": explain,
	"sha":     shortSHA,
	"has": func(s Service, d string) bool {
		for _, x := range s.Drift {
			if x == d {
				return true
			}
		}
		return false
	},
}).Parse(`<!doctype html>
<html lang="en" class="dark"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Hanzo CI — fleet</title>
<meta http-equiv="refresh" content="60">
<style>{{css}}</style></head><body>

<header>
  <h1>Hanzo <span>CI</span></h1>
  <div class="meta">
    {{len .Services}} services &middot; read {{.Age}}<br>
    {{.Source}} &middot; {{.Universe}}
  </div>
</header>

<div class="strip">
  <span class="chip ok">current <b>{{index .Counts "current"}}</b></span>
  <span class="chip fail">unbuilt <b>{{index .Counts "unbuilt"}}</b></span>
  <span class="chip fail">unsynced <b>{{index .Counts "unsynced"}}</b></span>
  <span class="chip run">unshipped <b>{{index .Counts "unshipped"}}</b></span>
  <span class="chip run">untested <b>{{index .Counts "untested"}}</b></span>
</div>

<nav>
  <a href="/" class="on">fleet</a>
  <a href="/runs">runs</a>
  {{if .Sudo}}<a href="/" {{if eq .Org ""}}class="on"{{end}}>all orgs</a>{{end}}
  {{range .Orgs}}<a href="/?org={{.}}" {{if eq $.Org .}}class="on"{{end}}>{{.}}</a>{{end}}
  <span class="who">signed in as {{.Viewer}}{{if .Sudo}} &middot; fleet view{{end}}</span>
</nav>

{{if .Stale}}<div class="warn">
  Snapshot is stale — last successful read {{.Age}}.
  {{if .SourceErr}}Reading failed: {{.SourceErr}}{{else}}A source is not answering.{{end}}
  These rows are the last good read, not current state.
</div>{{end}}

{{if .Services}}
<table>
<thead><tr>
  <th>Service</th>
  <th>State</th>
  <th class="hide-sm">Wrote</th>
  <th>Built</th>
  <th>Declared</th>
  <th>Running</th>
</tr></thead>
<tbody>
{{range .Services}}
<tr>
  <td>
    <span class="dot {{tone .}}"></span><span class="repo">{{.Name}}</span>
    <div class="title">{{.Namespace}}{{if .Repo}} &middot; {{.Repo}}{{else}} &middot; no repo builds this image{{end}}</div>
  </td>

  <td>
    {{if .Drift}}{{range .Drift}}<span class="tag {{.}}">{{explain .}}</span>{{end}}
    {{else}}<span class="ok">current</span>{{end}}
    {{if has . "unbuilt"}}<div class="note">{{.Behind}} commit{{if ne .Behind 1}}s{{end}} behind{{if since .Since}} &middot; {{since .Since}}{{end}}</div>{{end}}
  </td>

  <td class="hide-sm mono">
    {{if .Head.SHA}}
      <span class="dot {{.Head.Build.State}}"></span>{{if .Head.Build.URL}}<a href="{{.Head.Build.URL}}">{{sha .Head.SHA}}</a>{{else}}{{sha .Head.SHA}}{{end}}
      {{if .Head.Build.Job}}<span class="job">{{.Head.Build.Job}}</span>{{end}}
      {{if eq .Head.Build.State "absent"}}<span class="job">no run</span>{{end}}
      <div class="title">{{.Head.Title}}</div>
    {{else}}—{{end}}
  </td>

  <td class="mono {{if has . "unshipped"}}gap{{end}}">{{short .Built}}</td>

  <td class="mono {{if has . "unsynced"}}gap{{end}}">{{short .Declared}}
    {{if .PinnedAt}}<div class="note">pinned {{since .PinnedAt}} ago</div>{{end}}
  </td>

  <td class="mono {{if has . "unsynced"}}gap{{end}}">{{short .Running}}
    {{if .Want}}<div class="note">{{.Ready}}/{{.Want}} ready</div>{{end}}
  </td>
</tr>
{{end}}
</tbody></table>
{{else}}
<div class="empty">
  No services visible.<br>
  <span class="mono">Services are the images {{.Universe}} declares — this view holds no state of its own.</span>
</div>
{{end}}

<footer>
  What we wrote is the tip of each repo on {{.Source}}; what runs is read from the cluster.
  Drive a sync at <a href="https://cd.hanzo.ai">cd.hanzo.ai</a>.
</footer>
</body></html>`))
