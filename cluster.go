package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"
)

// cluster.go reads what is actually running.
//
// It talks to the apiserver over plain HTTP because that is what the apiserver
// is: a JSON REST API this service can read with the same client it already
// points at the forge. A generated Kubernetes client would be the first
// dependency this repo has ever had, carried to spend two verbs on three
// resources.
//
// The identity is the pod's own ServiceAccount, granted get and list on
// workloads and nothing else. No kubeconfig is stored, so there is no secret to
// hold, rotate or leak — the token is minted by the cluster for this pod and
// expires on its own.

const (
	serviceAccount = "/var/run/secrets/kubernetes.io/serviceaccount"
	apiHost        = "https://kubernetes.default.svc"
)

type cluster struct {
	host string
	dir  string
	http *http.Client
}

// dial prepares a reader for the cluster this pod runs in. It fails when the
// ServiceAccount is not mounted, which is the honest answer off-cluster: the
// fleet view then reports that it cannot read running state, rather than drawing
// every service as absent.
func dial(dir, host string) (*cluster, error) {
	ca, err := os.ReadFile(dir + "/ca.crt")
	if err != nil {
		return nil, fmt.Errorf("cluster identity: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(ca) {
		return nil, fmt.Errorf("cluster identity: ca.crt holds no certificate")
	}
	return &cluster{
		host: host,
		dir:  dir,
		http: &http.Client{
			Timeout: 30 * time.Second,
			Transport: &http.Transport{
				TLSClientConfig: &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12},
			},
		},
	}, nil
}

// workload is the part of a Deployment, StatefulSet or DaemonSet this view
// reads. The three kinds differ only in how they count replicas, so they are
// decoded through one shape and the count is taken from whichever pair is set.
type workload struct {
	Metadata struct {
		Name      string `json:"name"`
		Namespace string `json:"namespace"`
	} `json:"metadata"`
	Spec struct {
		Replicas *int `json:"replicas"`
		Template struct {
			Spec struct {
				Containers []struct {
					Image string `json:"image"`
				} `json:"containers"`
			} `json:"spec"`
		} `json:"template"`
	} `json:"spec"`
	Status struct {
		ReadyReplicas          int `json:"readyReplicas"`
		Replicas               int `json:"replicas"`
		NumberReady            int `json:"numberReady"`
		DesiredNumberScheduled int `json:"desiredNumberScheduled"`
	} `json:"status"`
}

// running lists every container image the cluster is currently running, with the
// readiness of the workload carrying it.
//
// Every container is reported, not a guessed primary one. Which container holds
// the service is decided by the image the service declares, and picking here — by
// ordinal, or by a name that matches the workload — would be a convention that
// silently reads the wrong image the first time a sidecar is listed first.
func (c *cluster) running(ctx context.Context) ([]live, error) {
	if c == nil {
		return nil, fmt.Errorf("no cluster identity mounted at %s", serviceAccount)
	}
	var out []live
	for _, kind := range []string{"deployments", "statefulsets", "daemonsets"} {
		var body struct {
			Items []workload `json:"items"`
		}
		if err := c.getJSON(ctx, "/apis/apps/v1/"+kind, &body); err != nil {
			return nil, err
		}
		for _, w := range body.Items {
			ready, want := w.Status.ReadyReplicas, w.Status.Replicas
			if w.Status.DesiredNumberScheduled > 0 {
				ready, want = w.Status.NumberReady, w.Status.DesiredNumberScheduled
			}
			if w.Spec.Replicas != nil && want == 0 {
				want = *w.Spec.Replicas
			}
			for _, ct := range w.Spec.Template.Spec.Containers {
				image, v := splitImage(ct.Image)
				if image == "" {
					continue
				}
				out = append(out, live{
					Name:      w.Metadata.Name,
					Namespace: w.Metadata.Namespace,
					Image:     image,
					Version:   v,
					Ready:     ready,
					Want:      want,
				})
			}
		}
	}
	return out, nil
}

func (c *cluster) getJSON(ctx context.Context, path string, out any) error {
	// The token is read per request. A projected ServiceAccount token is rotated
	// by the kubelet well inside this pod's lifetime, so one read at startup
	// would work for an hour and then fail with 401 for as long as the pod lives.
	token, err := os.ReadFile(c.dir + "/token")
	if err != nil {
		return fmt.Errorf("cluster identity: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.host+path, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(token)))
	req.Header.Set("Accept", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s: %s", path, resp.Status)
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

// splitImage separates a reference into the repository and the version naming it.
//
// A pinned reference carries both — ghcr.io/hanzoai/cloud:v1.801.548@sha256:… —
// because the tag is what a human reads and the digest is what is pulled. Both
// are kept: comparing on the digest is what makes "declared equals running" a
// statement about bytes rather than about a label that can be moved.
func splitImage(ref string) (string, Version) {
	var v Version
	if i := strings.LastIndex(ref, "@"); i > 0 {
		v.Digest, ref = ref[i+1:], ref[:i]
	}
	// A colon after the last slash is a tag; before it, it is a registry port.
	if i := strings.LastIndexByte(ref, ':'); i > strings.LastIndexByte(ref, '/') {
		v.Tag, ref = ref[i+1:], ref[:i]
	}
	return ref, v
}
