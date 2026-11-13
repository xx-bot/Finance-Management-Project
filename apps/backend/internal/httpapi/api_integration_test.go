package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"image"
	"image/png"
	"io"
	"log/slog"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"pocketledger/backend/internal/auth"
	"pocketledger/backend/internal/config"
	"pocketledger/backend/internal/domain"
	"pocketledger/backend/internal/extraction"
	"pocketledger/backend/internal/store"
)

type fakeExtractor struct{ calls atomic.Int32 }

func (f *fakeExtractor) Configured() bool { return true }
func (f *fakeExtractor) Extract(ctx context.Context, data []byte, mime string) (extraction.Result, error) {
	f.calls.Add(1)
	receipt, err := domain.ParseReceipt([]byte(`{"merchant":"Corner shop","category":"household","items":[],"total":"436.20"}`))
	return extraction.Result{Receipt: receipt, Provider: "test", Model: "mock", Usage: map[string]*int64{}}, err
}

type fixture struct {
	db        *store.Store
	server    *httptest.Server
	extractor *fakeExtractor
}

func setup(t *testing.T) *fixture {
	t.Helper()
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" && os.Getenv("TEST_DATABASE") == "true" {
		c, err := config.Load("")
		if err != nil {
			t.Fatal(err)
		}
		databaseURL = c.DatabaseURL
	}
	if databaseURL == "" {
		t.Skip("set TEST_DATABASE_URL or use the Docker Compose tests profile to run PostgreSQL integration tests")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	db, err := store.Open(ctx, databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Pool.Close)
	if err = db.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	if err = db.Migrate(ctx); err != nil {
		t.Fatal("migrations are not repeatable:", err)
	}
	provider := &fakeExtractor{}
	handler, err := New(db, provider, Options{AllowRegistration: true, PasswordCost: 4, Logger: slog.New(slog.NewTextHandler(io.Discard, nil))})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	return &fixture{db, server, provider}
}
func (f *fixture) request(t *testing.T, method, path, token string, body any, status int) []byte {
	t.Helper()
	var encoded []byte
	if body != nil {
		var err error
		encoded, err = json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
	}
	request, err := http.NewRequest(method, f.server.URL+path, bytes.NewReader(encoded))
	if err != nil {
		t.Fatal(err)
	}
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	response, err := f.server.Client().Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	data, _ := io.ReadAll(response.Body)
	if response.StatusCode != status {
		t.Fatalf("%s %s status=%d want=%d response=%s", method, path, response.StatusCode, status, data)
	}
	return data
}
func (f *fixture) register(t *testing.T) auth.Result {
	t.Helper()
	id, _ := auth.ID()
	var result auth.Result
	body := f.request(t, "POST", "/api/auth/register", "", map[string]string{"email": id + "@example.test", "password": "long-test-password"}, 201)
	if err := json.Unmarshal(body, &result); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = f.db.Pool.Exec(context.Background(), "DELETE FROM users WHERE id=$1", result.User.ID) })
	return result
}

func TestIntegrationSessionsAndIsolation(t *testing.T) {
	f := setup(t)
	a, b := f.register(t), f.register(t)
	f.request(t, "GET", "/api/me", "", nil, 401)
	f.request(t, "GET", "/api/me", a.AccessToken, nil, 200)
	var sessionHash []byte
	var passwordHash []byte
	if err := f.db.Pool.QueryRow(context.Background(), "SELECT token_hash,password_hash FROM sessions JOIN users ON users.id=sessions.user_id WHERE users.id=$1", a.User.ID).Scan(&sessionHash, &passwordHash); err != nil {
		t.Fatal(err)
	}
	if len(sessionHash) != 32 || bytes.Contains(passwordHash, []byte("long-test-password")) {
		t.Fatal("credentials were not hashed")
	}
	e := domain.Expense{ID: "same-client-id", Merchant: "Corner shop", Date: "2026-11-12T00:00:00.000", Currency: "MYR", TotalMinor: 1001, Category: "groceries",
		Lines: []domain.ExpenseLine{{Description: "A", AmountMinor: 500, Category: "groceries"}, {Description: "B", AmountMinor: 500, Category: "dining"}}, Adjustments: []domain.Adjustment{{Label: "Rounding", AmountMinor: 1}}, Status: "verified"}
	f.request(t, "PUT", "/api/expenses/"+e.ID, a.AccessToken, e, 200)
	f.request(t, "PUT", "/api/expenses/"+e.ID, a.AccessToken, e, 200)
	usd := e
	usd.ID = "other-currency"
	usd.Currency = "USD"
	f.request(t, "PUT", "/api/expenses/"+usd.ID, a.AccessToken, usd, 200)
	data := f.request(t, "GET", "/api/expenses?currency=MYR&month=2026-11&limit=1", a.AccessToken, nil, 200)
	var page domain.ExpensePage
	if err := json.Unmarshal(data, &page); err != nil {
		t.Fatal(err)
	}
	if len(page.Expenses) != 1 || page.HasMore || len(page.Expenses[0].Lines) != 2 {
		t.Fatal("retry duplicated an expense or item persistence failed")
	}
	f.request(t, "GET", "/api/expenses/"+e.ID, b.AccessToken, nil, 404)
	f.request(t, "DELETE", "/api/expenses/"+e.ID, b.AccessToken, nil, 404)
	e.Merchant = "Other person's shop"
	f.request(t, "PUT", "/api/expenses/"+e.ID, b.AccessToken, e, 200)
	var original domain.Expense
	data = f.request(t, "GET", "/api/expenses/"+e.ID, a.AccessToken, nil, 200)
	if err := json.Unmarshal(data, &original); err != nil {
		t.Fatal(err)
	}
	if original.Merchant != "Corner shop" {
		t.Fatal("cross-account update")
	}
	var summary store.Summary
	data = f.request(t, "GET", "/api/summary?currency=MYR&month=2026-11", a.AccessToken, nil, 200)
	if err := json.Unmarshal(data, &summary); err != nil {
		t.Fatal(err)
	}
	if summary.TotalMinor != 1001 || summary.CategoryTotals["groceries"] != 501 || summary.CategoryTotals["dining"] != 500 || summary.DailyTotals[11] != 1001 {
		t.Fatalf("summary=%+v", summary)
	}
	f.request(t, "PUT", "/api/budgets/MYR", a.AccessToken, map[string]int64{"amount_minor": 99900}, 200)
	f.request(t, "GET", "/api/budgets", a.AccessToken, nil, 200)
	e.TotalMinor = 5000
	f.request(t, "PUT", "/api/expenses/"+e.ID, a.AccessToken, e, 400)
	f.request(t, "POST", "/api/auth/login", "", map[string]string{"email": a.User.Email, "password": "wrong-password"}, 401)
	data = f.request(t, "POST", "/api/auth/login", "", map[string]string{"email": a.User.Email, "password": "long-test-password"}, 200)
	var login auth.Result
	_ = json.Unmarshal(data, &login)
	f.request(t, "POST", "/api/auth/logout", login.AccessToken, nil, 204)
	f.request(t, "GET", "/api/me", login.AccessToken, nil, 401)
	f.request(t, "DELETE", "/api/expenses/"+e.ID, a.AccessToken, nil, 204)
	f.request(t, "GET", "/api/expenses/"+e.ID, a.AccessToken, nil, 404)
}

