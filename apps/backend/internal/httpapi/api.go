package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"image"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	_ "golang.org/x/image/webp"

	"pocketledger/backend/internal/auth"
	"pocketledger/backend/internal/domain"
	"pocketledger/backend/internal/extraction"
	"pocketledger/backend/internal/store"
)

type Options struct {
	SessionTTL, ExtractionTimeout       time.Duration
	AllowRegistration                   bool
	PasswordCost, ExtractionConcurrency int
	Logger                              *slog.Logger
}
type API struct {
	store     *store.Store
	extractor extraction.Extractor
	options   Options
	dummyHash []byte
	slots     chan struct{}
	limiter   *limiter
}
type userKey struct{}
type credentialInput struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

func New(s *store.Store, extractor extraction.Extractor, options Options) (http.Handler, error) {
	if options.Logger == nil {
		options.Logger = slog.Default()
	}
	if options.PasswordCost == 0 {
		options.PasswordCost = 12
	}
	if options.ExtractionConcurrency < 1 {
		options.ExtractionConcurrency = 2
	}
	if options.SessionTTL == 0 {
		options.SessionTTL = 720 * time.Hour
	}
	if options.ExtractionTimeout == 0 {
		options.ExtractionTimeout = 90 * time.Second
	}
	dummy, err := auth.HashPassword("not-a-real-user-password", options.PasswordCost)
	if err != nil {
		return nil, err
	}
	a := &API{store: s, extractor: extractor, options: options, dummyHash: dummy, slots: make(chan struct{}, options.ExtractionConcurrency), limiter: &limiter{entries: map[string]window{}}}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health/live", func(w http.ResponseWriter, r *http.Request) { write(w, 200, map[string]string{"status": "alive"}) })
	mux.HandleFunc("GET /health/ready", a.ready)
	mux.HandleFunc("POST /api/auth/register", a.credentials(true))
	mux.HandleFunc("POST /api/auth/login", a.credentials(false))
	mux.Handle("POST /api/auth/logout", a.authenticated(http.HandlerFunc(a.logout)))
	mux.Handle("GET /api/me", a.authenticated(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { write(w, 200, currentUser(r)) })))
	mux.Handle("GET /api/categories", a.authenticated(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		write(w, 200, map[string]any{"categories": domain.Categories})
	})))
	mux.Handle("POST /api/receipts/extract", a.authenticated(http.HandlerFunc(a.extract)))
	mux.Handle("GET /api/expenses", a.authenticated(http.HandlerFunc(a.listExpenses)))
	mux.Handle("GET /api/expenses/{id}", a.authenticated(http.HandlerFunc(a.getExpense)))
	mux.Handle("PUT /api/expenses/{id}", a.authenticated(http.HandlerFunc(a.putExpense)))
	mux.Handle("DELETE /api/expenses/{id}", a.authenticated(http.HandlerFunc(a.deleteExpense)))
	mux.Handle("GET /api/budgets", a.authenticated(http.HandlerFunc(a.getBudgets)))
	mux.Handle("PUT /api/budgets/{currency}", a.authenticated(http.HandlerFunc(a.putBudget)))
	mux.Handle("GET /api/summary", a.authenticated(http.HandlerFunc(a.summary)))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 120*time.Second)
		defer cancel()
		r = r.WithContext(ctx)
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Cache-Control", "no-store")
		start := time.Now()
		defer func() {
			if recovered := recover(); recovered != nil {
				options.Logger.Error("request panic", "route", r.Pattern)
				fail(w, 500, "internal_error", "An internal error occurred.")
			}
			options.Logger.Info("request", "method", r.Method, "route", r.Pattern, "duration_ms", time.Since(start).Milliseconds())
		}()
		mux.ServeHTTP(w, r)
	}), nil
}

