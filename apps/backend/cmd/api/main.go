package main

import (
	"context"
	"flag"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"pocketledger/backend/internal/config"
	"pocketledger/backend/internal/extraction"
	"pocketledger/backend/internal/httpapi"
	"pocketledger/backend/internal/store"
)

func main() {
	if err := run(); err != nil {
		slog.Error("server stopped", "reason", err.Error())
		os.Exit(1)
	}
}
func run() error {
	envFile := flag.String("env-file", "", "optional dotenv path; existing environment variables take precedence")
	flag.Parse()
	settings, err := config.Load(*envFile)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	startup, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	db, err := store.Open(startup, settings.DatabaseURL)
	if err != nil {
		return err
	}
	defer db.Pool.Close()
	if err = db.Migrate(startup); err != nil {
		return err
	}
	provider, err := extraction.NewGemini(settings.GeminiKey, settings.GeminiModel, settings.MaxOutputTokens)
	if err != nil {
		return err
	}
	handler, err := httpapi.New(db, provider, httpapi.Options{SessionTTL: settings.SessionTTL, ExtractionTimeout: settings.ExtractionTimeout,
		AllowRegistration: settings.AllowRegistration, ExtractionConcurrency: settings.ExtractionConcurrency})
	if err != nil {
		return err
	}
	server := &http.Server{Addr: settings.Address, Handler: handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 30 * time.Second, WriteTimeout: 125 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 * 1024}
	failed := make(chan error, 1)
	go func() {
		slog.Info("backend listening", "address", settings.Address, "extraction_configured", provider.Configured())
		failed <- server.ListenAndServe()
	}()
	select {
	case err = <-failed:
		if err != http.ErrServerClosed {
			return err
		}
		return nil
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		return server.Shutdown(shutdown)
	}
}
