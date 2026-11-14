package ci

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

// identity.go is how this service proves who it is to Hanzo Git.
//
// The forge accepts only a Hanzo IAM token, so there is nothing to store: the
// pod already carries a ServiceAccount token the kubelet minted for it, for the
// IAM audience, and IAM exchanges it (RFC 7523) for a bearer that lasts about an
// hour. The bearer is kept in memory, renewed shortly before it ends, and never
// written anywhere. Whoever the pod's account is, the forge decides what that
// subject may read.

const (
	bearerGrant = "urn:ietf:params:oauth:grant-type:jwt-bearer"
	// renewBefore is how long before expiry a bearer is replaced, so a request
	// never carries one that ends in flight.
	renewBefore = 5 * time.Minute
)

// workloadAssertion is where the kubelet projects the token, and workloadIssuer
// is the IAM that exchanges it. Both are the names the rest of the fleet reads.
func workloadAssertion() string {
	return env("HANZO_SA_TOKEN", "/var/run/secrets/hanzo/iam/token")
}

func workloadIssuer() string {
	return strings.TrimRight(env("HANZO_IAM_URL", "https://hanzo.id"), "/")
}

// identity renews the bearer on demand. One value serves every poller.
type identity struct {
	file, issuer string
	client       *http.Client

	mu     sync.Mutex
	bearer string
	until  time.Time
}

func newIdentity() *identity {
	return &identity{file: workloadAssertion(), issuer: workloadIssuer(), client: &http.Client{Timeout: 15 * time.Second}}
}

// mounted reports whether the pod carries an assertion at all, so a deployment
// without one fails closed at start instead of at the first read.
func (i *identity) mounted() error {
	if _, err := os.Stat(i.file); err != nil {
		return fmt.Errorf("no workload identity mounted at %s", i.file)
	}
	return nil
}

// token returns a bearer that is good for at least renewBefore.
func (i *identity) token(ctx context.Context) (string, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	if i.bearer != "" && time.Until(i.until) > renewBefore {
		return i.bearer, nil
	}
	assertion, err := os.ReadFile(i.file)
	if err != nil {
		return "", fmt.Errorf("read workload assertion: %w", err)
	}
	form := url.Values{"grant_type": {bearerGrant}, "assertion": {strings.TrimSpace(string(assertion))}}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, i.issuer+"/v1/iam/oauth/token", strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	resp, err := i.client.Do(req)
	if err != nil {
		return "", errors.New("IAM workload exchange unreachable")
	}
	defer resp.Body.Close()
	// A refusal never quotes the body: a token response carries credentials.
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("IAM workload exchange answered HTTP %d", resp.StatusCode)
	}
	var answer struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int64  `json:"expires_in"`
	}
	if json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&answer) != nil || answer.AccessToken == "" {
		return "", errors.New("IAM workload exchange returned no token")
	}
	i.bearer = answer.AccessToken
	i.until = time.Now().Add(time.Duration(answer.ExpiresIn) * time.Second)
	return i.bearer, nil
}
