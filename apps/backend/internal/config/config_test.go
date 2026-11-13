package config

import (
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestEnvironmentPrecedenceAndPasswordEncoding(t *testing.T) {
	env := filepath.Join(t.TempDir(), "config.env")
	if err := os.WriteFile(env, []byte("GEMINI_MODEL=file-model\n"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GEMINI_MODEL", "environment-model")
	t.Setenv("DATABASE_URL", "")
	t.Setenv("POSTGRES_PASSWORD", "a:@/ password")
	t.Setenv("POSTGRES_HOST", "db")
	c, err := Load(env)
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := url.Parse(c.DatabaseURL)
	if err != nil {
		t.Fatal(err)
	}
	password, _ := parsed.User.Password()
	if password != "a:@/ password" || parsed.Host != "db:5432" || c.GeminiModel != "environment-model" {
		t.Fatal("environment precedence or URL encoding failed")
	}
}
func TestInvalidConfiguration(t *testing.T) {
	env := filepath.Join(t.TempDir(), "empty.env")
	_ = os.WriteFile(env, nil, 0600)
	t.Setenv("DATABASE_URL", "postgres://unused/db")
	t.Setenv("SESSION_TTL", "wrong")
	_, err := Load(env)
	if err == nil || !strings.Contains(err.Error(), "SESSION_TTL") {
		t.Fatal("accepted invalid session TTL")
	}
}