func write(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if value != nil {
		_ = json.NewEncoder(w).Encode(value)
	}
}
func fail(w http.ResponseWriter, status int, code, message string) {
	write(w, status, map[string]any{"error": map[string]string{"code": code, "message": message}})
}
func currentUser(r *http.Request) auth.User { return r.Context().Value(userKey{}).(auth.User) }
func readJSON(w http.ResponseWriter, r *http.Request, target any) bool {
	if !strings.HasPrefix(strings.ToLower(r.Header.Get("Content-Type")), "application/json") {
		fail(w, 415, "content_type", "Use application/json.")
		return false
	}
	r.Body = http.MaxBytesReader(w, r.Body, 1024*1024)
	data, err := io.ReadAll(r.Body)
	var max *http.MaxBytesError
	if errors.As(err, &max) {
		fail(w, 413, "body_too_large", "The JSON body exceeds 1 MiB.")
		return false
	}
	if err != nil {
		fail(w, 400, "invalid_body", "Could not read the request body.")
		return false
	}
	if err = domain.DecodeJSON(data, target); err != nil {
		fail(w, 400, "invalid_json", err.Error())
		return false
	}
	return true
}
func (a *API) databaseError(w http.ResponseWriter, r *http.Request, err error) {
	if errors.Is(err, store.ErrNotFound) {
		fail(w, 404, "not_found", "Record not found.")
		return
	}
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(r.Context().Err(), context.DeadlineExceeded) {
		fail(w, 504, "timeout", "The operation timed out.")
		return
	}
	a.options.Logger.Error("database operation failed", "route", r.Pattern) // Never log SQL parameters or credentials.
	fail(w, 500, "database_error", "Could not complete the database operation.")
}
func (a *API) ready(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := a.store.Pool.Ping(ctx); err != nil {
		fail(w, 503, "not_ready", "Database is unavailable.")
		return
	}
	write(w, 200, map[string]any{"status": "ready", "extraction_configured": a.extractor.Configured()})
}
func (a *API) authenticated(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		parts := strings.Fields(r.Header.Get("Authorization"))
		if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") || len(parts[1]) != 43 {
			fail(w, 401, "unauthorized", "A valid bearer session is required.")
			return
		}
		user, err := a.store.Authenticate(r.Context(), auth.TokenHash(parts[1]))
		if errors.Is(err, store.ErrNotFound) {
			fail(w, 401, "unauthorized", "The session is invalid or expired.")
			return
		}
		if err != nil {
			a.databaseError(w, r, err)
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), userKey{}, user)))
	})
}

func (a *API) credentials(register bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if register && !a.options.AllowRegistration {
			fail(w, 403, "registration_disabled", "Registration is disabled.")
			return
		}
		ip, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil {
			ip = r.RemoteAddr
		}
		if !a.limiter.allow("auth:"+ip, 20) {
			w.Header().Set("Retry-After", "60")
			fail(w, 429, "rate_limit", "Too many authentication attempts. Try again later.")
			return
		}
		var input credentialInput
		if !readJSON(w, r, &input) {
			return
		}
		email, err := auth.Credentials(input.Email, input.Password)
		if err != nil {
			fail(w, 400, "invalid_credentials", err.Error())
			return
		}
		token, err := auth.Token()
		if err != nil {
			fail(w, 500, "internal_error", "Could not create a session.")
			return
		}
		expires := time.Now().UTC().Add(a.options.SessionTTL)
		var user auth.User
		if register {
			id, err := auth.ID()
			if err != nil {
				fail(w, 500, "internal_error", "Could not create an account.")
				return
			}
			hash, err := auth.HashPassword(input.Password, a.options.PasswordCost)
			if err != nil {
				fail(w, 500, "internal_error", "Could not create an account.")
				return
			}
			user, err = a.store.CreateAccount(r.Context(), auth.User{ID: id, Email: email}, hash, auth.TokenHash(token), expires)
			if errors.Is(err, store.ErrConflict) {
				fail(w, 409, "email_exists", "An account already exists for this email.")
				return
			}
			if err != nil {
				a.databaseError(w, r, err)
				return
			}
		} else {
			var hash []byte
			user, hash, err = a.store.UserByEmail(r.Context(), email)
			if err != nil && !errors.Is(err, store.ErrNotFound) {
				a.databaseError(w, r, err)
				return
			}
			missing := errors.Is(err, store.ErrNotFound)
			if missing {
				hash = a.dummyHash
			}
			if !auth.CheckPassword(hash, input.Password) || missing {
				fail(w, 401, "invalid_credentials", "Email or password is incorrect.")
				return
			}
			if err = a.store.AddSession(r.Context(), user.ID, auth.TokenHash(token), expires); err != nil {
				a.databaseError(w, r, err)
				return
			}
		}
		status := 200
		if register {
			status = 201
		}
		write(w, status, auth.Result{User: user, AccessToken: token, TokenType: "Bearer", ExpiresAt: expires})
	}
}
func (a *API) logout(w http.ResponseWriter, r *http.Request) {
	token := strings.Fields(r.Header.Get("Authorization"))[1]
	if err := a.store.Logout(r.Context(), auth.TokenHash(token)); err != nil {
		a.databaseError(w, r, err)
		return
	}
	write(w, 204, nil)
}

