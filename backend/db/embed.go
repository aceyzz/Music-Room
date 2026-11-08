package db

import "embed"

// Embed all SQL migration scripts in db/schema
//
//go:embed schema/*.sql
var MigrationsFS embed.FS
