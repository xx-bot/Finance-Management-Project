package auth

import (
	"bytes"
	"testing"

	"golang.org/x/crypto/bcrypt"
)

func TestPasswordsAndCredentials(t *testing.T) {
	email, err := Credentials("  Alex@Example.com ", "a-long-test-password")
	if err != nil || email != "alex@example.com" {
		t.Fatal(email, err)
	}
	for _, pair := range [][2]string{{"bad", "long-password"}, {"Alex <alex@example.com>", "long-password"}, {"a@example.com", "short"}} {
		if _, err := Credentials(pair[0], pair[1]); err == nil {
			t.Fatal("accepted invalid credentials")
		}
	}
	hash, err := HashPassword("a-long-test-password", bcrypt.MinCost)
	if err != nil {
		t.Fatal(err)
	}
	if !CheckPassword(hash, "a-long-test-password") || CheckPassword(hash, "a-different-password") {
		t.Fatal("password verification failed")
	}
	if bytes.Contains(hash, []byte("a-long-test-password")) {
		t.Fatal("stored plaintext password")
	}
}
func TestOpaqueSessions(t *testing.T) {
	a, err := Token()
	if err != nil {
		t.Fatal(err)
	}
	b, _ := Token()
	if a == b || len(a) != 43 || len(TokenHash(a)) != 32 {
		t.Fatal("invalid session token")
	}
	if bytes.Equal(TokenHash(a), TokenHash(b)) {
		t.Fatal("hash collision")
	}
	id, err := ID()
	if err != nil || len(id) != 36 {
		t.Fatal("invalid user ID")
	}
}
