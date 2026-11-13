// Package config loads server settings without printing credentials.
package config

import (
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/joho/godotenv"
)

type Config struct {
	Address, DatabaseURL, GeminiKey, GeminiModel string
	SessionTTL, ExtractionTimeout                time.Duration
	AllowRegistration                            bool
	MaxOutputTokens, ExtractionConcurrency       int
}

// Load never overwrites environment variables supplied by Docker or the shell.
func Load(envFile string) (Config, error) {
	if envFile != "" {
		if err := godotenv.Load(envFile); err != nil {
			return Config{}, fmt.Errorf("could not read or parse the specified env file")
		}
	} else {
		cwd, _ := os.Getwd()
		for dir := cwd; ; dir = filepath.Dir(dir) {
			if _, err := os.Stat(filepath.Join(dir, ".env")); err == nil {
				if err = godotenv.Load(filepath.Join(dir, ".env")); err != nil {
					return Config{}, fmt.Errorf("could not parse the project env file")
				}
				break
			}
			if filepath.Dir(dir) == dir {
				break
			}
		}
	}
	c := Config{Address: value("HTTP_ADDR", ":8080"), DatabaseURL: os.Getenv("DATABASE_URL"),
		GeminiKey: strings.TrimSpace(os.Getenv("GEMINI_API_KEY")), GeminiModel: value("GEMINI_MODEL", "gemini-3.5-flash-lite")}
	if c.GeminiKey == "your_gemini_api_key_here" {
		c.GeminiKey = ""
	}
	if c.DatabaseURL == "" {
		password := os.Getenv("POSTGRES_PASSWORD")
		if password == "" {
			return c, fmt.Errorf("set DATABASE_URL or POSTGRES_PASSWORD")
		}
		u := url.URL{Scheme: "postgres", Host: value("POSTGRES_HOST", "localhost") + ":" + value("POSTGRES_PORT", "5432"),
			User: url.UserPassword(value("POSTGRES_USER", "pocket"), password), Path: "/" + value("POSTGRES_DB", "pocket_ledger")}
		q := u.Query()
		q.Set("sslmode", value("POSTGRES_SSLMODE", "disable"))
		u.RawQuery = q.Encode()
		c.DatabaseURL = u.String()
	}
	var err error
	if c.SessionTTL, err = time.ParseDuration(value("SESSION_TTL", "720h")); err != nil || c.SessionTTL < time.Hour || c.SessionTTL > 90*24*time.Hour {
		return c, fmt.Errorf("SESSION_TTL must be between 1h and 2160h")
	}
	if c.ExtractionTimeout, err = time.ParseDuration(value("EXTRACTION_TIMEOUT", "90s")); err != nil || c.ExtractionTimeout < time.Second || c.ExtractionTimeout > 110*time.Second {
		return c, fmt.Errorf("EXTRACTION_TIMEOUT must be between 1s and 110s")
	}
	if c.AllowRegistration, err = strconv.ParseBool(value("ALLOW_REGISTRATION", "true")); err != nil {
		return c, fmt.Errorf("ALLOW_REGISTRATION must be true or false")
	}
	if c.MaxOutputTokens, err = strconv.Atoi(value("GEMINI_MAX_OUTPUT_TOKENS", "4096")); err != nil || c.MaxOutputTokens < 128 || c.MaxOutputTokens > 32768 {
		return c, fmt.Errorf("GEMINI_MAX_OUTPUT_TOKENS must be between 128 and 32768")
	}
	if c.ExtractionConcurrency, err = strconv.Atoi(value("EXTRACTION_CONCURRENCY", "2")); err != nil || c.ExtractionConcurrency < 1 || c.ExtractionConcurrency > 16 {
		return c, fmt.Errorf("EXTRACTION_CONCURRENCY must be between 1 and 16")
	}
	return c, nil
}

func value(key, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return fallback
}
