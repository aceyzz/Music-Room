package mailer

import (
	"context"
	"log"
)

// LogMailer ecrit le mail dans les logs au lieu de l'envoyer.
// defaut en dev : aucune config, et le code de verification est lisible
// dans docker compose logs.
type LogMailer struct{}

func NewLogMailer() LogMailer {
	return LogMailer{}
}

func (LogMailer) Send(ctx context.Context, m Mail) error {
	log.Printf("[mailer:log] to=%s subject=%q\n%s", m.To, m.Subject, m.Body)
	return nil
}
