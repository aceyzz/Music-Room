package main

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"net"
	"strings"
	"time"

	pb "example.com/music-app/gen/go/music_room/v1"
	"github.com/joho/godotenv"

	// "github.com/redis/go-redis/v9"
	"golang.org/x/time/rate"
	"google.golang.org/grpc"
	"google.golang.org/grpc/reflection" // For debugging with grpcurl

	"github.com/jackc/pgx/v5/pgxpool"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"

	// 1. Import your root db package (holds MigrationsFS)
	"example.com/music-app/db"
	sqlc "example.com/music-app/db/sqlc"

	// 2. Import your sqlc package under an alias like 'sqlc' instead of 'db'
	"example.com/music-app/internal/config"
	"example.com/music-app/internal/loginattempt"
	"example.com/music-app/internal/mailer"
	"example.com/music-app/internal/media"
	"example.com/music-app/internal/ratelimit"
	"example.com/music-app/internal/session"
	"example.com/music-app/internal/token"

	"net/http"

	"example.com/music-app/internal/delegation"
	"example.com/music-app/internal/event"
	"example.com/music-app/internal/music_provider"
	"example.com/music-app/internal/playlist"
	"example.com/music-app/internal/realtime"
	"example.com/music-app/internal/services"
	"github.com/grpc-ecosystem/grpc-gateway/v2/runtime"
	"google.golang.org/grpc/credentials/insecure"

	// 3. Import your register package for the AuthServer
	"example.com/music-app/internal/apidocs"
	"example.com/music-app/internal/auth/authn"
	"example.com/music-app/internal/auth/emailverif"
	"example.com/music-app/internal/auth/login"
	"example.com/music-app/internal/auth/logout"
	"example.com/music-app/internal/auth/oauth"
	"example.com/music-app/internal/auth/onetimecode"
	"example.com/music-app/internal/auth/passwordreset"
	"example.com/music-app/internal/auth/register"
	"example.com/music-app/internal/authz"
	"example.com/music-app/internal/authz/outbox"
	"example.com/music-app/internal/interceptor"
	"example.com/music-app/internal/security"
	"example.com/music-app/internal/user"
)

// 2. Helper function to apply migrations on boot
func runMigrations(dbURL string) error {
	stdDb, err := sql.Open("pgx", dbURL)
	if err != nil {
		return fmt.Errorf("failed to open stdlib connection for goose: %w", err)
	}
	defer stdDb.Close()

	// Access MigrationsFS from the root 'db' package
	goose.SetBaseFS(db.MigrationsFS)

	if err := goose.SetDialect("postgres"); err != nil {
		return fmt.Errorf("failed to set goose dialect: %w", err)
	}

	log.Println("Checking for pending database migrations...")
	if err := goose.Up(stdDb, "schema"); err != nil {
		return fmt.Errorf("goose migration failed: %w", err)
	}

	log.Println("Database schema is up to date!")
	return nil
}

