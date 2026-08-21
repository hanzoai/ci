package main

import "testing"

// declared_test.go pins the reader against the shapes the fleet's values files
// actually take. It is weighted toward refusals: a reader that guesses would put
// a wrong version on the one page whose whole job is saying what is declared, and
// a wrong number there is worse than a blank, because a blank is visibly unknown.

func TestDeclaredReadsTheFleetsShapes(t *testing.T) {
	cases := []struct {
		name, body, image string
		want              Version
	}{{
		name: "tag and digest, the shape of almost every service",
		body: "replicas: 1\nimage:\n  repository: ghcr.io/hanzoai/cloud\n" +
			"  tag: v1.801.548\n  digest: sha256:8830c2b1\n  pullPolicy: IfNotPresent\n",
		image: "ghcr.io/hanzoai/cloud",
		want:  Version{Tag: "v1.801.548", Digest: "sha256:8830c2b1"},
	}, {
		// The pin a human reads and the bytes the kubelet pulls are written in
		// one edit, and comments explaining a release sit between them.
		name: "comments inside the block",
		body: "image:\n  repository: ghcr.io/hanzoai/cloud\n" +
			"  # ROLLED BACK — the newer tag served no routes.\n  #\n" +
			"  # Measured from outside the cluster.\n" +
			"  tag: v1.801.357\n  digest: sha256:aabb\n",
		image: "ghcr.io/hanzoai/cloud",
		want:  Version{Tag: "v1.801.357", Digest: "sha256:aabb"},
	}, {
		name:  "pinned by digest alone",
		body:  "image:\n  repository: ghcr.io/hanzoai/iam\n  digest: sha256:ccdd\n  pullPolicy: Always\n",
		image: "ghcr.io/hanzoai/iam",
		want:  Version{Digest: "sha256:ccdd"},
	}, {
		name:  "pinned by tag alone",
		body:  "image:\n  repository: ghcr.io/hanzoai/bot-gateway\n  tag: v0.3.1\n",
		image: "ghcr.io/hanzoai/bot-gateway",
		want:  Version{Tag: "v0.3.1"},
	}, {
		name:  "quoted",
		body:  "image:\n  repository: \"ghcr.io/hanzoai/a\"\n  tag: '0.1.0'\n",
		image: "ghcr.io/hanzoai/a",
		want:  Version{Tag: "0.1.0"},
	}, {
		name:  "a comment after the value is not the value",
		body:  "image:\n  repository: ghcr.io/hanzoai/a  # the published name\n  tag: v1.0.0 # cut by hand\n",
		image: "ghcr.io/hanzoai/a",
		want:  Version{Tag: "v1.0.0"},
	}, {
		name:  "the block ends at the first dedent",
		body:  "image:\n  repository: ghcr.io/hanzoai/a\n  tag: v1.0.0\ningress:\n  tag: not-an-image\n",
		image: "ghcr.io/hanzoai/a",
		want:  Version{Tag: "v1.0.0"},
	}}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			image, got := declared(tc.body)
			if image != tc.image {
				t.Fatalf("image = %q; want %q", image, tc.image)
			}
			if got != tc.want {
				t.Errorf("version = %+v; want %+v", got, tc.want)
			}
		})
	}
}

// TestDeclaredRefusesWhatItDoesNotUnderstand — every one of these must yield no
// image, so the page shows the value as unknown rather than as a number nobody
// wrote.
func TestDeclaredRefusesWhatItDoesNotUnderstand(t *testing.T) {
	cases := []struct{ name, body string }{
		{"no image block at all — a chart of routes or hosts",
			"replicas: 1\ningress:\n  enabled: true\n  hosts: [a.hanzo.ai]\n"},
		{"empty file", ""},
		{"a block with no repository", "image:\n  tag: v1.0.0\n  digest: sha256:aa\n"},
		// A sidecar's image is not what the chart deploys, and reading it would
		// report the fleet running a log shipper.
		{"nested image belongs to something else",
			"sidecars:\n- name: shipper\n  image:\n    repository: ghcr.io/other/shipper\n    tag: v9\n"},
		{"the word appears in prose only",
			"# the image is published by the pipeline\nreplicas: 2\n"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if image, v := declared(tc.body); image != "" {
				t.Errorf("read image %q version %+v; want nothing", image, v)
			}
		})
	}
}

// TestSplitImageKeepsBothNames — a pinned reference names a release twice, and
// both halves are kept because they answer different questions.
func TestSplitImageKeepsBothNames(t *testing.T) {
	cases := []struct {
		ref, image string
		want       Version
	}{
		{"ghcr.io/hanzoai/cloud:v1.801.548@sha256:8830c2b1", "ghcr.io/hanzoai/cloud",
			Version{Tag: "v1.801.548", Digest: "sha256:8830c2b1"}},
		{"ghcr.io/hanzoai/cloud:v1.801.548", "ghcr.io/hanzoai/cloud", Version{Tag: "v1.801.548"}},
		{"ghcr.io/hanzoai/cloud@sha256:8830", "ghcr.io/hanzoai/cloud", Version{Digest: "sha256:8830"}},
		{"ghcr.io/hanzoai/cloud", "ghcr.io/hanzoai/cloud", Version{}},
		// A colon before the last slash is a registry port, not a tag.
		{"oci.hanzo.ai:5000/hanzo/a:v1", "oci.hanzo.ai:5000/hanzo/a", Version{Tag: "v1"}},
		{"oci.hanzo.ai:5000/hanzo/a", "oci.hanzo.ai:5000/hanzo/a", Version{}},
	}
	for _, tc := range cases {
		image, got := splitImage(tc.ref)
		if image != tc.image || got != tc.want {
			t.Errorf("splitImage(%q) = %q %+v; want %q %+v", tc.ref, image, got, tc.image, tc.want)
		}
	}
}
