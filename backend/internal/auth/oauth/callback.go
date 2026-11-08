package oauth

import (
	"fmt"
	"html"
	"net/http"
	"net/url"
)

// CallbackPath : l'URL de redirection a declarer chez chaque provider est
// <adresse publique du backend> + CallbackPath.
const CallbackPath = "/oauth/callback"

// champs du retour provider que l'on transmet a l'app. tout le reste est
// ignore : l'app n'a besoin que du code (ou de la raison de l'echec) et du
// state qu'elle a elle-meme genere.
var forwardedParams = []string{"code", "state", "error", "error_description"}

// limite par valeur : un code ou un state font quelques centaines d'octets,
// rien de legitime n'approche cette taille.
const maxParamLen = 2048

// NewCallbackHandler renvoie la page de rebond du flux OAuth de l'app.
//
// pourquoi un rebond : google et facebook n'acceptent, pour un client qui a
// un secret (le notre, puisque l'echange du code se fait ici), que des URL de
// redirection http(s). l'app, elle, ne sait recevoir que son schema a elle
// (musicroom://...). le provider redirige donc ici, et on renvoie aussitot le
// navigateur vers appCallback avec le code : flutter_web_auth_2 l'intercepte,
// et l'app appelle OAuthLogin avec ce code et CETTE URL comme redirect_uri.
//
// pas d'echange de code ici, pas d'etat, pas de cookie : la page ne fait que
// recopier des parametres vers une destination fixe (appCallback vient de la
// config, jamais de la requete), donc pas de redirection ouverte possible.
func NewCallbackHandler(appCallback string) (http.Handler, error) {
	target, err := url.Parse(appCallback)
	if err != nil || target.Scheme == "" {
		return nil, fmt.Errorf("oauth: callback de l'app invalide %q (attendu: schema://chemin)", appCallback)
	}

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			w.Header().Set("Allow", http.MethodGet)
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		in := r.URL.Query()
		out := url.Values{}
		for _, key := range forwardedParams {
			if v := in.Get(key); v != "" {
				if len(v) > maxParamLen {
					http.Error(w, "parameter too long", http.StatusBadRequest)
					return
				}
				out.Set(key, v)
			}
		}
		// ni code ni erreur : ce n'est pas un retour de provider.
		if out.Get("code") == "" && out.Get("error") == "" {
			http.Error(w, "missing code", http.StatusBadRequest)
			return
		}

		dest := *target
		dest.RawQuery = out.Encode()
		location := dest.String()

		// le code est un secret a usage unique : ni cache, ni fuite via Referer.
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Location", location)
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.WriteHeader(http.StatusFound)
		// filet de securite si le navigateur ne suit pas une redirection vers
		// un schema non http : un lien a toucher.
		fmt.Fprintf(w, `<!doctype html><meta charset="utf-8"><title>Music Room</title>`+
			`<p><a href="%s">Return to Music Room</a></p>`, html.EscapeString(location))
	}), nil
}
