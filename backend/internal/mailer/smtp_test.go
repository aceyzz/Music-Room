package mailer

import (
	"context"
	"errors"
	"strings"
	"testing"
)

func validConfig() SMTPConfig {
	return SMTPConfig{
		Host:     "smtp.example.com",
		Port:     587,
		Username: "user@example.com",
		Password: "secret",
		From:     "noreply@example.com",
	}
}

func TestNewSMTPMailerRejectsIncompleteConfig(t *testing.T) {
	noHost := validConfig()
	noHost.Host = ""

	noPort := validConfig()
	noPort.Port = 0

	noFrom := validConfig()
	noFrom.From = ""

	cases := []struct {
		name string
		cfg  SMTPConfig
	}{
		{"sans host", noHost},
		{"sans port", noPort},
		{"sans from", noFrom},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := NewSMTPMailer(tc.cfg); !errors.Is(err, ErrIncompleteConfig) {
				t.Fatalf("attendu ErrIncompleteConfig, got %v", err)
			}
		})
	}
}

func TestNewSMTPMailerAcceptsValidConfig(t *testing.T) {
	if _, err := NewSMTPMailer(validConfig()); err != nil {
		t.Fatalf("une config complete doit passer, got %v", err)
	}
}

func TestBuildMessageHasHeadersAndBody(t *testing.T) {
	got := string(buildMessage("noreply@example.com", Mail{
		To:      "neo@matrix.io",
		Subject: "Ton code",
		Body:    "123456",
	}))

	for _, want := range []string{
		"From: noreply@example.com\r\n",
		"To: neo@matrix.io\r\n",
		"Subject: Ton code\r\n",
		"Content-Type: text/plain; charset=UTF-8\r\n",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("entete manquante: %q", want)
		}
	}

	// une ligne vide separe les entetes du corps
	if !strings.HasSuffix(got, "\r\n\r\n123456") {
		t.Errorf("corps mal separe des entetes:\n%q", got)
	}
}

func TestBuildMessageBlocksHeaderInjection(t *testing.T) {
	// un \r\n dans une entete permettrait d'en ajouter d'autres
	got := string(buildMessage("noreply@example.com", Mail{
		To:      "neo@matrix.io\r\nBcc: attaquant@evil.io",
		Subject: "Salut\r\nX-Injecte: oui",
		Body:    "corps",
	}))

	headers, _, found := strings.Cut(got, "\r\n\r\n")
	if !found {
		t.Fatal("message sans separation entetes/corps")
	}

	// le texte injecte peut rester dans la valeur, ce qui est inoffensif.
	// ce qui compte : il ne doit pas debuter une ligne.
	for _, line := range strings.Split(headers, "\r\n") {
		if strings.HasPrefix(line, "Bcc:") {
			t.Errorf("entete Bcc injectee: %q", line)
		}
		if strings.HasPrefix(line, "X-Injecte:") {
			t.Errorf("entete X-Injecte injectee: %q", line)
		}
	}
}

func TestLogMailerNeverFails(t *testing.T) {
	if err := NewLogMailer().Send(context.Background(), Mail{To: "x", Subject: "y", Body: "z"}); err != nil {
		t.Fatalf("le log mailer ne doit jamais echouer, got %v", err)
	}
}
