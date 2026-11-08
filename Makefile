-include .env

# ==============================================================================
# Variables
# ==============================================================================
BACKEND_DIR  ?= backend
FRONTEND_DIR ?= frontend/app
MACOS_DIR    := $(FRONTEND_DIR)/macos
IOS_DIR      := $(FRONTEND_DIR)/ios
MACOS_LOCAL_CONFIG := $(MACOS_DIR)/Runner/Configs/Local.xcconfig
IOS_LOCAL_CONFIG   := $(IOS_DIR)/Flutter/Local.xcconfig

BUILD_DIR    ?= $(BACKEND_DIR)/bin
APP_NAME     ?= app-backend
MAIN_FILE    ?= cmd/main.go

SWAGGER_PATH ?= $(FRONTEND_DIR)/lib/gen/api_spec.swagger.json
OPENAPI_OUT  ?= $(FRONTEND_DIR)/lib/gen/openapi_client
PUB_NAME     ?= openapi_client

API_TESTS_DIR  ?= tests
API_TESTS_VENV ?= $(API_TESTS_DIR)/.venv

# Containerised Go toolchain. No Go is assumed on the host.
#
# The repository ROOT is mounted, not backend/: internal/authz's tests read
# authz/model.fga, which lives above it. Two named volumes keep the module
# cache and the build cache between runs -- without them every invocation
# re-downloads the dependency tree.
GO_IMAGE      ?= golang:1.25-alpine
GO_MOD_VOLUME ?= music-room-gomod
GO_BUILD_CACHE ?= music-room-gobuild
DOCKER_GO = docker run --rm \
	-v "$(CURDIR):/work" \
	-v $(GO_MOD_VOLUME):/go/pkg/mod \
	-v $(GO_BUILD_CACHE):/root/.cache/go-build \
	-w /work/$(BACKEND_DIR) $(GO_IMAGE)

# The same, joined to the compose network so a test can reach the services by
# their container names.
DOCKER_GO_NET = docker run --rm \
	--network music-room_default \
	-v "$(CURDIR):/work" \
	-v $(GO_MOD_VOLUME):/go/pkg/mod \
	-v $(GO_BUILD_CACHE):/root/.cache/go-build \
	-e APP_DATABASE_URL=postgres://postgres:$(POSTGRES_PASSWORD)@postgres:5432/music_room?sslmode=disable \
	-e APP_OPENFGA_API_URL=http://openfga:8080 \
	-w /work/$(BACKEND_DIR) $(GO_IMAGE)

FGA_STORE_ID ?= 01MRAVTHZ00000000000000000
## Pinned, in step with docker-compose.yaml: the backend matches one of the
## server's error messages (conflictMarker in internal/authz/client.go) and the
## check-cache flags it enables are version-specific, so `latest` would let
## either change under a measured result.
FGA_IMAGE     := openfga/openfga:v1.18.3
FGA_CLI_IMAGE := openfga/cli:v0.7.20

# ==============================================================================
# Targets
# ==============================================================================

.PHONY: all help clean fclean re backend frontend frontend-second frontend-linux emulator-setup tools doctor \
		eval-check eval apk android phone phone-2 phone-build phone-build-lean phone-stop wait-backend seed-once \
        backend-build backend-test backend-test-coverage backend-lint tidy \
	buf-dep buf-lint buf-format buf-generate buf-breaking buf-clean buf-rebuild \
	sqlc-generate sqlc-clean sqlc-rebuild \
        generate-openapi build-runner build-runner-clean rebuild-runner generate \
		setup-local-configs provision-macos provision-ios provision-all run-macos run-ios \
		api-test-up api-test-down api-test-deps api-test \
		seed seed-reset seed-local seed-doc \
		docker-backend-build docker-backend-test docker-backend-test-integration \
		docker-backend-lint docker-generate openfga fga-validate fga-model \
		activity-logs

## The whole stack, both phones included (their services sit behind profiles).
COMPOSE := docker compose --profile phone --profile phone2

## Under this many GB free for Docker (an evaluation machine has 5-10), `make`
## builds the images one at a time and drops the build cache after each, so
## only the final images stay. Above it the cache stays: a rebuild takes seconds.
LOW_DISK_GB ?= 20

## Tools the host-side generation (buf-rebuild, sqlc-rebuild) runs.
CODEGEN_TOOLS := buf sqlc protoc-gen-go protoc-gen-go-grpc protoc-gen-grpc-gateway \
	protoc-gen-openapiv2 protoc-gen-dart

## Default target: generate the code on the host, then build and start the
## Docker containers, phones included (:6080 and :6081). The backend image generates its own code
## (backend/Dockerfile), so without the tools the stack still comes up; only
## the host copy (IDE, Flutter stubs, make backend) is skipped, loudly.
all:
	@missing=""; for t in $(CODEGEN_TOOLS); do command -v $$t >/dev/null || missing="$$missing $$t"; done; \
	if [ -z "$$missing" ]; then \
		$(MAKE) buf-rebuild sqlc-rebuild generate-openapi || exit 1; \
	else \
		echo ""; \
		echo "WARNING: host code generation skipped, missing:$$missing"; \
		echo "  The Docker stack still builds, but VS Code will show errors and the"; \
		echo "  Flutter app will not compile. Install them with 'make tools' (see 'make doctor'),"; \
		echo "  or generate everything through Docker with 'make docker-generate'."; \
		echo ""; \
	fi
	@# phone-2 runs phone's image: built once. Free space unknown counts as low.
	@free=$$(df -Pk "$$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)" 2>/dev/null | awk 'NR==2 {print int($$4 / 1048576)}'); \
	if [ "$${free:-0}" -lt $(LOW_DISK_GB) ]; then \
		echo "$${free:-?} GB free for Docker: building one image at a time, without keeping the build cache."; \
		for s in backend image-service; do \
			$(COMPOSE) build $$s && docker builder prune -af >/dev/null || exit 1; \
		done; \
		$(MAKE) phone-build-lean || exit 1; \
		$(COMPOSE) up -d --no-build; \
	else \
		$(COMPOSE) up --build -d; \
	fi
	@echo "Phones: http://localhost:6080 and http://localhost:6081"

