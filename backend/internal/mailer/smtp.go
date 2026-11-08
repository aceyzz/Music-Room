package mailer

import (
	"context"
	"errors"
	"fmt"
	"net/smtp"
	"strings"
)

var ErrIncompleteConfig = errors.New("smtp config incomplete")

// SMTPConfig : identifiants lus depuis l'env
type SMTPConfig struct {
	Host     string
	Port     int
	Username string
	Password string
	From     string
}

type SMTPMailer struct {
	cfg  SMTPConfig
	auth smtp.Auth
}

// NewSMTPMailer refuse une config incomplete plutot que d'echouer
// silencieusement au premier envoi
func NewSMTPMailer(cfg SMTPConfig) (*SMTPMailer, error) {
	if cfg.Host == "" || cfg.Port == 0 || cfg.From == "" {
		return nil, ErrIncompleteConfig
	}

	return &SMTPMailer{
		cfg:  cfg,
		auth: smtp.PlainAuth("", cfg.Username, cfg.Password, cfg.Host),
	}, nil
}

func (m *SMTPMailer) Send(ctx context.Context, mail Mail) error {
	addr := fmt.Sprintf("%s:%d", m.cfg.Host, m.cfg.Port)

	if err := smtp.SendMail(addr, m.auth, m.cfg.From, []string{mail.To}, buildMessage(m.cfg.From, mail)); err != nil {
		// l'erreur smtp peut contenir la config : on ne la remonte pas telle quelle.
		return fmt.Errorf("smtp send failed: %w", err)
	}
	return nil
}

// buildMessage assemble les entetes et le corps
// les sauts de ligne sont retires des entetes : sans ca, un \n dans une
// adresse permet d'injecter des entetes arbitraires (header injection)
func buildMessage(from string, mail Mail) []byte {
	var b strings.Builder

	fmt.Fprintf(&b, "From: %s\r\n", sanitizeHeader(from))
	fmt.Fprintf(&b, "To: %s\r\n", sanitizeHeader(mail.To))
	fmt.Fprintf(&b, "Subject: %s\r\n", sanitizeHeader(mail.Subject))
	b.WriteString("MIME-Version: 1.0\r\n")
	b.WriteString("Content-Type: text/plain; charset=UTF-8\r\n")
	b.WriteString("\r\n")
	b.WriteString(mail.Body)

	return []byte(b.String())
}

func sanitizeHeader(v string) string {
	return strings.NewReplacer("\r", "", "\n", "").Replace(v)
}
