package backend

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Client calls todofor.ai admin REST to mint short-lived, single-use
// enrollment tokens. The VM's bridge redeems the token once to get durable
// device credentials — the caller's API key never enters the VM.
type Client struct {
	baseURL string
	apiKey  string
	http    *http.Client
}

func New(baseURL, apiKey string) *Client {
	return &Client{
		baseURL: strings.TrimRight(baseURL, "/"),
		apiKey:  apiKey,
		http:    &http.Client{Timeout: 10 * time.Second},
	}
}

// MintEnrollToken mints a fresh enrollment token for userID, recorded against
// sandboxID so a successful redeem can attach-device for cleanup.
func (c *Client) MintEnrollToken(ctx context.Context, userID, sandboxID string, ttlSec uint32) (string, error) {
	body, _ := json.Marshal(map[string]any{
		"userId":    userID,
		"ttlSec":    ttlSec,
		"sandboxId": sandboxID,
	})
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost,
		c.baseURL+"/admin/v1/enroll/mint", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-API-Key", c.apiKey)

	resp, err := c.http.Do(req)
	if err != nil {
		return "", fmt.Errorf("mint request: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		b, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("mint failed: %d %s", resp.StatusCode, b)
	}
	var out struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", err
	}
	return out.Token, nil
}

