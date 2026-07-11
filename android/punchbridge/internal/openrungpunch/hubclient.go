package openrungpunch

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

type HubClient struct {
	BaseURL    string
	HTTPClient *http.Client
}

func (c HubClient) httpClient() *http.Client {
	if c.HTTPClient != nil {
		return c.HTTPClient
	}
	return &http.Client{
		Timeout: 10 * time.Second,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
		Transport: &http.Transport{DisableKeepAlives: true},
	}
}

func (c HubClient) FetchConfig(ctx context.Context) (PunchConfig, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(c.BaseURL, "/")+PathPunchConfig, nil)
	if err != nil {
		return PunchConfig{}, err
	}
	response, err := c.httpClient().Do(request)
	if err != nil {
		return PunchConfig{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return PunchConfig{}, fmt.Errorf("punch config: unexpected status %d", response.StatusCode)
	}
	var config PunchConfig
	if err := json.NewDecoder(io.LimitReader(response.Body, 16<<10)).Decode(&config); err != nil {
		return PunchConfig{}, fmt.Errorf("decode punch config: %w", err)
	}
	return config, nil
}

func (c HubClient) RequestPunch(ctx context.Context, body PunchRequest) (PunchResponse, error) {
	var response PunchResponse
	if err := c.postJSON(ctx, PathPunchRequest, body, &response); err != nil {
		return PunchResponse{}, err
	}
	return response, nil
}

func (c HubClient) postJSON(ctx context.Context, path string, body any, out any) error {
	payload, err := json.Marshal(body)
	if err != nil {
		return err
	}
	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		strings.TrimRight(c.BaseURL, "/")+path,
		bytes.NewReader(payload),
	)
	if err != nil {
		return err
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := c.httpClient().Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("punch hub %s: status %d", path, response.StatusCode)
	}
	if out != nil {
		if err := json.NewDecoder(io.LimitReader(response.Body, 16<<10)).Decode(out); err != nil {
			return fmt.Errorf("decode punch response: %w", err)
		}
	}
	return nil
}
