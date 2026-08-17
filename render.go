package main

import (
	"fmt"
	"html/template"
	"net/http"
	"strings"
	"time"
)

// render.go — the HTML view. Server-rendered on purpose: this page is a table
// of build results, and a client-side app would ship a bundle, a fetch layer
// and a loading state to show the same rows a second later. The dashboard also
// has to be readable when the thing it reports on is broken, which is exactly
// when a build pipeline for its own frontend is the wrong dependency.
//
// That argument is about the BUILD, not about the design. The look is the
// house's and is not restated here: the <style> block is @hanzo/brand's own
// published token sheet plus this page's layout rules, both compiled in — see
// brand.go. Server rendering and one design system are not in tension; only
// server rendering and a JS component library are, and it is the tokens, not
// the components, that this page ever needed.

// renderRuns writes the run page for ONE viewer. Every row it renders has
// already passed v.visible — the template is never handed the full snapshot and
// asked to be careful with it, because a template that can see everything is one
// edit away from showing it.
func renderRuns(w http.ResponseWriter, snap snapshot, v viewer, org string, cfg config) {
	runs := v.visible(snap.Runs, org)
	if len(runs) > 200 {
		runs = runs[:200]
	}

	data := struct {
		Runs      []Run
		Orgs      []string
		Org       string
		Viewer    string
		Sudo      bool
		Repos     int
		FetchedAt time.Time
		Age       string
		Stale     bool
		SourceErr string
		Source    string
		Counts    map[string]int
	}{
		Runs:      runs,
		Orgs:      v.orgs(snap.Runs),
		Org:       org,
		Viewer:    v.org,
		Sudo:      v.sudo,
		Repos:     snap.Repos,
		FetchedAt: snap.FetchedAt,
		Age:       humanAge(snap.FetchedAt),
		Stale:     snap.stale(cfg.staleAfter),
		SourceErr: snap.errString(),
		Source:    cfg.gitBase,
		Counts:    countByOutcome(runs),
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := tmpl.Execute(w, data); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

// countByOutcome buckets runs for the summary strip.
func countByOutcome(runs []Run) map[string]int {
	c := map[string]int{"success": 0, "failure": 0, "running": 0, "cancelled": 0}
	for _, r := range runs {
		c[outcome(r)]++
	}
	return c
}

// outcome collapses (status, conclusion) into the four states worth a colour.
//
// Status alone is NOT enough and getting this wrong is silent: Hanzo Git
// reports every finished run as `completed` regardless of how it went, so
// bucketing on status painted successes and cancellations as failures — on the
// live instance that was 15 of 20 runs mislabelled red.
//
// `cancelled` gets its own bucket rather than folding into failure. On this
// fleet cancellations are the single largest category (superseded pushes cancel
// the in-flight run), and a board that shows them as broken is a board nobody
// trusts, which is worse than no board.
func outcome(r Run) string {
	if !strings.EqualFold(r.Status, "completed") {
		return "running" // queued | in_progress | waiting | blocked
	}
	switch strings.ToLower(r.Conclusion) {
	case "success":
		return "success"
	case "cancelled", "canceled", "skipped":
		return "cancelled"
	case "":
		// Completed with no conclusion should not happen; if it does, say
		// "running" rather than inventing a verdict the data does not support.
		return "running"
	default:
		return "failure" // failure | timed_out | action_required
	}
}

func humanAge(t time.Time) string {
	if t.IsZero() {
		return "never"
	}
	d := time.Since(t)
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%ds ago", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	default:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	}
}

func humanDur(d time.Duration) string {
	if d <= 0 {
		return "—"
	}
	if d < time.Minute {
		return fmt.Sprintf("%ds", int(d.Seconds()))
	}
	return fmt.Sprintf("%dm%02ds", int(d.Minutes()), int(d.Seconds())%60)
}

// `class="dark"` is @hanzo/brand's own dark hook, not a local convention: the
// sheet's :root IS the dark scale, and the class is what additionally sets
// color-scheme so the scrollbars and form controls the browser draws match.
// Elsewhere in the fleet next-themes toggles that class; this page has no JS and
// no toggle, so it states its scheme once and means it.
var tmpl = template.Must(template.New("ci").Funcs(template.FuncMap{
	"outcome": outcome,
	"dur":     func(r Run) string { return humanDur(r.Duration()) },
	"ago":     humanAge,
	"css":     pageCSS,
}).Parse(`<!doctype html>
<html lang="en" class="dark"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Hanzo CI</title>
<meta http-equiv="refresh" content="60">
<style>{{css}}</style></head><body>

<header>
  <h1>Hanzo <span>CI</span></h1>
  <div class="meta">
    {{.Repos}} repos &middot; refreshed {{.Age}}<br>
    source {{.Source}}
  </div>
</header>

<div class="strip">
  <span class="chip ok">passing <b>{{index .Counts "success"}}</b></span>
  <span class="chip fail">failing <b>{{index .Counts "failure"}}</b></span>
  <span class="chip run">running <b>{{index .Counts "running"}}</b></span>
  <span class="chip cancel">cancelled <b>{{index .Counts "cancelled"}}</b></span>
</div>

<nav>
  {{if .Sudo}}<a href="/" {{if eq .Org ""}}class="on"{{end}}>all orgs</a>{{end}}
  {{range .Orgs}}<a href="/?org={{.}}" {{if eq $.Org .}}class="on"{{end}}>{{.}}</a>{{end}}
  <span class="who">signed in as {{.Viewer}}{{if .Sudo}} &middot; fleet view{{end}}</span>
</nav>

{{if .Stale}}<div class="warn">
  Snapshot is stale — last successful refresh {{.Age}}.
  {{if .SourceErr}}Hanzo Git said: {{.SourceErr}}{{else}}Hanzo Git is not answering.{{end}}
  These rows are the last good read, not current state.
</div>{{end}}

{{if .Runs}}
<table>
<thead><tr>
  <th>Repository</th><th>Workflow</th><th class="hide-sm">Commit</th>
  <th class="hide-sm">Actor</th><th>Started</th><th>Took</th>
</tr></thead>
<tbody>
{{range .Runs}}
<tr>
  <td><span class="dot {{outcome .}}"></span><a href="{{.URL}}"><span class="org">{{.Org}}/</span><span class="repo">{{.Repo}}</span></a></td>
  <td>{{.Workflow}} <span class="mono">#{{.Number}}</span><div class="title">{{.Title}}</div></td>
  <td class="hide-sm mono">{{.Branch}}@{{.SHA}}<div>{{.Event}}</div></td>
  <td class="hide-sm mono">{{.Actor}}</td>
  <td class="mono">{{ago .StartedAt}}</td>
  <td class="mono">{{dur .}}</td>
</tr>
{{end}}
</tbody></table>
{{else}}
<div class="empty">
  No runs in the scanned window.<br>
  <span class="mono">Builds land here from {{.Source}} — this view holds no state of its own.</span>
</div>
{{end}}

<footer>
  Build truth lives in Hanzo Git; this is a view over it.
  Delivery is <a href="https://cd.hanzo.ai">cd.hanzo.ai</a>.
</footer>
</body></html>`))