## Help target to display available commands
help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Available targets:"
	@echo "Evaluation (Docker only, nothing else installed):"
	@echo "  eval-check            Check the machine: docker, compose, buildx, RAM, disk"
	@echo "  eval                  Stack + demo data + the phone (http://localhost:6080)"
	@echo "  phone / phone-2       The app on a phone-sized screen in the browser (:6080 / :6081)"
	@echo "  phone-build           Rebuild the phone image after a code change"
	@echo "  phone-stop            Stop the phones (and the Android emulator)"
	@echo "  android               The Android app on an emulator (:6082), needs /dev/kvm"
	@echo "  apk                   Android APK for a real phone -> dist/music-room.apk"
	@echo "                        (APK_BACKEND_HOST=<this machine's LAN IP>, guessed by default)"
	@echo "  docker-api-test       Python API suite in a container (PYTEST_ARGS=... to narrow)"
	@echo "  docker-app-test       Flutter app tests in a container (APP_TEST_ARGS=... to narrow)"
	@echo "  docker-app-test-live  The app's test/live, in a container, against the stack"
	@echo "  docker-generate       All generated code (Go, sqlc, Dart, OpenAPI client) via Docker"
	@echo "  eval-images-save/load Carry every image in dist/images.tar for an offline machine"
	@echo ""
	@echo "Load testing (V.7, docs/annex/load-testing.md):"
	@echo "  loadtest              Measured run: SCENARIO=mixed|track_vote|playlist_editor|delegation|login"
	@echo "                        LT_PROFILE=small|medium, STEPS=25,50,..., HOLD=2m -> loadtest/results/"
	@echo "  loadtest-demo         Bots voting on the demo event while the phone shows it (:5665 dashboard)"
	@echo "  loadtest-down         Stop the load-test stack and drop its volumes"
	@echo ""
	@echo "Development:"
	@echo "  doctor                Check that every tool the install needs is reachable"
	@echo "  tools                 Install the code generation tools (buf, sqlc, protoc plugins)"
	@echo "  all                   Build and start Docker containers and both phones (default)"
	@echo "  backend               Start postgres containers and run Go backend"
	@echo "  frontend              Run the Flutter app on an Android emulator (boots one if needed)"
	@echo "  frontend-second       Same on a second emulator, to test two accounts at once"
	@echo "  frontend-linux        Run the Flutter app as a Linux desktop window"
	@echo "  emulator-setup        Create an Android emulator (AVD) if none exists"
	@echo "  backend-build         Build the Go backend server binary"
	@echo "  backend-test          Run Go backend unit tests with race detector"
	@echo "  backend-test-coverage Run Go backend unit tests with HTML coverage report"
	@echo "  backend-lint          Run golangci-lint on Go backend code"
	@echo "  tidy                  Run 'go mod tidy' inside the backend directory"
	@echo "  sqlc-generate         Regenerate db/sqlc (containerised sqlc)"
	@echo "  docker-backend-build  Build the backend with a containerised Go toolchain"
	@echo "  docker-backend-test   Run backend unit tests in a container"
	@echo "  docker-backend-test-integration  ... plus tests needing live Postgres/OpenFGA"
	@echo "  docker-backend-lint   gofmt + go vet in a container"
	@echo "  openfga               Start the OpenFGA server and its database"
	@echo "  fga-validate          Validate authz/model.fga locally (requires the fga CLI)"
	@echo "  fga-model             Push authz/model.fga into the running OpenFGA store"
	@echo "  seed                  Fill the stack with the demo world (docs/annex/init_script_doc.md)"
	@echo "  seed-reset            DESTRUCTIVE: wipe the database, OpenFGA and images, then seed"
	@echo "  seed-local            Seed for a backend run on the host (make backend)"
	@echo "  seed-doc              Rewrite docs/annex/init_script_doc.md from the seeder"
	@echo "  activity-logs         Tail the most recent activity_logs rows (N=50 for more)"
	@echo "  clean                 Stop Docker containers and remove build/test artifacts"
	@echo "  fclean                Full Docker clean (containers, volumes, images, generated code)"
	@echo "  re                    Rebuild and restart the Docker environment"
	@echo "  buf-dep               Update Buf dependencies"
	@echo "  buf-lint              Run buf linter on proto files"
	@echo "  buf-format            Format proto files with buf"
	@echo "  buf-generate          Generate code from proto using buf"
	@echo "  buf-breaking          Check for breaking changes against main branch"
	@echo "  generate-openapi      Generate Dart client from Swagger/OpenAPI spec"
	@echo "  build-runner          Generate Flutter code using build_runner"
	@echo "  build-runner-clean     Clean the build_runner cache"
	@echo "  rebuild-runner        Clean cache and regenerate Flutter code in one step"
	@echo "  generate              Run all code generation pipelines (buf + openapi + build-runner)"
	@echo "  setup-local-configs   Generate untracked Local.xcconfig templates for iOS & macOS"
	@echo "  provision-macos       Register bundle ID and fetch macOS provisioning profile via Xcode"
	@echo "  provision-ios         Register bundle ID and fetch iOS provisioning profile via Xcode"
	@echo "  provision-all         Run provisioning for both macOS and iOS"
	@echo "  run-macos             Launch Flutter macOS desktop application"
	@echo "  run-ios               Launch Flutter iOS application"
	@echo "  api-test              Start the stack, install deps and run the Python API test suite"
	@echo "  api-test-up           Start postgres/backend for the API test suite"
	@echo "  api-test-down         Stop postgres/backend started for the API test suite"
	@echo "  api-test-deps         Create/refresh the tests/.venv virtualenv"

# ==============================================================================
# Application Execution & Backend Tooling
# ==============================================================================

## Start Postgres & OpenFGA containers then run the Go backend server
## OpenFGA is not optional here: the backend refuses to boot without a reachable
## store holding an authorization model.
backend:
	docker compose up -d postgres openfga-init
#	Redis is disabled in docker-compose.yaml; add `redis` here when re-enabled.
	cd $(BACKEND_DIR) && APP_OPENFGA_API_URL=http://localhost:8082 go run $(MAIN_FILE)

## Run the Flutter app on an Android emulator (AVD), creating and booting it
## first when needed. Inside the emulator localhost is the emulator itself;
## 10.0.2.2 is the host machine, where docker compose publishes the backend.
##
## EMULATOR picks the AVD: the machine's first one other than SECOND_EMULATOR
## (the list is alphabetical, so that one could come first and both targets
## would share it), or AVD_NAME when there is none. The system image must match
## the host CPU: an x86_64 image on an ARM host does not boot.
AVD_NAME      ?= Music_Room_Pixel
AVD_DEVICE    ?= pixel_4a
SECOND_EMULATOR ?= Music_Room_Pixel_2
EMULATOR      ?= $(or $(shell emulator -list-avds 2>/dev/null | grep -vx '$(SECOND_EMULATOR)' | head -n 1),$(AVD_NAME))
ANDROID_ABI   ?= $(if $(filter aarch64 arm64,$(shell uname -m)),arm64-v8a,x86_64)
ANDROID_IMAGE ?= system-images;android-36;google_apis;$(ANDROID_ABI)
ANDROID_BACKEND_HOST ?= 10.0.2.2

## adb serial (emulator-5554...) of the running instance of $(EMULATOR), if any.
EMULATOR_SERIAL = for s in $$(adb devices | awk '/^emulator-.*device$$/ {print $$1}'); do \
	[ "$$(adb -s $$s emu avd name 2>/dev/null | head -n 1 | tr -d '\r')" = "$(EMULATOR)" ] \
	&& echo $$s && break; done

ANDROID_SDK   ?= $(or $(ANDROID_HOME),$(ANDROID_SDK_ROOT),$(HOME)/Android/Sdk)

## Create the $(EMULATOR) AVD if it does not exist. Needs the Android SDK
## command-line tools (sdkmanager, avdmanager); the SDK itself is not installed
## here -- Android Studio's SDK Manager does that.
##
## sdkmanager only gets the packages that are missing: given one already
## installed it upgrades it, swapping the emulator and adb binaries out from
## under a running emulator, which then dies.
emulator-setup:
	@if emulator -list-avds 2>/dev/null | grep -qx "$(EMULATOR)"; then \
		echo "Android emulator present: $(EMULATOR)"; \
	else \
		command -v sdkmanager >/dev/null && command -v avdmanager >/dev/null || { \
			echo "sdkmanager/avdmanager not found: install the Android SDK command-line tools (Android Studio > SDK Manager)"; exit 1; }; \
		echo "Creating Android emulator $(EMULATOR) ($(ANDROID_IMAGE))..."; \
		yes | sdkmanager --licenses >/dev/null; \
		pkgs=""; \
		[ -x "$(ANDROID_SDK)/platform-tools/adb" ] || pkgs="$$pkgs platform-tools"; \
		[ -x "$(ANDROID_SDK)/emulator/emulator" ] || pkgs="$$pkgs emulator"; \
		[ -d "$(ANDROID_SDK)/$(subst ;,/,$(ANDROID_IMAGE))" ] || pkgs="$$pkgs $(ANDROID_IMAGE)"; \
		[ -z "$$pkgs" ] || sdkmanager $$pkgs || exit 1; \
		echo no | avdmanager create avd -n "$(EMULATOR)" -k "$(ANDROID_IMAGE)" -d $(AVD_DEVICE) || exit 1; \
		echo "hw.keyboard=yes" >> "$$HOME/.android/avd/$(EMULATOR).avd/config.ini"; \
	fi