func main() {
	loadDotenv()
	ctx := context.Background()
	dbURL := config.Getenv("APP_DATABASE_URL", "")
	if dbURL == "" {
		log.Fatal("APP_DATABASE_URL manquant")
	}
	grpcAddr := config.Getenv("APP_GRPC_ADDR", ":50051")
	httpAddr := config.Getenv("APP_HTTP_ADDR", ":8080")
	// redisAddr := config.Getenv("APP_REDIS_ADDR", "localhost:6379")
	// redisDB := config.Getenv("APP_REDIS_DB", 0)

	if err := runMigrations(dbURL); err != nil {
		log.Fatalf("Migration step failed: %v", err)
	}

	pool, err := pgxpool.New(ctx, dbURL)
	if err != nil {
		log.Fatalf("Unable to connect to database: %v\n", err)
	}
	defer pool.Close()

	if err := pool.Ping(ctx); err != nil {
		log.Fatalf("Database ping failed: %v\n", err)
	}

	// OpenFGA. Le boot échoue si le store est injoignable ou vide : une écriture
	// de tuple qui part dans le vide ne se voit pas, et le premier symptôme
	// serait une permission refusée sans raison, longtemps après.
	fgaClient, err := authz.NewClient(authz.Config{
		APIURL:  config.Getenv("APP_OPENFGA_API_URL", "http://localhost:8082"),
		StoreID: config.Getenv("APP_OPENFGA_STORE_ID", "01MRAVTHZ00000000000000000"),
		ModelID: config.Getenv("APP_OPENFGA_MODEL_ID", ""),
	})
	if err != nil {
		log.Fatalf("OpenFGA client: %v", err)
	}
	modelID, err := fgaClient.Ping(ctx)
	if err != nil {
		log.Fatalf("OpenFGA: %v", err)
	}
	log.Printf("OpenFGA ready, pinned authorization model %s", modelID)

	tupleOutbox := outbox.New(fgaClient)
	outbox.LogBacklog(ctx, pool)

	// Assemblage de la chaîne auth : repository -> service -> handler.
	userRepo := user.NewRepository(pool, tupleOutbox)
	hasher := security.NewArgon2Hasher()
	minPasswordLen := config.Getenv("APP_MIN_PASSWORD_LENGTH", register.DefaultMinPasswordLen)
	registerSvc := register.NewService(userRepo, hasher, minPasswordLen)

	sessionRepo := session.NewRepository(pool)
	tokenGen := security.NewSessionTokenGenerator()
	sessionTTLDays := config.Getenv("APP_SESSION_TTL_DAYS", 30)
	loginAttemptRepo := loginattempt.NewRepository(pool)
	loginSvc := login.NewService(userRepo, sessionRepo, hasher, tokenGen, loginAttemptRepo,
		time.Duration(sessionTTLDays)*24*time.Hour)
	logoutSvc := logout.NewService(sessionRepo, tokenGen)
	tokenRepo := token.NewRepository(pool)
	codeTTLMinutes := config.Getenv("APP_EMAIL_CODE_TTL_MINUTES", 15)
	codeMaxAttempts := config.Getenv("APP_CODE_MAX_ATTEMPTS", onetimecode.DefaultMaxAttempts)
	codes := onetimecode.NewService(tokenRepo, tokenGen,
		time.Duration(codeTTLMinutes)*time.Minute, codeMaxAttempts)
	mail := buildMailer()
	emailVerifSvc := emailverif.NewService(codes, tokenRepo, mail)
	oauthSvc := oauth.NewService(
		buildOAuthRegistry(),
		userRepo, sessionRepo, tokenGen,
		time.Duration(sessionTTLDays)*24*time.Hour,
	)

	// redisClient := redis.NewClient(&redis.Options{
	// 	Addr: redisAddr,
	// 	DB:   redisDB,
	// })
	// defer redisClient.Close()

	// if err := pingRedis(ctx, redisClient); err != nil {
	// 	log.Fatalf("Redis ping failed: %v", err)
	// }

	// Reprend les changements de tuples dont la tentative synchrone a échoué, et
	// ceux dont le processus est mort avant de la faire. Sans lui, l'outbox
	// garantit qu'aucun changement n'est perdu mais rien ne les rattrape jamais.
	workerCtx, stopWorker := context.WithCancel(ctx)
	defer stopWorker()
	go outbox.NewWorker(tupleOutbox, pool, outbox.WorkerConfig{
		Interval:  time.Duration(config.Getenv("APP_OPENFGA_SYNC_INTERVAL_SECONDS", 15)) * time.Second,
		BatchSize: int32(config.Getenv("APP_OPENFGA_SYNC_BATCH", 20)),
	}).Run(workerCtx)

	lis, err := net.Listen("tcp", grpcAddr)
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}

	// L'intercepteur de permissions : authentification puis autorisation, pour
	// chaque RPC, avant le handler. La table de politique
	// (internal/interceptor/policy.go) refuse par defaut -- une RPC absente est
	// refusee, avec un log qui la nomme.
	//
	// Il est monte ici, sur le serveur gRPC, et couvre donc aussi la passerelle
	// REST : grpc-gateway rappelle ce meme port en loopback et reexpedie le
	// header Authorization. Les streams Watch* passent par lui aussi
	// (interceptor.Stream).
	sessionIdleDays := config.Getenv("APP_SESSION_IDLE_DAYS", 7)
	authenticator := authn.NewAuthenticator(sessionRepo, tokenGen,
		time.Duration(sessionIdleDays)*24*time.Hour)
	permissions := interceptor.New(authenticator, fgaClient, interceptor.NewResolver(pool), sqlc.New(pool))
	// Every call from one IP address, gRPC or REST: APP_RATE_LIMIT_RPS a
	// second on average, twice that in a burst; 0 turns it off (the load test,
	// whose k6 sends everything from one address).
	if perSecond := config.Getenv("APP_RATE_LIMIT_RPS", 100); perSecond > 0 {
		permissions.LimitPerIP(ratelimit.New(rate.Limit(perSecond), 2*perSecond))
	}

	// Sans MaxRecvMsgSize, gRPC-Go refuse tout message de plus de 4 Mio avec
	// RESOURCE_EXHAUSTED, avant le handler : un avatar de 4,5 Mio, accepté par
	// validAvatarUpload, n'y arrivait jamais. Le Mio de marge couvre le reste
	// de la requête (voir media.MaxUploadBytes).
	grpcServer := grpc.NewServer(
		grpc.MaxRecvMsgSize(media.MaxUploadBytes+1<<20),
		grpc.UnaryInterceptor(permissions.Unary()),
		grpc.StreamInterceptor(permissions.Stream()),
	)
	// Register reflection service on gRPC server.
	// This allows debugging tools like grpcurl.
	reflection.Register(grpcServer)

	// Create a DeezerClient instance
	deezerClient := music_provider.NewDeezerClient()
	pb.RegisterMusicProviderServiceServer(grpcServer, music_provider.NewService(deezerClient))

	// image-service client + local file storage, shared by every service that
	// stores an image (UserService avatars, PlaylistService covers).
	mediaStore, err := media.NewStore(config.Getenv("APP_IMAGE_STORAGE_DIR", "data/images"))
	if err != nil {
		log.Fatalf("could not create image storage directory: %v", err)
	}
	mediaClient := media.NewClient(config.Getenv("APP_IMAGE_SERVICE_URL", "http://localhost:8080"))

	// Un repository par service qui écrit des permissions : c'est lui qui ouvre
	// la transaction, donc c'est lui qui porte l'outbox. Voir
	// docs/authz-sync-guide.md -- passer le pool à Enqueue au lieu de la
	// transaction compile et vide le pattern de sa garantie.
	// Réveille les streams Watch* ouverts après chaque écriture
	// (internal/realtime). En mémoire : un seul processus backend.
	liveUpdates := realtime.NewHub()

	playlistRepo := playlist.NewRepository(pool, tupleOutbox)
	eventRepo := event.NewRepository(pool, tupleOutbox)
	delegationRepo := delegation.NewRepository(pool, tupleOutbox)

	// Create a PlaylistService instance
	pb.RegisterPlaylistServiceServer(grpcServer, playlist.NewService(pool, playlistRepo, deezerClient, mediaClient, mediaStore, fgaClient, liveUpdates))

	// Create an EventService instance (Music Track Vote / live playlist)
	eventSvc := event.NewService(pool, eventRepo, deezerClient, fgaClient, liveUpdates)
	// Events past their planned end are ended by the server, once now --
	// before re-arming, so an event that is over is not restarted -- then
	// every 10 s, so one past its end stops as soon as its music does.
	if ended, err := eventSvc.EndOverdueEvents(ctx); err != nil {
		log.Printf("event: could not end overdue events: %v", err)
	} else {
		log.Printf("event: ended %d event(s) past their planned end", ended)
	}
	go eventSvc.RunEventEnder(ctx, 10*time.Second)
	// The sound comes from the host's phone: pause when they leave the page.
	go eventSvc.RunSpeakerCheck(ctx, 2*time.Second)
	// The auto-advance timers live in memory: arm again those a restart lost.
	if rearmed, err := eventSvc.RearmAutoAdvance(ctx); err != nil {
		log.Printf("event: could not re-arm the auto-advance timers: %v", err)
	} else {
		log.Printf("event: re-armed the auto-advance timer of %d playing event(s)", rearmed)
	}
	pb.RegisterEventServiceServer(grpcServer, eventSvc)

	// Create a DelegationService instance (Music Control Delegation)
	pb.RegisterDelegationServiceServer(grpcServer, delegation.NewService(pool, delegationRepo, liveUpdates))

	// Create an AuthServer instance
	passwordResetSvc := passwordreset.NewService(userRepo, codes, hasher, mail, minPasswordLen)
	authServer := services.NewAuthServer(registerSvc, loginSvc, logoutSvc, emailVerifSvc, oauthSvc, passwordResetSvc)
	pb.RegisterAuthServiceServer(grpcServer, authServer)

	// Create a UserService instance (profile, music preferences, friends, avatar)
	// Même userRepo que l'inscription : le profil, l'avatar et le graphe social
	// écrivent tous des tuples sur l'objet `user`.
	pb.RegisterUserServiceServer(grpcServer, user.NewService(pool, userRepo, mediaClient, mediaStore))

	go func() {
		log.Printf("gRPC server listening on %s", grpcAddr)
		if err := grpcServer.Serve(lis); err != nil {
			log.Fatalf("failed to serve gRPC: %v", err)
		}
	}()

	// 2. Setup gRPC-Gateway multiplexer
	//
	// Activity logging reads x-platform/x-device-model/x-app-version
	// from the incoming gRPC metadata (internal/interceptor/activitylog.go),
	// and grpc-gateway's DefaultHeaderMatcher would silently drop all three:
	// it only forwards IANA-permanent HTTP headers and ones prefixed
	// Grpc-Metadata-, never an arbitrary custom header. Without this, the
	// mobile app's headers would never reach the interceptor at all.
	gwmux := runtime.NewServeMux(runtime.WithIncomingHeaderMatcher(activityHeaderMatcher))
	opts := []grpc.DialOption{grpc.WithTransportCredentials(insecure.NewCredentials())}

	if err := pb.RegisterMusicProviderServiceHandlerFromEndpoint(ctx, gwmux, grpcAddr, opts); err != nil {
		log.Fatalf("Failed to register gRPC-Gateway endpoint: %v", err)
	}
	if err := pb.RegisterPlaylistServiceHandlerFromEndpoint(ctx, gwmux, grpcAddr, opts); err != nil {
		log.Fatalf("Failed to register gRPC-Gateway endpoint: %v", err)
	}
	if err := pb.RegisterEventServiceHandlerFromEndpoint(ctx, gwmux, grpcAddr, opts); err != nil {
		log.Fatalf("Failed to register gRPC-Gateway endpoint: %v", err)
	}
	if err := pb.RegisterDelegationServiceHandlerFromEndpoint(ctx, gwmux, grpcAddr, opts); err != nil {
		log.Fatalf("Failed to register gRPC-Gateway endpoint: %v", err)
	}
	if err := pb.RegisterUserServiceHandlerFromEndpoint(ctx, gwmux, grpcAddr, opts); err != nil {
		log.Fatalf("Failed to register gRPC-Gateway endpoint: %v", err)
	}
	if err := pb.RegisterAuthServiceHandlerFromEndpoint(ctx, gwmux, grpcAddr, opts); err != nil {
		log.Fatalf("Failed to register gRPC-Gateway endpoint: %v", err)
	}

	// 3. Create top-level HTTP router around the Gateway
	topMux := http.NewServeMux()
	// Swagger UI + le spec OpenAPI lui-même, générés par
	// buf depuis les mêmes .proto que le reste de l'API -- voir
	// internal/apidocs.
	topMux.Handle("/docs/", http.StripPrefix("/docs", apidocs.Handler()))
	// Serves files written by UploadAvatar/SetPlaylistCover: images.storage_key
	// is the path relative to mediaStore's directory, so /media/<storage_key>
	// resolves straight to the file on disk.
	topMux.Handle("/media/", http.StripPrefix("/media/", media.FileHandler(mediaStore.Dir())))
	// Rebond OAuth : les providers redirigent ici, la page renvoie le code vers
	// le schema de l'app (voir internal/auth/oauth/callback.go).
	oauthCallback, err := oauth.NewCallbackHandler(config.Getenv("APP_OAUTH_APP_CALLBACK", "musicroom://oauth"))
	if err != nil {
		log.Fatalf("OAuth callback: %v", err)
	}
	topMux.Handle(oauth.CallbackPath, oauthCallback)
	topMux.Handle("/", gwmux) // gRPC-Gateway REST routes

	log.Printf("HTTP Gateway listening on %s", httpAddr)
	if err := http.ListenAndServe(httpAddr, topMux); err != nil {
		log.Fatalf("failed to serve HTTP: %v", err)
	}
}

