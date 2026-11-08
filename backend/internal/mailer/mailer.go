// package mailer : envoi d'emails.
// deux implementations : log (dev, defaut) et smtp.
package mailer

import "context"

// Mail : un message a envoyer.
type Mail struct {
	To      string
	Subject string
	Body    string
}

// Mailer : le contrat. les appelants ne savent pas comment c'est envoye.
type Mailer interface {
	Send(ctx context.Context, m Mail) error
}