frontend: emulator-setup $(OPENAPI_OUT)
	cd $(FRONTEND_DIR) && flutter pub get
	@# frontend/app/.env (DEV_SESSION_TOKEN, OAuth ids...) with BACKEND_HOST
	@# swapped for the emulator's view of the host.
	cd $(FRONTEND_DIR) && { [ -f .env ] && grep -v '^BACKEND_HOST=' .env; \
		echo "BACKEND_HOST=$(ANDROID_BACKEND_HOST)"; } > .dart_tool/env.android
	@serial=$$($(EMULATOR_SERIAL)); \
	if [ -z "$$serial" ]; then \
		echo "Starting Android emulator $(EMULATOR)..."; \
		flutter emulators --launch "$(EMULATOR)" || exit 1; \
		until serial=$$($(EMULATOR_SERIAL)); [ -n "$$serial" ]; do sleep 2; done; \
		until [ "$$(adb -s $$serial shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do sleep 2; done; \
	fi; \
	cd $(FRONTEND_DIR) && flutter run -d $$serial --dart-define-from-file=.dart_tool/env.android

## A second emulator next to the first, e.g. to test with two accounts at once.
## Run it in another terminal once `make frontend` has finished building.
frontend-second:
	$(MAKE) frontend EMULATOR=$(SECOND_EMULATOR)

## Run the Flutter app as a Linux desktop window (backend on localhost)
frontend-linux: $(OPENAPI_OUT)
	cd $(FRONTEND_DIR) && flutter pub get && flutter run -d linux \
		$$([ -f .env ] && echo --dart-define-from-file=.env)

## Build the Go backend binary
backend-build:
	cd $(BACKEND_DIR) && mkdir -p bin && go build -o bin/$(APP_NAME) $(MAIN_FILE)

## Run Go backend unit tests with race detection
backend-test:
	cd $(BACKEND_DIR) && go test -v -race ./...

## Run Go backend unit tests with HTML coverage report
backend-test-coverage:
	cd $(BACKEND_DIR) && go test -v -race -coverprofile=coverage.out ./...
	cd $(BACKEND_DIR) && go tool cover -html=coverage.out -o coverage.html

## Lint Go backend source code (requires golangci-lint)
backend-lint:
	cd $(BACKEND_DIR) && golangci-lint run ./...

## Download dependencies and prune backend go.mod
tidy:
	cd $(BACKEND_DIR) && go mod tidy

# ==============================================================================
# Containerised Go toolchain -- everything below needs Docker, not Go
# ==============================================================================

## Build the backend binary in a container
docker-backend-build:
	$(DOCKER_GO) go build -o bin/$(APP_NAME) $(MAIN_FILE)

## Run the unit tests in a container
##
## No -race: the detector needs cgo and a C compiler, which the alpine image
## does not carry. `make backend-test` runs it with the race detector when a
## host toolchain is available.
docker-backend-test:
	$(DOCKER_GO) go test ./...

## Run the tests that need live Postgres and OpenFGA (build tag: integration)
docker-backend-test-integration: openfga
	docker compose up -d postgres
	$(DOCKER_GO_NET) go test -tags integration ./...

## gofmt + go vet in a container (golangci-lint is not installed there)
docker-backend-lint:
	$(DOCKER_GO) sh -c 'test -z "$$(gofmt -l .)" || { echo "gofmt wants changes in:"; gofmt -l .; exit 1; }'
	$(DOCKER_GO) go vet ./...

# ==============================================================================
# Host toolchain -- what `make` (code generation) and the frontend need
# ==============================================================================

## Code generation tool versions, shared by `tools` and `docker-generate`.
BUF_VERSION                ?= v1.47.2
PROTOC_GEN_GO_VERSION      ?= v1.36.11
PROTOC_GEN_GO_GRPC_VERSION ?= v1.5.1
GRPC_GATEWAY_VERSION       ?= v2.30.0
SQLC_VERSION               ?= v1.30.0
PROTOC_PLUGIN_VERSION      ?= 25.0.0

## Install the code generation tools on the host (needs Go and Dart/Flutter).
## They land in $(go env GOPATH)/bin and ~/.pub-cache/bin, which must be on PATH.
tools:
	go install github.com/bufbuild/buf/cmd/buf@$(BUF_VERSION)
	go install google.golang.org/protobuf/cmd/protoc-gen-go@$(PROTOC_GEN_GO_VERSION)
	go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@$(PROTOC_GEN_GO_GRPC_VERSION)
	go install github.com/grpc-ecosystem/grpc-gateway/v2/protoc-gen-grpc-gateway@$(GRPC_GATEWAY_VERSION)
	go install github.com/grpc-ecosystem/grpc-gateway/v2/protoc-gen-openapiv2@$(GRPC_GATEWAY_VERSION)
	go install github.com/sqlc-dev/sqlc/cmd/sqlc@$(SQLC_VERSION)
	dart pub global activate protoc_plugin $(PROTOC_PLUGIN_VERSION)
	@echo ""
	@echo "Done. If 'make doctor' still reports them missing, add to ~/.bashrc:"
	@echo '  export PATH="$$PATH:$$(go env GOPATH)/bin:$$HOME/.pub-cache/bin"'

## Check that every tool the install (README.md) needs is reachable.
doctor:
	@ok=1; \
	check() { if command -v "$$1" >/dev/null 2>&1; then printf '  ok       %s\n' "$$1"; \
		else printf '  MISSING  %-26s -> %s\n' "$$1" "$$2"; ok=0; fi; }; \
	echo "Backend:"; \
	check docker "https://docs.docker.com/engine/install/"; \
	if docker info >/dev/null 2>&1; then echo "  ok       docker daemon reachable"; \
		else echo "  FAIL     docker daemon not reachable (started? user in the docker group?)"; ok=0; fi; \
	check go "https://go.dev/doc/install (only needed for make tools)"; \
	for t in buf sqlc protoc-gen-go protoc-gen-go-grpc protoc-gen-grpc-gateway protoc-gen-openapiv2 protoc-gen-dart; do \
		check $$t "make tools"; done; \
	echo "Frontend:"; \
	check flutter "https://docs.flutter.dev/get-started/install/linux"; \
	check adb "Android Studio > SDK Manager > Android SDK Platform-Tools"; \
	check emulator "Android Studio > SDK Manager > Android Emulator"; \
	check sdkmanager "Android Studio > SDK Manager > Android SDK Command-line Tools"; \
	check avdmanager "Android Studio > SDK Manager > Android SDK Command-line Tools"; \
	if [ -w /dev/kvm ]; then echo "  ok       /dev/kvm (emulator acceleration)"; \
		else echo "  WARN     /dev/kvm not writable: the emulator will be very slow (sudo usermod -aG kvm \$$USER), or use make frontend-linux"; fi; \
	[ $$ok = 1 ] && echo "All good." || { echo "Some tools are missing, see README.md."; exit 1; }

## Regenerate everything `make generate` does, in containers: the Go protobuf
## stubs, the served OpenAPI spec and db/sqlc (golang image, buf.gen.backend.yaml,
## the template the backend image runs), then the Dart stubs, the OpenAPI client
## and lib/gen/api.dart (frontend/Dockerfile's `gen` target). The spec is not
## optional: internal/apidocs go:embeds it, so go build fails without.
docker-generate: docker-generate-backend docker-generate-frontend

docker-generate-frontend:
	rm -rf $(FRONTEND_DIR)/lib/gen
	$(FRONTEND_BUILD) --target gen --output type=local,dest=$(FRONTEND_DIR)/lib/gen .

docker-generate-backend:
	docker run --rm -v "$(CURDIR):/work" -v $(GO_MOD_VOLUME):/go/pkg/mod \
		-v $(GO_BUILD_CACHE):/root/.cache/go-build -w /work $(GO_IMAGE) sh -c '\
		go install github.com/bufbuild/buf/cmd/buf@$(BUF_VERSION) && \
		go install google.golang.org/protobuf/cmd/protoc-gen-go@$(PROTOC_GEN_GO_VERSION) && \
		go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@$(PROTOC_GEN_GO_GRPC_VERSION) && \
		go install github.com/grpc-ecosystem/grpc-gateway/v2/protoc-gen-grpc-gateway@$(GRPC_GATEWAY_VERSION) && \
		go install github.com/grpc-ecosystem/grpc-gateway/v2/protoc-gen-openapiv2@$(GRPC_GATEWAY_VERSION) && \
		go install github.com/sqlc-dev/sqlc/cmd/sqlc@$(SQLC_VERSION) && \
		export PATH=$$PATH:/go/bin && \
		buf generate --template buf.gen.backend.yaml && \
		cd backend && sqlc generate'

# ==============================================================================
# OpenFGA
# ==============================================================================

## Start the OpenFGA server, its database, and the one-shot store/model import
openfga:
	docker compose up -d openfga-init

## Validate authz/model.fga locally.
##
## NECESSARY, NOT SUFFICIENT: it does not catch the server's 512-byte cap on a
## condition expression. `make fga-model` is the real check.
fga-validate:
	docker run --rm -v "$(CURDIR)/authz:/authz" $(FGA_CLI_IMAGE) model validate --file /authz/model.fga

## Push authz/model.fga into the running store, then restart the backend if it
## runs: it pins the latest model id at boot (authz.Client.Ping), so a new model
## is only picked up by a fresh start (restart a `make backend` process by hand).
fga-model: openfga
	docker run --rm --network music-room_default -v "$(CURDIR)/authz:/authz" \
		$(FGA_CLI_IMAGE) --api-url http://openfga:8080 \
		model write --store-id $(FGA_STORE_ID) --file /authz/model.fga
	@docker compose ps --status running --services 2>/dev/null | grep -qx backend && \
		docker compose restart backend || true

## Tail the most recent activity_logs rows (V.6, docs/annex/authz-enforcement.md
## §Activity logging). N overrides the row count: make activity-logs N=50
##
## resource_type/resource_id are the object a Requirement resolved (never
## the raw request body -- see the doc for why). platform / model /
## app_version are subject V.6's platform, device and application version:
## model is the x-device-model header the call itself sent, so it is there on
## every row, a failed login included. platform and app_version are the
## snapshots copied from the session's device (bound by RegisterDevice), NULL
## for a call with no session or made before the app registered -- metadata
## still carries the raw headers for those.
##
## Not `N ?= 20`: N is also the load test's account count (N ?= 1000 below),
## and a global default here won the first-come `?=` and seeded every load test
## with 20 accounts. 20 only when N is not given on the command line.
activity-logs:
	docker compose exec postgres psql -U postgres -d music_room -c \
		"SELECT created_at, action, user_id, device_id, platform_snapshot AS platform, metadata->>'x-device-model' AS model, app_version_snapshot AS app_version, resource_type, resource_id, result_code, metadata FROM activity_logs ORDER BY created_at DESC LIMIT $(if $(filter command line,$(origin N)),$(N),20);"

# ==============================================================================
# Demo data (backend/cmd/seed) -- docs/annex/init_script_doc.md lists what it creates
# ==============================================================================

# The seeder built into the backend image (backend/Dockerfile), run as the
# backend service: its environment and image volume, so it writes where the
# backend reads, and its depends_on, so postgres and openfga-init are up first.
# Docker only: no Go, no generated code on the host. The image is the one
# `make` last built. -loadtest's fixtures go to loadtest/ on the host.
SEED = docker compose run --rm -v "$(CURDIR)/loadtest:/loadtest" \
	--entrypoint /music-room-seed backend -loadtest-out /loadtest/fixtures.json

## Fill the database, OpenFGA and the image volume with the demo world.
## Refuses if it is already there. SEED_ARGS=-offline skips Deezer.
seed:
	$(SEED) $(SEED_ARGS)

## DESTRUCTIVE: empty every table, every OpenFGA tuple and the image folders,
## then seed again. Accounts made by hand go too.
seed-reset:
	$(SEED) -reset $(SEED_ARGS)

## The same as `seed`, for a backend run on the host with `make backend`
## (localhost URLs, images in backend/data/images). Add SEED_ARGS=-reset to wipe.
seed-local:
	docker compose up -d --wait postgres
	docker compose up -d openfga-init
	cd $(BACKEND_DIR) && APP_OPENFGA_API_URL=http://localhost:8082 go run ./cmd/seed $(SEED_ARGS)

## Rewrite docs/annex/init_script_doc.md from the seeder (no database needed)
seed-doc:
	$(DOCKER_GO) go run ./cmd/seed -doc ../docs/annex/init_script_doc.md

# ==============================================================================
# Python API integration tests (tests/) -- black-box, over the REST gateway
# ==============================================================================

## Start postgres/backend for the Python API test suite
## OpenFGA's check cache is OFF for the suite (API_TEST_FGA_CACHE=true to keep
## it). With it on, a revocation takes ~1-2 s to reach a Check that was cached
## (docker-compose.yaml), and some tests read straight after revoking -- e.g.
## test_settings.py::test_owner_can_change_visibility_after_creation. The suite
## asserts the rules; the cache's staleness is a measured, documented trade-off.
## Side effect: openfga stays uncached until the next `make all`.
API_TEST_FGA_CACHE ?= false
api-test-up:
	APP_RATE_LIMIT_RPS=0 FGA_CHECK_CACHE=$(API_TEST_FGA_CACHE) docker compose up --build -d postgres backend

## Stop the containers started for the Python API test suite
api-test-down:
	docker compose stop postgres backend

## Create/refresh the virtualenv used by the API test suite
api-test-deps:
	python3 -m venv $(API_TESTS_VENV)
	$(API_TESTS_VENV)/bin/pip install -q -r $(API_TESTS_DIR)/requirements.txt

## Start the stack, install deps and run the Python API test suite
api-test: api-test-up api-test-deps
	TEST_DATABASE_URL=postgresql://postgres:$(POSTGRES_PASSWORD)@localhost:5432/music_room $(API_TESTS_VENV)/bin/pytest $(API_TESTS_DIR) -v

# ==============================================================================
# Evaluation -- Docker only (README.md, "Installation")
# ==============================================================================
# The evaluation machines have Docker and nothing else: no Go, Flutter, Android
# SDK or Python. Everything below runs in containers, from a fresh clone.

## BuildKit (--output) and linux/amd64: the Android SDK has no linux-arm64
## aapt2, so on an Apple Silicon Mac the build runs emulated.
FRONTEND_BUILD = docker build --platform linux/amd64 -f frontend/Dockerfile

APK     := dist/music-room.apk
BACKEND_URL ?= http://localhost:8081

## The address a real phone reaches the backend at, baked into the APK: this
## machine on the local network (the phone on the same Wi-Fi). Guessed, so
## override it when the machine has several: make apk APK_BACKEND_HOST=192.168.1.20
APK_BACKEND_HOST ?= $(shell hostname -I 2>/dev/null | awk '{print $$1}' || true)$(if $(filter Darwin,$(shell uname)),$(shell ipconfig getifaddr en0 2>/dev/null))

## Which phone `phone` starts; phone-2 overrides all three.
PHONE_SERVICE  ?= phone
PHONE_PROFILE  ?= phone
PHONE_WEB_PORT ?= 6080
PHONE_IMAGE    := music-room-phone

## Docker-only doctor: what `make eval` needs from the machine.
eval-check:
	@ok=1; \
	pass() { printf '  ok       %s\n' "$$1"; }; \
	fail() { printf '  FAIL     %s\n' "$$1"; ok=0; }; \
	warn() { printf '  WARN     %s\n' "$$1"; }; \
	command -v docker >/dev/null && pass docker || fail "docker: https://docs.docker.com/engine/install/"; \
	docker info >/dev/null 2>&1 && pass "docker daemon reachable" || fail "docker daemon not reachable (started? user in the docker group?)"; \
	docker compose version >/dev/null 2>&1 && pass "docker compose v2" || fail "docker compose v2 (the plugin, not docker-compose v1)"; \
	docker buildx version >/dev/null 2>&1 && pass "docker buildx" || fail "docker buildx (BuildKit, for make apk)"; \
	command -v curl >/dev/null && pass curl || fail "curl (apt install curl)"; \
	cpus=$$(docker info --format '{{.NCPU}}' 2>/dev/null); mem=$$(docker info --format '{{.MemTotal}}' 2>/dev/null); \
	[ -n "$$mem" ] && [ "$$mem" -ge 8000000000 ] && pass "$$cpus CPUs, $$((mem / 1073741824)) GB RAM" || warn "$$cpus CPUs, $$(( $${mem:-0} / 1073741824 )) GB RAM: 8 GB+ advised (stack + Flutter build + phones)"; \
	root=$$(docker info --format '{{.DockerRootDir}}' 2>/dev/null); \
	free=$$(df -Pk "$$root" 2>/dev/null | awk 'NR==2 {print int($$4 / 1048576)}'); \
	[ -n "$$free" ] && [ "$$free" -ge 25 ] && pass "$$free GB free for Docker ($$root)" || warn "$${free:-?} GB free for Docker ($$root): images + build caches take ~25 GB"; \
	if command -v ss >/dev/null; then for port in 5432 5433 6379 8080 8081 8082 8083 50051 6080 6081; do \
		ss -ltnH "sport = :$$port" 2>/dev/null | grep -q . && warn "port $$port already in use (fine if it is this stack)"; \
	done; fi; \
	[ $$ok = 1 ] && echo "Ready for make eval." || { echo "Fix the FAIL lines first."; exit 1; }

## The Android APK, built in Docker -> dist/music-room.apk (release, arm64 + x86_64),
## for a real phone: the demo itself runs on `make phone`, which needs no APK.
## Cached: a rebuild with nothing changed takes seconds.
apk:
	@[ -n "$(APK_BACKEND_HOST)" ] || { echo "Could not guess this machine's LAN IP: make apk APK_BACKEND_HOST=<ip>"; exit 1; }
	$(FRONTEND_BUILD) --target apk-out --build-arg BACKEND_HOST=$(APK_BACKEND_HOST) \
		--output type=local,dest=dist .
	@echo "$(APK) talks to the backend at $(APK_BACKEND_HOST):50051. Install it on a phone"
	@echo "on the same network as this machine (ports 50051 and 8081 reachable)."

## Wait until the REST gateway answers (the same probe as tests/conftest.py).
wait-backend:
	@printf 'Waiting for the backend on $(BACKEND_URL)'; \
	for i in $$(seq 1 120); do \
		curl -s -o /dev/null --max-time 2 $(BACKEND_URL)/v1/events/0 && { echo " up."; exit 0; }; \
		printf .; sleep 2; \
	done; echo " not up after 4 min: docker compose logs backend"; exit 1

## Seed the demo world unless it is already there (`seed` refuses a second run),
## with 200 load-test accounts for `make loadtest-demo`'s bots.
seed-once:
	@if docker compose exec -T postgres psql -U postgres -d music_room -tAc \
		"SELECT 1 FROM users WHERE email = 'alex@musicroom.test'" 2>/dev/null | grep -q 1; then \
		echo "Demo world already seeded (make seed-reset re-seeds: the live events are relative to seed time)."; \
	else $(MAKE) seed SEED_ARGS="-loadtest 200"; fi

## Start the phone (http://localhost:6080): the Music Room Linux app on a
## phone-sized screen, in the browser (docker-compose.yaml, frontend/Dockerfile).
## Builds the image only when it is missing, not on every run: after
## `eval-images-load` on an offline machine the image is there but no build
## cache or base image is, and a rebuild would fail. `make phone-build` after a
## code change.
phone:
	@docker image inspect $(PHONE_IMAGE) >/dev/null 2>&1 || $(MAKE) phone-build
	docker compose --profile $(PHONE_PROFILE) up -d --no-build $(PHONE_SERVICE)
	@printf 'Waiting for the phone'; \
	for i in $$(seq 1 60); do \
		curl -s -o /dev/null --max-time 2 http://localhost:$(PHONE_WEB_PORT)/vnc.html && { echo " up."; break; }; \
		if ! docker compose ps --status running --services | grep -qx $(PHONE_SERVICE); then \
			echo " the container stopped; docker compose logs $(PHONE_SERVICE)"; exit 1; fi; \
		[ $$i = 60 ] && { echo " not up after 2 min: docker compose logs $(PHONE_SERVICE)"; exit 1; }; \
		printf .; sleep 2; \
	done
	@echo ""
	@echo "Phone ready: open http://localhost:$(PHONE_WEB_PORT) in a browser."
	@echo "Sign in as alex@musicroom.test / musicroom42 (docs/annex/init_script_doc.md lists every account)."

## (Re)build the phone image: the Flutter Linux build, ~10 min the first time.
## Then `make phone` (or phone-2) recreates a running phone on the new image.
## phone-build in two builds, for `make` on a low disk: the app alone (Flutter
## and its toolchain, several GB) into dist/phone, the cache dropped, then the
## phone image around it, so the two never sit on the disk together. The 42 and
## Google client IDs come from .env, as docker-compose.yaml passes them.
PHONE_OAUTH = $(foreach p,INTRA42 GOOGLE,--build-arg OAUTH_$(p)_CLIENT_ID=$$(sed -n 's/^APP_OAUTH_$(p)_CLIENT_ID=//p' .env 2>/dev/null | tail -n 1 | tr -d '"'))
phone-build-lean:
	rm -rf dist/phone
	docker build -f frontend/Dockerfile --target linux-bundle $(PHONE_OAUTH) --output type=local,dest=dist/phone .
	docker builder prune -af >/dev/null
	docker build -f frontend/Dockerfile --target phone --build-context linux-build=dist/phone -t $(PHONE_IMAGE) .
	docker builder prune -af >/dev/null

phone-build:
	docker compose --profile phone build phone

## The real Android app on an emulator (http://localhost:6082): builds the APK,
## boots the emulator, installs and opens the app. Needs /dev/kvm, which the
## evaluation machines lack: for a Linux laptop, after `make` and `make seed`.
APP_ID := com.example.app
ANDROID_BOOT_TIMEOUT ?= 600
android:
	@# Only there: the Docker daemon, root, hands it to the container.
	@[ -e /dev/kvm ] || { echo "/dev/kvm missing: the emulator cannot start" \
		"(hardware virtualisation off in the BIOS, or not a Linux host)"; exit 1; }
	$(MAKE) apk
	docker compose --profile android up -d android
	@printf 'Booting the emulator (1-3 min the first time)'; \
	start=$$(date +%s); \
	until docker compose exec -T android adb shell getprop sys.boot_completed 2>/dev/null | grep -q 1; do \
		if [ $$(( $$(date +%s) - start )) -gt $(ANDROID_BOOT_TIMEOUT) ]; then \
			echo " gave up after $(ANDROID_BOOT_TIMEOUT) s: docker compose logs android"; exit 1; fi; \
		if ! docker compose ps --status running --services | grep -qx android; then \
			echo " the container stopped: docker compose logs android"; exit 1; fi; \
		printf .; sleep 5; \
	done; echo " booted."
	@# Copied rather than mounted: BuildKit makes dist/ owner-only, and the
	@# emulator runs as another user.
	docker compose cp $(APK) android:/tmp/music-room.apk
	docker compose exec -T android adb install -r /tmp/music-room.apk
	docker compose exec -T android adb shell monkey -p $(APP_ID) \
		-c android.intent.category.LAUNCHER 1 >/dev/null
	@echo ""
	@echo "Android ready: open http://localhost:6082 in a browser."
	@echo "Sign in as alex@musicroom.test / musicroom42 (needs make seed first)."

## A second phone on :6081, to show two accounts collaborating.
phone-2:
	$(MAKE) phone PHONE_SERVICE=phone-2 PHONE_PROFILE=phone2 PHONE_WEB_PORT=6081

## Stop the phones, leaving the stack running.
phone-stop:
	docker compose --profile phone --profile phone2 --profile android stop phone phone-2 android

## Evaluation day, one command: stack, demo data, phone.
eval: all wait-backend seed-once phone

## The Python API suite, in a container (tests/Dockerfile) on the compose
## network: no Python or grpcurl on the host. Starts the stack if needed.
## PYTEST_ARGS narrows it, e.g. PYTEST_ARGS="tests/playlist_editor -x".
PYTEST_ARGS ?= tests
TESTS_IMAGE := music-room-tests
docker-api-test: api-test-up
	docker build -q -t $(TESTS_IMAGE) tests >/dev/null
	$(MAKE) wait-backend
	docker run --rm --network music-room_default -v "$(CURDIR):/work" -w /work \
		-e API_BASE_URL=http://backend:8081 \
		-e TEST_DATABASE_URL=postgresql://postgres:$(POSTGRES_PASSWORD)@postgres:5432/music_room \
		-e OPENFGA_API_URL=http://openfga:8080 \
		-e GRPC_ADDR=backend:50051 \
		-e PYTHONDONTWRITEBYTECODE=1 \
		$(TESTS_IMAGE) pytest -p no:cacheprovider $(PYTEST_ARGS)

## The app's tests, in a container (frontend/Dockerfile, target app-test): no
## Flutter on the host. APP_TEST_ARGS narrows it, e.g. APP_TEST_ARGS=test/events.
## The -live one runs test/live against the stack, on the compose network.
APP_TEST_ARGS  ?=
APP_TEST_IMAGE := music-room-app-test
app-test-image:
	docker build -f frontend/Dockerfile --target app-test -t $(APP_TEST_IMAGE) .
docker-app-test: app-test-image
	docker run --rm $(APP_TEST_IMAGE) flutter test $(APP_TEST_ARGS)
docker-app-test-live: app-test-image api-test-up
	$(MAKE) wait-backend
	docker run --rm --network music-room_default \
		-v /var/run/docker.sock:/var/run/docker.sock $(APP_TEST_IMAGE) \
		flutter test test/live --dart-define=LIVE_GRPC_HOST=backend --dart-define=BACKEND_HOST=backend

## Every image eval day needs, in one tarball, for a slow or offline network:
## `make eval-images-save` beforehand (after `make all`), carry
## dist/images.tar, `make eval-images-load` on the machine.
EVAL_IMAGES = postgres:16-alpine $(FGA_IMAGE) $(FGA_CLI_IMAGE) \
	music-room-backend music-room-image-service $(PHONE_IMAGE)
eval-images-save:
	docker compose --profile phone build
	for i in $(EVAL_IMAGES); do docker image inspect $$i >/dev/null 2>&1 || docker pull $$i; done
	docker save -o dist/images.tar $(EVAL_IMAGES)
	@ls -lh dist/images.tar

eval-images-load:
	docker load -i dist/images.tar

# ==============================================================================
# Load testing (V.7) -- docs/annex/load-testing.md
# ==============================================================================
# A separate compose project (music-room-lt, loadtest/compose.yaml): its own
# volumes and network, a declared CPU/memory budget, re-seeded before every run.
# The dev stack (`make all`) is never touched.
#
#   make loadtest                          mixed scenario, small budget
#   make loadtest SCENARIO=playlist_editor LT_PROFILE=medium
#   make loadtest SCENARIO=login STEPS=1,2,4,8,16
#   make loadtest STEPS=50,100 HOLD=1m     a shorter ramp
#   make loadtest-down                     stop it and drop its volumes

SCENARIO   ?= mixed
LT_PROFILE ?= small
STEPS      ?= 25,50,100,200,400,800
RAMP       ?= 30s
HOLD       ?= 2m
## Load-test users to seed: at least the top step (one account per VU).
N          ?= 1000
## Re-seed before each run (1) so every run starts from the same state.
LT_RESEED  ?= 1
## pgx pool settings appended to the backend's DATABASE_URL, e.g.
## LT_DB_PARAMS=&pool_max_conns=20 (loadtest/compose.yaml).
LT_DB_PARAMS ?=

## The budget, i.e. the "server" the result belongs to. Totals: small 2 vCPU /
## ~1.5 GB, medium 4 vCPU / ~3 GB (image-service adds 0.5 vCPU / 256 MB,
## idle under this load).
## small gives OpenFGA more CPU than the backend: every request runs a Check, and
## the first runs (2026-10-11) had OpenFGA pinned at 0.25 vCPU while the backend
## idled under 30 %. The same 2 vCPU split this way held 3x the users
## (docs/annex/load-testing.md). It costs SCENARIO=login, which is Argon2 on the backend.
## Each cap can be overridden on its own, e.g. the original split:
## make loadtest LT_BACKEND_CPUS=1 LT_FGA_CPUS=0.25
ifeq ($(LT_PROFILE),medium)
LT_BACKEND_CPUS ?= 2
LT_BACKEND_MEM  ?= 1g
LT_PG_CPUS      ?= 1
LT_PG_MEM       ?= 1g
LT_FGA_CPUS     ?= 0.5
LT_FGA_MEM      ?= 512m
LT_FGA_PG_CPUS  ?= 0.5
LT_FGA_PG_MEM   ?= 512m
else
LT_BACKEND_CPUS ?= 0.5
LT_BACKEND_MEM  ?= 512m
LT_PG_CPUS      ?= 0.5
LT_PG_MEM       ?= 512m
LT_FGA_CPUS     ?= 0.75
LT_FGA_MEM      ?= 256m
LT_FGA_PG_CPUS  ?= 0.25
LT_FGA_PG_MEM   ?= 256m
endif
LT_BUDGET = LT_BACKEND_CPUS=$(LT_BACKEND_CPUS) LT_BACKEND_MEM=$(LT_BACKEND_MEM) \
	LT_PG_CPUS=$(LT_PG_CPUS) LT_PG_MEM=$(LT_PG_MEM) LT_FGA_CPUS=$(LT_FGA_CPUS) LT_FGA_MEM=$(LT_FGA_MEM) \
	LT_FGA_PG_CPUS=$(LT_FGA_PG_CPUS) LT_FGA_PG_MEM=$(LT_FGA_PG_MEM)

## Server containers on the lower half of the cores, k6 on the upper half.
LT_NCPU          := $(or $(shell docker info --format '{{.NCPU}}' 2>/dev/null),4)
LT_SERVER_CPUSET ?= 0-$(shell echo $$(( $(LT_NCPU) / 2 - 1 )))
LT_K6_CPUSET     ?= $(shell echo $$(( $(LT_NCPU) / 2 )))-$(shell echo $$(( $(LT_NCPU) - 1 )))

LT_PROJECT := music-room-lt
LT_ENV = LT_UID=$(shell id -u) LT_GID=$(shell id -g) \
	LT_SERVER_CPUSET=$(LT_SERVER_CPUSET) LT_K6_CPUSET=$(LT_K6_CPUSET) \
	LT_DB_PARAMS='$(LT_DB_PARAMS)' $(LT_BUDGET)
LT_COMPOSE = $(LT_ENV) docker compose -p $(LT_PROJECT) -f docker-compose.yaml -f loadtest/compose.yaml \
	--profile loadtest

## LT_LABEL tags a variant in the results folder name (e.g. LT_LABEL=fga075).
LT_RUN = $(shell date +%Y%m%d-%H%M%S)-$(SCENARIO)-$(LT_PROFILE)$(if $(LT_LABEL),-$(LT_LABEL))

## Start the budgeted stack (k6 and verify run on demand, not here).
loadtest-up:
	$(LT_COMPOSE) up -d --build --wait backend

## Wipe the load-test database and seed the demo world plus N load-test users;
## writes loadtest/fixtures.json, which the k6 scenarios read.
##
## The backend is stopped while the seed runs. `-loadtest 1000` queues 11k
## permission changes in one go and delivers them inline, one by one; 30 s in
## they fall due and the backend's own outbox worker (1 s interval) claims them
## too. On 2026-10-12 that claim ran on CPU for 48 minutes holding its rows'
## locks, so every inline DeleteTupleChange behind it timed out (3 s) and the
## seed crawled; cancelling it (pg_cancel_backend) emptied the table in under a
## minute. Cause not pinned down yet: the plan is sane even on stale statistics
## (docs/annex/load-testing.md, "Next steps"). With nobody else claiming, the seed's
## own drain is the only consumer, and the backend restarts on a fresh state.
loadtest-seed: loadtest-up
	$(LT_COMPOSE) stop backend
	docker run --rm --network $(LT_PROJECT)_default \
		-v "$(CURDIR):/work" -v $(GO_MOD_VOLUME):/go/pkg/mod -v $(GO_BUILD_CACHE):/root/.cache/go-build \
		-v $(LT_PROJECT)_image_data:/data/images \
		-e APP_DATABASE_URL=postgres://postgres:$(POSTGRES_PASSWORD)@postgres:5432/music_room?sslmode=disable \
		-e APP_OPENFGA_API_URL=http://openfga:8080 -e APP_IMAGE_STORAGE_DIR=/data/images \
		-w /work/$(BACKEND_DIR) $(GO_IMAGE) go run ./cmd/seed -reset -offline -loadtest $(N)
	$(LT_COMPOSE) up -d --wait backend

## One measured run: re-seed, snapshot, k6 (live dashboard on :5665), docker
## stats, then the consistency check. Everything lands in loadtest/results/<run>/.
## k6 exits 99 when a threshold broke -- the expected outcome of a ramp that
## finds the knee -- so that code does not stop the target.
loadtest: loadtest-up
	@[ "$(LT_RESEED)" = 0 ] && [ -f loadtest/fixtures.json ] || $(MAKE) loadtest-seed
	@run=$(LT_RUN); dir=loadtest/results/$$run; mkdir -p $$dir; \
	{ echo "run: $$run"; echo "date: $$(date -u)"; echo "git: $$(git rev-parse --short HEAD) $$(git status --porcelain | grep -q . && echo '(dirty)')"; \
	  echo "scenario: $(SCENARIO)  steps: $(STEPS)  ramp: $(RAMP)  hold: $(HOLD)  users seeded: $(N)"; \
	  echo "budget ($(LT_PROFILE)): $(LT_BUDGET)"; echo "db params: $(LT_DB_PARAMS)"; \
	  echo "cpusets: server $(LT_SERVER_CPUSET), k6 $(LT_K6_CPUSET)"; \
	  echo "docker: $$(docker info --format '{{.NCPU}} CPUs, {{.MemTotal}} bytes, {{.OperatingSystem}}, kernel {{.KernelVersion}}')"; \
	  echo "host cpu: $$(if command -v lscpu >/dev/null; then lscpu | sed -n 's/^Model name: *//p'; else sysctl -n machdep.cpu.brand_string 2>/dev/null; fi)"; \
	} > $$dir/env.txt; \
	$(LT_COMPOSE) run --rm --no-deps verify snapshot $$dir/before.json; \
	sh loadtest/stats.sh $(LT_PROJECT) $$dir/docker-stats.csv & stats=$$!; \
	$(LT_COMPOSE) run --rm --no-deps --service-ports \
		-e STEPS=$(STEPS) -e RAMP=$(RAMP) -e HOLD=$(HOLD) -e RESULTS_DIR=results/$$run \
		-e K6_WEB_DASHBOARD_EXPORT=results/$$run/report.html \
		k6 run scenarios/$(SCENARIO).js; code=$$?; \
	kill $$stats 2>/dev/null; \
	[ $$code = 0 ] || [ $$code = 99 ] || { echo "k6 failed ($$code)"; exit $$code; }; \
	$(LT_COMPOSE) run --rm --no-deps verify check $$dir/before.json $$dir/summary.json \
		> $$dir/verify.txt 2>&1; verified=$$?; cat $$dir/verify.txt; \
	echo ""; echo "Results: $$dir (report.html, steps.md, verify.txt, docker-stats.csv, env.txt)"; \
	exit $$verified

## Stop the load-test stack and drop its volumes.
loadtest-down:
	$(LT_COMPOSE) down -v --remove-orphans

## Evaluation demo, on the MAIN stack (the one the phone talks to): DEMO_VUS
## bots vote in "Friday Warm-up — Live" while Alex watches it on the phone,
## with the k6 dashboard on http://localhost:5665. Needs the bots' accounts in
## the main database: `make eval` seeds them; otherwise
## make seed-reset SEED_ARGS="-loadtest 200".
DEMO_VUS      ?= 100
DEMO_DURATION ?= 10m
loadtest-demo:
	@docker compose exec -T postgres psql -U postgres -d music_room -tAc \
		"SELECT 1 FROM users WHERE email = 'lt-000001@musicroom.test'" 2>/dev/null | grep -q 1 || { \
		echo "No load-test accounts in the main database: make seed-reset SEED_ARGS=\"-loadtest 200\""; exit 1; }
	@mkdir -p loadtest/results/demo
	docker run --rm --network music-room_default -p 5665:5665 -u $(shell id -u):$(shell id -g) \
		-v "$(CURDIR)/loadtest:/loadtest" -w /loadtest \
		-e BASE_URL=http://backend:8081 -e RESULTS_DIR=results/demo \
		-e K6_WEB_DASHBOARD=true -e K6_WEB_DASHBOARD_HOST=0.0.0.0 \
		-e DEMO_VUS=$(DEMO_VUS) -e DEMO_DURATION=$(DEMO_DURATION) \
		grafana/k6:2.3.0 run scenarios/demo.js || [ $$? = 99 ]

# ==============================================================================
# Docker Management & Cleanup
# ==============================================================================

## Stop and remove containers and build artifacts
clean:
	$(COMPOSE) --profile android down
	rm -rf $(BUILD_DIR) $(BACKEND_DIR)/coverage.out $(BACKEND_DIR)/coverage.html

## Full cleanup: remove containers, volumes, local images, orphans, and generated code.
## The phone image is named (image:), which --rmi local keeps: removed by hand.
fclean: clean buf-clean sqlc-clean
	$(COMPOSE) --profile android down -v --rmi local --remove-orphans
	docker image rm -f $(PHONE_IMAGE)
	rm -rf $(OPENAPI_OUT)

## Clean everything and restart Docker containers
re: fclean all

# ==============================================================================
# Protobuf / Buf Tooling
# ==============================================================================

## Update Buf dependencies
buf-dep:
	buf dep update

## Lint protocol buffer files
buf-lint:
	buf lint

## Format protocol buffer files
buf-format:
	buf format -w

## Generate code from proto using buf (Go backend, Dart stubs, OpenAPI spec)
buf-generate:
	buf generate
	$(API_BARREL)

## Check for breaking changes against git main branch
buf-breaking:
	buf breaking --against '.git#branch=main'

## Clean generated code and artifacts from buf-generate
buf-clean:
	rm -rf $(BACKEND_DIR)/gen $(FRONTEND_DIR)/lib/gen

## Clean and regenerate code from proto in one step
buf-rebuild: buf-clean buf-generate

# ==============================================================================
# SQLC Code Generation
# ==============================================================================

## Generate Go code from SQL queries using sqlc
sqlc-generate:
	cd $(BACKEND_DIR) && sqlc generate

## Clean generated Go code from SQL queries
sqlc-clean:
	rm -rf $(BACKEND_DIR)/db/sqlc

### Clean and regenerate Go code from SQL queries in one step
sqlc-rebuild: sqlc-clean sqlc-generate

# ==============================================================================
# Frontend & OpenAPI Code Generation
# ==============================================================================

## openapi-generator from the host if installed, otherwise its Docker image
## (run as the current user so the generated files are not root-owned).
OPENAPI_GENERATOR ?= $(if $(shell command -v openapi-generator),openapi-generator,\
	docker run --rm -u $(shell id -u):$(shell id -g) -v "$(CURDIR):/work" -w /work \
	openapitools/openapi-generator-cli:v7.25.0)

## lib/gen/api.dart, the app's single import of everything generated: derived
## from the generated tree, so it is rewritten after each half of it.
API_BARREL = sh $(FRONTEND_DIR)/tool/write_api_barrel.sh $(FRONTEND_DIR)/lib/gen

## Generate Dart client using openapi-generator
generate-openapi:
	$(OPENAPI_GENERATOR) generate \
		-i $(SWAGGER_PATH) \
		-g dart \
		-o $(OPENAPI_OUT) \
		--additional-properties=pubName=$(PUB_NAME) \
		--additional-properties=nullableFields=false,legacyDiscriminatorBehavior=false \
		--global-property=apiTests=false,modelTests=false,apiDocs=false,modelDocs=false
	$(API_BARREL)

## The app imports the generated client, so frontend targets need it; `make`
## wipes lib/gen (buf-clean) and only regenerates the proto stubs.
$(SWAGGER_PATH):
	$(MAKE) buf-generate

$(OPENAPI_OUT): $(SWAGGER_PATH)
	$(MAKE) generate-openapi

## Generate code using build_runner in the frontend app directory
build-runner:
	cd $(FRONTEND_DIR) && dart run build_runner build --delete-conflicting-outputs

## Clean the build_runner cache
build-runner-clean:
	cd $(FRONTEND_DIR) && dart run build_runner clean

## Clean cache and regenerate Flutter code in one step
rebuild-runner: build-runner-clean build-runner

## Run all code generation pipelines sequentially
generate: buf-generate generate-openapi build-runner

# ----------------------------------------------------------------------
# Apple config
# ----------------------------------------------------------------------

# ----------------------------------------------------------------------
# 1. Config Setup (Run once when setting up the repository)
# ----------------------------------------------------------------------
setup-local-configs:
	@if [ ! -f $(MACOS_LOCAL_CONFIG) ]; then \
		echo "Creating $(MACOS_LOCAL_CONFIG)..."; \
		if [ -f $(MACOS_DIR)/Runner/Configs/Local.xcconfig.template ]; then \
			cp $(MACOS_DIR)/Runner/Configs/Local.xcconfig.template $(MACOS_LOCAL_CONFIG); \
		else \
			printf "DEVELOPMENT_TEAM = \nPRODUCT_BUNDLE_IDENTIFIER = com.echoroom.musicroom.local\nCODE_SIGN_STYLE = Automatic\n" > $(MACOS_LOCAL_CONFIG); \
		fi; \
	else \
		echo "$(MACOS_LOCAL_CONFIG) already exists."; \
	fi
	@if [ ! -f $(IOS_LOCAL_CONFIG) ]; then \
		echo "Creating $(IOS_LOCAL_CONFIG)..."; \
		if [ -f $(IOS_DIR)/Flutter/Local.xcconfig.template ]; then \
			cp $(IOS_DIR)/Flutter/Local.xcconfig.template $(IOS_LOCAL_CONFIG); \
		else \
			printf "DEVELOPMENT_TEAM = \nPRODUCT_BUNDLE_IDENTIFIER = com.echoroom.musicroom.local\nCODE_SIGN_STYLE = Automatic\n" > $(IOS_LOCAL_CONFIG); \
		fi; \
	else \
		echo "$(IOS_LOCAL_CONFIG) already exists."; \
	fi
	@echo "⚠️  Please open and update your DEVELOPMENT_TEAM and PRODUCT_BUNDLE_IDENTIFIER in:"
	@echo "   - $(MACOS_LOCAL_CONFIG)"
	@echo "   - $(IOS_LOCAL_CONFIG)"

