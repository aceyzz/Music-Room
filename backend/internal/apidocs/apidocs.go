// Package apidocs sert la spécification OpenAPI (générée par buf depuis les
// mêmes .proto que le reste de l'API, jamais réécrite à la main -- voir
// buf.gen.yaml) et une page Swagger UI qui la lit, directement depuis le
// backend (docs/todo.md §7 : "Serve OpenAPI/Swagger UI from Backend").
//
// api_spec.swagger.json est généré, pas commité (.gitignore) : `buf generate`
// (ou `make buf-rebuild`) doit avoir tourné avant `go build`, exactement
// comme pour gen/go -- go:embed échoue à la compilation si le fichier
// n'existe pas encore, ce qui est le comportement voulu (un spec périmé ou
// absent doit casser le build, pas être servi silencieusement).
package apidocs

import (
	_ "embed"
	"net/http"
)

//go:embed api_spec.swagger.json
var openapiSpec []byte

// swaggerUIPage charge swagger-ui-dist depuis un CDN plutôt que de
// l'embarquer : ~150 fichiers pour quelques Mo, pour un outil de
// développement/démo qui n'a pas besoin de fonctionner hors-ligne.
const swaggerUIPage = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Music Room API</title>
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui.css">
</head>
<body>
  <div id="swagger-ui"></div>
  <script src="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
  <script>
    window.onload = () => SwaggerUIBundle({
      url: "openapi.json",
      dom_id: "#swagger-ui",
    });
  </script>
</body>
</html>`

// Handler sert la page Swagger UI à sa racine et le spec JSON à
// openapi.json -- pensé pour être monté sous un préfixe (voir cmd/main.go),
// d'où les chemins relatifs plutôt qu'absolus dans swaggerUIPage.
func Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/openapi.json", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write(openapiSpec)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write([]byte(swaggerUIPage))
	})
	return mux
}
