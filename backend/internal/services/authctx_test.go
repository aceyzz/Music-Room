package services

import (
	"context"
	"testing"

	"google.golang.org/grpc/metadata"
)

func ctxWithAuth(value string) context.Context {
	return metadata.NewIncomingContext(
		context.Background(),
		metadata.Pairs("authorization", value),
	)
}

func TestBearerTokenExtracts(t *testing.T) {
	got, err := bearerToken(ctxWithAuth("Bearer abc123"))
	if err != nil {
		t.Fatalf("bearerToken: %v", err)
	}
	if got != "abc123" {
		t.Fatalf("token = %q", got)
	}
}

func TestBearerTokenIsCaseInsensitive(t *testing.T) {
	got, err := bearerToken(ctxWithAuth("bearer abc123"))
	if err != nil {
		t.Fatalf("bearerToken: %v", err)
	}
	if got != "abc123" {
		t.Fatalf("token = %q", got)
	}
}

func TestBearerTokenRejectsMalformed(t *testing.T) {
	cases := []struct {
		name string
		ctx  context.Context
	}{
		{"pas de metadata", context.Background()},
		{"header absent", metadata.NewIncomingContext(context.Background(), metadata.Pairs("x", "y"))},
		{"sans prefixe", ctxWithAuth("abc123")},
		{"prefixe seul", ctxWithAuth("Bearer ")},
		{"vide", ctxWithAuth("")},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := bearerToken(tc.ctx); err == nil {
				t.Fatal("attendu une erreur")
			}
		})
	}
}