// func pingRedis(ctx context.Context, client *redis.Client) error {
// 	pingCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
// 	defer cancel()

// 	if err := client.Ping(pingCtx).Err(); err != nil {
// 		return fmt.Errorf("unable to ping redis: %w", err)
// 	}

// 	return nil
// }

// buildMailer choisit l'implementation selon APP_MAILER.
// "log" par defaut : aucune config requise pour lancer le projet.
func buildMailer() mailer.Mailer {
	if config.Getenv("APP_MAILER", "log") != "smtp" {
		log.Println("Mailer: log (les emails sont ecrits dans les logs)")
		return mailer.NewLogMailer()
	}

	m, err := mailer.NewSMTPMailer(mailer.SMTPConfig{
		Host:     config.Getenv("APP_SMTP_HOST", ""),
		Port:     config.Getenv("APP_SMTP_PORT", 587),
		Username: config.Getenv("APP_SMTP_USERNAME", ""),
		Password: config.Getenv("APP_SMTP_PASSWORD", ""),
		From:     config.Getenv("APP_SMTP_FROM", ""),
	})
	if err != nil {
		// smtp demande mais config incomplete : on refuse de demarrer plutot
		// que de retomber silencieusement sur les logs.
		log.Fatalf("APP_MAILER=smtp mais la config est incomplete: %v", err)
	}

	log.Println("Mailer: smtp")
	return m
}

