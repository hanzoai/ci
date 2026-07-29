package main

import (
	_ "embed"
	"html/template"
)

// brand.go — where this page's design values come from.
//
// They come from @hanzo/brand, the one place the fleet's palette, radii, type
// scale and spacing are defined, and they arrive as that package's OWN
// published artifact rather than as hex codes retyped here. The distinction is
// the entire point. Until this file existed the template carried its own
// :root block, and being a hand-copy it had already drifted off the house:
// the status colours were GitHub Primer's (#3fb950 / #f85149 / #d29922) where
// the house says #10b981 / #ef4444 / #f59e0b, the surface blacks were each a
// shade wrong (#0b0b0d against --surface-0 #080808), and the hairline border
// was a solid #25252b where the house hairline is a 6%-white wash. Only the
// accent survived intact. A palette that is copied is a palette that diverges.
//
// Vendored, not fetched at build time, and compiled in rather than served off
// disk. @hanzo/brand publishes this file as a plain custom-property sheet
// (`exports["./styles/*"]`, documented for a bare <link>), so consuming it
// costs no npm, no bundler and no React — the image build stays `go build`
// against an empty go.mod, and the page stays one request that returns the
// answer. That matters here more than anywhere: this dashboard is read when
// the build system is broken, which is the worst possible moment for it to
// need the build system in order to draw itself.
//
// Refreshing is a deliberate, reviewed act — fetch, then update the pin:
//
//	curl -sSfo brand/variables.css https://unpkg.com/@hanzo/brand@<version>/styles/variables.css
//
//go:embed brand/variables.css
var brandCSS string

// brandCSSVersion and brandCSSSHA256 record WHICH @hanzo/brand the bytes above
// are, and a test rejects any other bytes. This is go.sum's argument, not
// ceremony: without it, "just darken that one border" is a one-character local
// edit that silently restores the second source of truth this file removed, and
// nothing would ever catch it.
const (
	brandCSSVersion = "1.4.5"
	brandCSSSHA256  = "941dfc0080343d25dc1ef2cd780290a2d8fe6cbd81136912281902f2e8e7741f"
)

// dashboardCSS is what this page adds on top: layout, not design. Every colour,
// radius and size in it is a var() into the sheet above.
//
//go:embed dashboard.css
var dashboardCSS string

// pageCSS is the <style> body: tokens first, then the rules that spend them.
// template.CSS because these are two compile-time constants, never input.
func pageCSS() template.CSS { return template.CSS(brandCSS + dashboardCSS) }
