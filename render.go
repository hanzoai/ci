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

func renderDashboard(w http.ResponseWriter, snap snapshot, org string, cfg config) {
	runs := filterByOrg(snap.Runs, org)
	if len(runs) > 200 {
		runs = runs[:200]
	}

	data := struct {
		Runs      []Run
		Orgs      []string
		Org       string
		Repos     int
		FetchedAt time.Time
		Age       string
		Stale     bool
		SourceErr string
		Source    string
		Counts    map[string]int
	}{
		Runs:      runs,
		Orgs:      orgsOf(snap.Runs),
		Org:       org,
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

var tmpl = template.Must(template.New("ci").Funcs(template.FuncMap{
	"outcome": outcome,
	"dur":     func(r Run) string { return humanDur(r.Duration()) },
	"ago":     humanAge,
}).Parse(`<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Hanzo CI</title>
<meta http-equiv="refresh" content="60">
<style>
:root{--bg:#0b0b0d;--panel:#141417;--line:#25252b;--fg:#e8e8ea;--dim:#8b8b95;
      --ok:#3fb950;--fail:#f85149;--run:#d29922;--accent:#8B5CF6}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
     font:14px/1.5 ui-sans-serif,-apple-system,"Segoe UI",Roboto,sans-serif}
header{display:flex;align-items:center;gap:16px;padding:16px 24px;
       border-bottom:1px solid var(--line);background:var(--panel)}
h1{margin:0;font-size:16px;font-weight:600;letter-spacing:-.01em}
h1 span{color:var(--accent)}
.meta{margin-left:auto;color:var(--dim);font-size:12px;text-align:right}
.strip{display:flex;gap:8px;padding:16px 24px;flex-wrap:wrap}
.chip{padding:6px 12px;border:1px solid var(--line);border-radius:8px;
      background:var(--panel);font-size:12px;color:var(--dim)}
.chip b{color:var(--fg);font-weight:600}
.chip.ok b{color:var(--ok)} .chip.fail b{color:var(--fail)} .chip.run b{color:var(--run)}
.chip.cancel b{color:var(--dim)}
nav{display:flex;gap:6px;padding:0 24px 16px;flex-wrap:wrap}
nav a{padding:5px 11px;border:1px solid var(--line);border-radius:999px;
      background:var(--panel);color:var(--dim);text-decoration:none;font-size:12px}
nav a.on{border-color:var(--accent);color:var(--fg)}
.warn{margin:0 24px 16px;padding:10px 14px;border:1px solid var(--run);
      border-radius:8px;background:#221b0c;color:#f0d58c;font-size:13px}
table{width:100%;border-collapse:collapse}
th{position:sticky;top:0;background:var(--panel);text-align:left;font-size:11px;
   text-transform:uppercase;letter-spacing:.06em;color:var(--dim);
   padding:10px 12px;border-bottom:1px solid var(--line);font-weight:600}
td{padding:10px 12px;border-bottom:1px solid var(--line);vertical-align:top}
tr:hover td{background:#111114}
a{color:inherit}
.dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:8px}
.dot.success{background:var(--ok)} .dot.failure{background:var(--fail)}
.dot.running{background:var(--run);animation:p 1.4s ease-in-out infinite}
.dot.cancelled{background:#4a4a52}
@keyframes p{50%{opacity:.35}}
.repo{font-weight:600}
.org{color:var(--dim)}
.title{color:var(--dim);max-width:42ch;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px;color:var(--dim)}
.empty{padding:48px 24px;text-align:center;color:var(--dim)}
footer{padding:16px 24px;color:var(--dim);font-size:12px;border-top:1px solid var(--line)}
@media(max-width:760px){.hide-sm{display:none}}
</style></head><body>

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
  <a href="/" {{if eq .Org ""}}class="on"{{end}}>all orgs</a>
  {{range .Orgs}}<a href="/?org={{.}}" {{if eq $.Org .}}class="on"{{end}}>{{.}}</a>{{end}}
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