func (a *API) extract(w http.ResponseWriter, r *http.Request) {
	if !a.extractor.Configured() {
		fail(w, 503, "extraction_unavailable", "Set GEMINI_API_KEY on the backend to enable extraction.")
		return
	}
	if !a.limiter.allow("extract:"+currentUser(r).ID, 6) {
		w.Header().Set("Retry-After", "60")
		fail(w, 429, "rate_limit", "At most six extraction requests per minute are allowed per account.")
		return
	}
	select {
	case a.slots <- struct{}{}:
		defer func() { <-a.slots }()
	default:
		w.Header().Set("Retry-After", "5")
		fail(w, 429, "busy", "Receipt extraction is busy. Try again shortly.")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 16*1024*1024)
	if err := r.ParseMultipartForm(1024 * 1024); err != nil {
		if r.MultipartForm != nil {
			_ = r.MultipartForm.RemoveAll()
		}
		var max *http.MaxBytesError
		if errors.As(err, &max) {
			fail(w, 413, "body_too_large", "The upload exceeds 16 MiB.")
		} else {
			fail(w, 400, "invalid_upload", "Send multipart/form-data with one image field.")
		}
		return
	}
	defer r.MultipartForm.RemoveAll()
	if len(r.MultipartForm.File) != 1 || len(r.MultipartForm.File["image"]) != 1 {
		fail(w, 400, "invalid_upload", "Upload exactly one file in the image field.")
		return
	}
	file, err := r.MultipartForm.File["image"][0].Open()
	if err != nil {
		fail(w, 400, "invalid_upload", "Could not read the image.")
		return
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, 15*1024*1024+1))
	if err != nil {
		fail(w, 400, "invalid_upload", "Could not read the image.")
		return
	}
	if len(data) > 15*1024*1024 {
		fail(w, 413, "image_too_large", "Choose an image smaller than 15 MiB.")
		return
	}
	config, format, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil || (format != "jpeg" && format != "png" && format != "webp") {
		fail(w, 415, "unsupported_image", "Upload a JPEG, PNG or WebP image.")
		return
	}
	if config.Width < 1 || config.Height < 1 || int64(config.Width)*int64(config.Height) > 25000000 {
		fail(w, 400, "image_dimensions", "The image must contain at most 25 million pixels.")
		return
	}
	mime := "image/" + format
	ctx, cancel := context.WithTimeout(r.Context(), a.options.ExtractionTimeout)
	defer cancel()
	result, err := a.extractor.Extract(ctx, data, mime)
	if err != nil {
		if ctx.Err() != nil {
			fail(w, 504, "extraction_timeout", "Receipt extraction timed out. No receipt was saved.")
			return
		}
		var upstream *extraction.Error
		if errors.As(err, &upstream) {
			fail(w, upstream.Status, "extraction_failed", upstream.Message)
		} else {
			fail(w, 502, "extraction_failed", "Receipt extraction failed. No receipt was saved.")
		}
		return
	}
	write(w, 200, result)
}

