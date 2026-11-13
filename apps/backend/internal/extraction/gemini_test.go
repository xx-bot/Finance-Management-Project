package extraction

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

const receiptJSON = `{"merchant":"Corner Cafe","category":"dining","items":[{"category":"dining","description":"Coffee","quantity":"1x","unit_price":null,"line_total":"12.00","sub_items":[]}],"total":"12.00"}`

func response(text, finish string) []byte {
	out, _ := json.Marshal(map[string]any{"candidates": []any{map[string]any{"finishReason": finish, "content": map[string]any{"parts": []any{map[string]any{"text": text}}}}}, "usageMetadata": map[string]int{"promptTokenCount": 123, "candidatesTokenCount": 45, "totalTokenCount": 168}, "modelVersion": "mock-model"})
	return out
}
func TestGeminiRequestAndSchema(t *testing.T) {
	calls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.Header.Get("x-goog-api-key") != "test-key" || r.URL.Path != "/models/gemini-3.5-flash-lite:generateContent" {
			t.Error("incorrect Gemini request")
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		config := body["generationConfig"].(map[string]any)
		if config["responseMimeType"] != "application/json" || config["candidateCount"] != float64(1) || config["responseJsonSchema"] == nil {
			t.Error("missing structured output settings")
		}
		if config["thinkingConfig"].(map[string]any)["thinkingLevel"] != "MINIMAL" {
			t.Error("incorrect thinking configuration")
		}
		props := config["responseJsonSchema"].(map[string]any)["properties"].(map[string]any)
		if props["merchant"] == nil || props["category"] == nil {
			t.Error("missing merchant or category schema")
		}
		category := props["category"].(map[string]any)
		if len(category["enum"].([]any)) != 8 {
			t.Error("unexpected category taxonomy")
		}
		_, _ = w.Write(response(receiptJSON, "STOP"))
	}))
	defer server.Close()
	g, err := NewGemini("test-key", "gemini-3.5-flash-lite", 4096)
	if err != nil {
		t.Fatal(err)
	}
	g.baseURL = server.URL
	result, err := g.Extract(context.Background(), []byte{1, 2, 3}, "image/jpeg")
	if err != nil {
		t.Fatal(err)
	}
	if calls != 1 || *result.Receipt.Total != "12.00" || *result.Usage["input_tokens"] != 123 {
		t.Fatal("invalid result")
	}
	if *result.Receipt.Merchant != "Corner Cafe" || result.Receipt.Category != "dining" || result.Receipt.Items[0].Category != "dining" {
		t.Fatal("merchant or categories were lost")
	}
}
func TestGeminiFailureDoesNotRetry(t *testing.T) {
	for _, status := range []int{400, 401, 403, 404, 429, 500} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			calls := 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls++
				w.WriteHeader(status)
				_, _ = w.Write([]byte("sensitive upstream error test-key"))
			}))
			defer server.Close()
			g, _ := NewGemini("test-key", "gemini-3.5-flash-lite", 2048)
			g.baseURL = server.URL
			_, err := g.Extract(context.Background(), []byte{1}, "image/jpeg")
			var upstream *Error
			if !errors.As(err, &upstream) || calls != 1 || strings.Contains(err.Error(), "test-key") {
				t.Fatal("unsafe failure or unexpected retry")
			}
			if status == 429 && upstream.Status != 429 {
				t.Fatal("quota failure was hidden")
			}
		})
	}
}
func TestIncompleteAndRepeatedJSONRejected(t *testing.T) {
	for _, sample := range []struct{ text, finish string }{{receiptJSON, "MAX_TOKENS"}, {receiptJSON + "\n" + receiptJSON, "STOP"}, {`{"items":[],"total":3}`, "STOP"}, {`{"items":[{}],"total":null}`, "STOP"}} {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write(response(sample.text, sample.finish)) }))
		g, _ := NewGemini("test-key", "gemini-3.5-flash-lite", 2048)
		g.baseURL = server.URL
		if _, err := g.Extract(context.Background(), nil, "image/jpeg"); err == nil {
			t.Fatal("accepted invalid or truncated output")
		}
		server.Close()
	}
}
func TestCancelledRequest(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		select {
		case <-r.Context().Done():
		case <-time.After(time.Second):
		}
	}))
	defer server.Close()
	g, _ := NewGemini("test-key", "gemini-3.5-flash-lite", 2048)
	g.baseURL = server.URL
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()
	if _, err := g.Extract(ctx, nil, "image/jpeg"); err == nil {
		t.Fatal("ignored cancellation")
	}
}

func TestOversizedInlineRequestNeverReachesGemini(t *testing.T) {
	calls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls++; w.WriteHeader(500) }))
	defer server.Close()
	g, _ := NewGemini("test-key", "gemini-3.5-flash-lite", 2048)
	g.baseURL = server.URL
	_, err := g.Extract(context.Background(), make([]byte, 15*1024*1024), "image/jpeg")
	var upstream *Error
	if !errors.As(err, &upstream) || upstream.Status != 413 || calls != 0 {
		t.Fatal("oversized inline request was not rejected before calling Gemini")
	}
}
