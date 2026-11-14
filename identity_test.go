package ci

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

// mountAssertion stands a ServiceAccount token where the pod would carry one.
func mountAssertion(t *testing.T) string {
	t.Helper()
	f := filepath.Join(t.TempDir(), "token")
	if err := os.WriteFile(f, []byte("pod-assertion\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HANZO_SA_TOKEN", f)
	return f
}

// The forge is shown the pod's assertion exchanged at IAM for a bearer, the
// bearer is reused until it is about to end, and then it is replaced.
func TestTheBearerIsExchangedKeptAndRenewed(t *testing.T) {
	var calls atomic.Int32
	expires := "3600"
	iam := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/iam/oauth/token" || r.Method != http.MethodPost {
			t.Errorf("exchange went to %s %s", r.Method, r.URL.Path)
		}
		_ = r.ParseForm()
		if r.Form.Get("grant_type") != bearerGrant || r.Form.Get("assertion") != "pod-assertion" {
			t.Errorf("exchange carried grant %q assertion %q", r.Form.Get("grant_type"), r.Form.Get("assertion"))
		}
		n := calls.Add(1)
		w.Write([]byte(`{"access_token":"bearer-` + string(rune('0'+n)) + `","expires_in":` + expires + `}`))
	}))
	defer iam.Close()
	mountAssertion(t)
	t.Setenv("HANZO_IAM_URL", iam.URL)
	who := newIdentity()

	for i := 0; i < 3; i++ {
		got, err := who.token(context.Background())
		if err != nil || got != "bearer-1" {
			t.Fatalf("token = %q, %v; want the first bearer reused", got, err)
		}
	}
	if calls.Load() != 1 {
		t.Fatalf("IAM was asked %d times for a bearer that had an hour left", calls.Load())
	}
	who.until = who.until.Add(-59 * 60 * 1e9) // inside the renewal window
	if got, _ := who.token(context.Background()); got != "bearer-2" {
		t.Fatalf("a bearer about to end was reused: %q", got)
	}
}

// A refusal says what happened and never what IAM answered.
func TestARefusedExchangeIsNamedAndQuotesNothing(t *testing.T) {
	iam := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte(`{"error":"secret-detail"}`))
	}))
	defer iam.Close()
	mountAssertion(t)
	t.Setenv("HANZO_IAM_URL", iam.URL)
	_, err := newIdentity().token(context.Background())
	if err == nil || !strings.Contains(err.Error(), "HTTP 400") || strings.Contains(err.Error(), "secret-detail") {
		t.Fatalf("err = %v", err)
	}
}

// Without an assertion the service refuses to start rather than fail on its
// first read of the forge.
func TestNoAssertionFailsConfiguration(t *testing.T) {
	t.Setenv("HANZO_SA_TOKEN", filepath.Join(t.TempDir(), "absent"))
	if _, err := loadConfig(); err == nil || !strings.Contains(err.Error(), "no workload identity") {
		t.Fatalf("loadConfig err = %v", err)
	}
}

// The requests that reach the forge carry the exchanged bearer as a Bearer.
func TestTheForgeIsAskedWithTheBearer(t *testing.T) {
	iam := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte(`{"access_token":"ey.a.b","expires_in":3600}`))
	}))
	defer iam.Close()
	var auth string
	forge := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth = r.Header.Get("Authorization")
		w.Write([]byte(`{}`))
	}))
	defer forge.Close()
	mountAssertion(t)
	t.Setenv("HANZO_IAM_URL", iam.URL)
	g := &gitSource{base: forge.URL, who: newIdentity(), http: http.DefaultClient}
	var out map[string]any
	if err := g.getJSON(context.Background(), "/v1/user", &out); err != nil {
		t.Fatal(err)
	}
	if auth != "Bearer ey.a.b" {
		t.Fatalf("Authorization = %q", auth)
	}
}