func (a *API) listExpenses(w http.ResponseWriter, r *http.Request) {
	currency, month := r.URL.Query().Get("currency"), r.URL.Query().Get("month")
	if currency != "" && !domain.ValidCurrency(currency) {
		fail(w, 400, "invalid_currency", "Use IDR, MYR or USD.")
		return
	}
	if month != "" && !validMonth(month) {
		fail(w, 400, "invalid_month", "Use YYYY-MM.")
		return
	}
	limit, offset := 50, 0
	var err error
	if value := r.URL.Query().Get("limit"); value != "" {
		limit, err = strconv.Atoi(value)
		if err != nil || limit < 1 || limit > 100 {
			fail(w, 400, "invalid_limit", "limit must be between 1 and 100.")
			return
		}
	}
	if value := r.URL.Query().Get("offset"); value != "" {
		offset, err = strconv.Atoi(value)
		if err != nil || offset < 0 || offset > 1000000 {
			fail(w, 400, "invalid_offset", "offset must be between 0 and 1000000.")
			return
		}
	}
	page, err := a.store.Expenses(r.Context(), currentUser(r).ID, currency, month, limit, offset)
	if err != nil {
		a.databaseError(w, r, err)
		return
	}
	write(w, 200, page)
}
func (a *API) getExpense(w http.ResponseWriter, r *http.Request) {
	if !domain.ValidID(r.PathValue("id")) {
		fail(w, 400, "invalid_id", "Invalid expense ID.")
		return
	}
	e, err := a.store.Expense(r.Context(), currentUser(r).ID, r.PathValue("id"))
	if err != nil {
		a.databaseError(w, r, err)
		return
	}
	write(w, 200, e)
}
func (a *API) putExpense(w http.ResponseWriter, r *http.Request) {
	var e domain.Expense
	if !readJSON(w, r, &e) {
		return
	}
	if e.ID != r.PathValue("id") {
		fail(w, 400, "invalid_id", "The URL and body expense IDs must match.")
		return
	}
	if err := e.Validate(); err != nil {
		fail(w, 400, "invalid_expense", err.Error())
		return
	}
	saved, err := a.store.SaveExpense(r.Context(), currentUser(r).ID, e)
	if err != nil {
		a.databaseError(w, r, err)
		return
	}
	write(w, 200, saved)
}
func (a *API) deleteExpense(w http.ResponseWriter, r *http.Request) {
	if !domain.ValidID(r.PathValue("id")) {
		fail(w, 400, "invalid_id", "Invalid expense ID.")
		return
	}
	if err := a.store.DeleteExpense(r.Context(), currentUser(r).ID, r.PathValue("id")); err != nil {
		a.databaseError(w, r, err)
		return
	}
	write(w, 204, nil)
}
func (a *API) getBudgets(w http.ResponseWriter, r *http.Request) {
	budgets, err := a.store.Budgets(r.Context(), currentUser(r).ID)
	if err != nil {
		a.databaseError(w, r, err)
		return
	}
	write(w, 200, map[string]any{"budgets": budgets})
}
func (a *API) putBudget(w http.ResponseWriter, r *http.Request) {
	var input struct {
		AmountMinor int64 `json:"amount_minor"`
	}
	if !readJSON(w, r, &input) {
		return
	}
	b := domain.Budget{Currency: r.PathValue("currency"), AmountMinor: input.AmountMinor}
	if !domain.ValidCurrency(b.Currency) || b.AmountMinor < 1 || b.AmountMinor > domain.MaxMoney {
		fail(w, 400, "invalid_budget", "Choose IDR, MYR or USD and a positive amount_minor within the supported range.")
		return
	}
	if err := a.store.SaveBudget(r.Context(), currentUser(r).ID, b); err != nil {
		a.databaseError(w, r, err)
		return
	}
	write(w, 200, b)
}
func validMonth(value string) bool {
	parsed, err := time.Parse("2006-01", value)
	return err == nil && parsed.Format("2006-01") == value
}
func (a *API) summary(w http.ResponseWriter, r *http.Request) {
	currency, month := r.URL.Query().Get("currency"), r.URL.Query().Get("month")
	if !domain.ValidCurrency(currency) || !validMonth(month) {
		fail(w, 400, "invalid_filter", "Supply currency=IDR|MYR|USD and month=YYYY-MM.")
		return
	}
	summary, err := a.store.Summary(r.Context(), currentUser(r).ID, currency, month)
	if err != nil {
		a.databaseError(w, r, err)
		return
	}
	write(w, 200, summary)
}

type window struct {
	start time.Time
	count int
}
type limiter struct {
	mu      sync.Mutex
	entries map[string]window
}

func (l *limiter) allow(key string, max int) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	if len(l.entries) > 10000 {
		for k, v := range l.entries {
			if now.Sub(v.start) >= time.Minute {
				delete(l.entries, k)
			}
		}
		if len(l.entries) > 10000 {
			return false
		}
	}
	entry := l.entries[key]
	if now.Sub(entry.start) >= time.Minute {
		entry = window{start: now}
	}
	if entry.count >= max {
		return false
	}
	entry.count++
	l.entries[key] = entry
	return true
}