// buildOAuthRegistry n'enregistre que les providers configures.
// un constructeur renvoie nil sans identifiants : on l'ecarte plutot que
// d'echouer au premier appel.
func buildOAuthRegistry() oauth.Registry {
	var configured []oauth.Provider

	if p := oauth.NewGoogleProvider(
		config.Getenv("APP_OAUTH_GOOGLE_CLIENT_ID", ""),
		config.Getenv("APP_OAUTH_GOOGLE_CLIENT_SECRET", ""),
	); p != nil {
		configured = append(configured, p)
	}

	if p := oauth.NewFacebookProvider(
		config.Getenv("APP_OAUTH_FACEBOOK_CLIENT_ID", ""),
		config.Getenv("APP_OAUTH_FACEBOOK_CLIENT_SECRET", ""),
	); p != nil {
		configured = append(configured, p)
	}

	if p := oauth.NewIntra42Provider(
		config.Getenv("APP_OAUTH_INTRA42_CLIENT_ID", ""),
		config.Getenv("APP_OAUTH_INTRA42_CLIENT_SECRET", ""),
	); p != nil {
		configured = append(configured, p)
	}

	names := make([]string, 0, len(configured))
	for _, p := range configured {
		names = append(names, p.Name())
	}
	log.Printf("OAuth providers: %v", names)

	return oauth.NewRegistry(configured...)
}

// activityHeaderMatcher forwards the three V.6 activity-log headers as gRPC
// metadata, on top of grpc-gateway's own defaults (Authorization and the
// other IANA-permanent headers, still handled by DefaultHeaderMatcher).
func activityHeaderMatcher(key string) (string, bool) {
	switch strings.ToLower(key) {
	case "x-platform", "x-device-model", "x-app-version":
		return strings.ToLower(key), true
	default:
		return runtime.DefaultHeaderMatcher(key)
	}
}

func loadDotenv() {
	for _, path := range []string{".env", "../.env"} {
		if err := godotenv.Load(path); err == nil {
			log.Printf("Config chargee depuis %s", path)
			return
		}
	}
	log.Println("Pas de .env : variables d'environnement uniquement")
}