func TestIntegrationUploadAndNoAutomaticSave(t *testing.T) {
	f := setup(t)
	user := f.register(t)
	f.request(t, "GET", "/health/ready", "", nil, 200)
	for index, valid := range []bool{false, true} {
		var body bytes.Buffer
		writer := multipart.NewWriter(&body)
		part, err := writer.CreateFormFile("image", "receipt.png")
		if err != nil {
			t.Fatal(err)
		}
		if valid {
			if err = png.Encode(part, image.NewRGBA(image.Rect(0, 0, 2, 2))); err != nil {
				t.Fatal(err)
			}
		} else {
			_, _ = part.Write([]byte("not an image"))
		}
		_ = writer.Close()
		request, _ := http.NewRequest("POST", f.server.URL+"/api/receipts/extract", &body)
		request.Header.Set("Content-Type", writer.FormDataContentType())
		request.Header.Set("Authorization", "Bearer "+user.AccessToken)
		response, err := f.server.Client().Do(request)
		if err != nil {
			t.Fatal(err)
		}
		data, _ := io.ReadAll(response.Body)
		response.Body.Close()
		want := 415
		if valid {
			want = 200
		}
		if response.StatusCode != want {
			t.Fatalf("upload %d status=%d body=%s", index, response.StatusCode, data)
		}
		if valid {
			var result extraction.Result
			if err := json.Unmarshal(data, &result); err != nil || result.Receipt.Merchant == nil || *result.Receipt.Merchant != "Corner shop" || result.Receipt.Category != "household" {
				t.Fatal("extraction did not return reviewable merchant/category suggestions", err)
			}
		}
	}
	if f.extractor.calls.Load() != 1 {
		t.Fatal("invalid upload reached extraction")
	}
	var count int
	if err := f.db.Pool.QueryRow(context.Background(), "SELECT count(*) FROM expenses WHERE user_id=$1", user.User.ID).Scan(&count); err != nil || count != 0 {
		t.Fatal("extraction saved an unreviewed expense", err)
	}
	f.request(t, "GET", "/api/expenses?currency=INVALID", user.AccessToken, nil, 400)
	f.request(t, "PUT", "/api/expenses/body-id", user.AccessToken, map[string]any{"id": "different"}, 400)
	_, err := f.db.Pool.Exec(context.Background(), "UPDATE sessions SET expires_at=now()-interval '1 second' WHERE token_hash=$1", auth.TokenHash(user.AccessToken))
	if err != nil {
		t.Fatal(err)
	}
	f.request(t, "GET", "/api/me", user.AccessToken, nil, 401)
}

func TestLimiter(t *testing.T) {
	l := &limiter{entries: map[string]window{}}
	for i := 0; i < 6; i++ {
		if !l.allow("user", 6) {
			t.Fatal("rate limit too early")
		}
	}
	if l.allow("user", 6) || !l.allow("another-user", 6) {
		t.Fatal("rate limit did not isolate accounts")
	}
	l.entries["user"] = window{start: time.Now().Add(-2 * time.Minute), count: 6}
	if !l.allow("user", 6) {
		t.Fatal("rate limit did not reset")
	}
}
