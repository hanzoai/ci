package main

import "strings"

// declared.go reads the image out of one values file.
//
// It reads exactly one block and understands exactly three keys:
//
//	image:
//	  repository: ghcr.io/hanzoai/cloud
//	  tag: v1.801.548
//	  digest: sha256:8830c2b1…
//
// A YAML library would parse the whole document to reach those three scalars,
// and this repo has no dependencies at all — the reason being that the thing
// which tells you the fleet is broken should not itself be able to break on a
// transitive upgrade. Reading the one block it needs keeps that property.
//
// It is strict rather than clever. Anything that is not this exact shape yields
// no image, so a values file the reader does not understand shows as unknown on
// the page. Guessing would be worse than blank: a dashboard whose whole job is
// saying what is declared must never infer it.

// declared returns the image repository and the version pinned to it.
func declared(body string) (string, Version) {
	var (
		v      Version
		image  string
		inside bool
	)
	for _, raw := range strings.Split(body, "\n") {
		line := strings.TrimRight(raw, "\r")
		if trimmed := strings.TrimSpace(line); trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		if !inside {
			// Only a top-level `image:` opens the block. The same key nested
			// under another — a sidecar's, an init container's — is a different
			// image and is not what the chart deploys.
			if line == "image:" {
				inside = true
			}
			continue
		}
		if !strings.HasPrefix(line, "  ") {
			break // dedented: the block is over
		}
		key, value, ok := strings.Cut(strings.TrimSpace(line), ":")
		if !ok {
			continue
		}
		switch key {
		case "repository":
			image = scalar(value)
		case "tag":
			v.Tag = scalar(value)
		case "digest":
			// A digest is `sha256:…`, so the cut above split the value itself.
			v.Digest = scalar(strings.TrimPrefix(strings.TrimSpace(line), "digest:"))
		}
	}
	if image == "" {
		return "", Version{}
	}
	return image, v
}

// scalar trims a value of its quotes and of any comment following it. Neither an
// image name nor a tag nor a digest can contain a space, so the first one begins
// something that is not the value.
func scalar(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexAny(s, " \t"); i >= 0 {
		s = s[:i]
	}
	return strings.Trim(s, `"'`)
}
