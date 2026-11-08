package event

import (
	"context"
	"errors"
	"time"

	db "example.com/music-app/db/sqlc"
	pb "example.com/music-app/gen/go/music_room/v1"
	"example.com/music-app/internal/authz"
	"example.com/music-app/internal/realtime"
	songservice "example.com/music-app/internal/songs"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// CreateEvent démarre une playlist en direct. Si source_playlist_id est
// fourni, la file de vote est initialisée avec les morceaux de cette
// playlist.
func (s *Service) CreateEvent(ctx context.Context, req *pb.CreateEventRequest) (*pb.CreateEventResponse, error) {
	if req.GetHostId() <= 0 || req.GetName() == "" {
		return nil, status.Error(codes.InvalidArgument, "host_id and name are required")
	}
	visibility, err := validVisibility(req.GetVisibility())
	if err != nil {
		return nil, err
	}
	voteLicense, err := validVoteLicense(req.GetVoteLicense())
	if err != nil {
		return nil, err
	}
	startsAt, endsAt, err := eventWindow(req.GetStartsAt(), req.GetEndsAt(), time.Now())
	if err != nil {
		return nil, err
	}
	venueLatitude := optionalNumeric(req.GetVenueLatitude())
	venueLongitude := optionalNumeric(req.GetVenueLongitude())
	windowStart, err := parseVoteWindowTime(req.GetVoteWindowStart())
	if err != nil {
		return nil, err
	}
	windowEnd, err := parseVoteWindowTime(req.GetVoteWindowEnd())
	if err != nil {
		return nil, err
	}
	if voteLicense == string(db.VoteLicenseLocationTime) {
		hasVenue := venueLatitude.Valid && venueLongitude.Valid && req.GetVenueRadiusMeters() > 0
		hasWindow := windowStart.Valid && windowEnd.Valid && req.GetVoteWindowTimezone() != ""
		if err := requireVenueAndWindow(hasVenue, hasWindow); err != nil {
			return nil, err
		}
	}

	// Ces lectures étaient dans la transaction ; elles n'ont pas besoin d'y être.
	// La file semée est un instantané dans les deux cas, et la transaction n'a
	// plus à rester ouverte pendant un parcours de playlist.
	queries := db.New(s.pool)

	// host_id vient de la session, et la playlist source a déjà été résolue ET
	// vérifiée en lecture (playlist#can_view) : semer un événement avec une
	// playlist est une lecture de cette playlist, et ne pas la vérifier
	// laisserait n'importe qui recopier une playlist privée dans un événement
	// public.
	var sourceSongIDs []int64
	if req.GetSourcePlaylistId() > 0 {
		sourceSongs, err := queries.GetPlaylistSongsByPlaylistID(ctx, req.GetSourcePlaylistId())
		if err != nil {
			return nil, databaseError(err)
		}
		sourceSongIDs = make([]int64, len(sourceSongs))
		for i, song := range sourceSongs {
			sourceSongIDs[i] = song.SongID
		}
	}

	created, err := s.repo.Create(ctx, CreateParams{
		Insert: db.CreateEventSimpleParams{
			HostID: req.GetHostId(), SourcePlaylistID: req.GetSourcePlaylistId(),
			Name: req.GetName(), Description: req.GetDescription(),
			Visibility: db.ResourceVisibility(visibility), VoteLicense: db.VoteLicense(voteLicense),
			VenueLatitude: venueLatitude, VenueLongitude: venueLongitude, VenueRadiusMeters: req.GetVenueRadiusMeters(),
			VoteWindowStart: windowStart, VoteWindowEnd: windowEnd, VoteWindowTimezone: req.GetVoteWindowTimezone(),
			StartsAt: startsAt, EndsAt: endsAt,
		},
		SourceSongIDs: sourceSongIDs,
	})
	if err != nil {
		return nil, databaseError(err)
	}

	// Pas de démarrage automatique, même seedé depuis une playlist : la radio
	// ne part que quand l'hôte appuie sur lecture (docs/todo.md §4, D3).
	// C'est ce geste qui fixera l'appareil qui joue le son (D1).
	queueDto, err := s.listQueue(ctx, created.ID, req.GetHostId())
	if err != nil {
		return nil, err
	}
	return &pb.CreateEventResponse{Event: eventDTO(created), Queue: queueDto}, nil
}

// SuggestSong ajoute un morceau à la file de vote en direct, en le récupérant
// depuis Deezer et en le mettant en cache si nécessaire (même logique que
// AddSongToPlaylist).
func (s *Service) SuggestSong(ctx context.Context, req *pb.SuggestSongRequest) (*pb.SuggestSongResponse, error) {
	if req.GetEventId() <= 0 || req.GetDeezerSongId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "event_id and deezer_song_id are required")
	}
	queries := db.New(s.pool)

	event, err := queries.GetEventByID(ctx, req.GetEventId())
	if err != nil {
		return nil, databaseError(err)
	}
	// event#can_suggest_song a déjà répondu : visibilité ET licence de vote,
	// créneau horaire compris pour location_time. Reste le rayon.
	if err := requireVoteResiduals(event, req.GetSuggesterLatitude(), req.GetSuggesterLongitude()); err != nil {
		return nil, err
	}

	// Le cache du catalogue est global et n'a pas à être atomique avec l'entrée
	// de file : sur le pool, donc, et non dans la transaction. Ce qui y était
	// avant maintenait un verrou ouvert pendant un appel réseau à Deezer, et un
	// rollback ne laissait de toute façon qu'une ligne songs de trop -- un cache
	// tiède, pas une incohérence.
	songService := songservice.NewService(s.deezer, s.pool)
	storedSong, err := songService.GetSongByDeezerID(ctx, req.GetDeezerSongId())
	if err != nil {
		storedSong, err = songService.AddSongFromDeezer(ctx, req.GetDeezerSongId())
		if err != nil {
			return nil, status.Errorf(codes.Internal, "could not add song from Deezer: %v", err)
		}
	}

	if _, err := s.repo.SuggestSong(ctx, req.GetEventId(), storedSong.ID, req.GetUserId()); err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return nil, status.Error(codes.AlreadyExists, "song already queued for this event")
		}
		return nil, databaseError(err)
	}

	// Pas de démarrage automatique, même si rien ne joue : la radio ne part
	// que quand l'hôte appuie sur lecture (docs/todo.md §4, D3).
	queueDto, err := s.listQueue(ctx, req.GetEventId(), req.GetUserId())
	if err != nil {
		return nil, err
	}
	s.hub.Publish(realtime.Event(req.GetEventId()))
	return &pb.SuggestSongResponse{Event: eventDTO(event), Queue: queueDto}, nil
}

// CastVote enregistre un vote pour un morceau en attente. Zéro ligne affectée
// est un résultat normal (déjà voté, ou morceau plus en attente) : ce n'est
// pas une erreur, la file est simplement relue.
func (s *Service) CastVote(ctx context.Context, req *pb.CastVoteRequest) (*pb.CastVoteResponse, error) {
	if req.GetEventId() <= 0 || req.GetQueueEntryId() <= 0 || req.GetUserId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "event_id, queue_entry_id and user_id are required")
	}
	queries := db.New(s.pool)
	event, err := queries.GetEventByID(ctx, req.GetEventId())
	if err != nil {
		return nil, databaseError(err)
	}
	// event#can_vote et queue_entry#can_vote ont déjà répondu -- le second
	// parce qu'il se résout par l'événement parent de l'entrée, ce qui est ce
	// qui fait échouer une entrée empruntée à un AUTRE événement.
	if err := requireVoteResiduals(event, req.GetVoterLatitude(), req.GetVoterLongitude()); err != nil {
		return nil, err
	}

	_, err = queries.CastQueueVote(ctx, db.CastQueueVoteParams{
		QueueEntryID:   req.GetQueueEntryId(),
		UserID:         req.GetUserId(),
		VoterLatitude:  optionalNumeric(req.GetVoterLatitude()),
		VoterLongitude: optionalNumeric(req.GetVoterLongitude()),
	})
	accepted := true
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			accepted = false
		} else {
			return nil, databaseError(err)
		}
	}

	queueDto, err := s.listQueue(ctx, req.GetEventId(), req.GetUserId())
	if err != nil {
		return nil, err
	}
	s.hub.Publish(realtime.Event(req.GetEventId()))
	return &pb.CastVoteResponse{Accepted: accepted, Queue: queueDto}, nil
}

// ListEventQueue lit la file de vote en direct, triée par nombre de votes
// puis par ordre d'arrivée à ce score (event_queue_entries_ranking_idx).
func (s *Service) ListEventQueue(ctx context.Context, req *pb.ListEventQueueRequest) (*pb.ListEventQueueResponse, error) {
	if req.GetEventId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "event_id is required")
	}
	queueDto, err := s.listQueue(ctx, req.GetEventId(), req.GetViewerId())
	if err != nil {
		return nil, err
	}
	return &pb.ListEventQueueResponse{Queue: queueDto}, nil
}

// RemoveQueueEntry un-suggère un morceau encore en attente.
// queue_entry#can_remove (le suggesteur OU l'hôte/admin de l'événement,
// authz/model.fga) est déjà vérifié par l'intercepteur, directement sur
// l'entrée -- pas besoin de revérifier ici qui a le droit, seulement si
// c'est encore possible (status = 'queued').
func (s *Service) RemoveQueueEntry(ctx context.Context, req *pb.RemoveQueueEntryRequest) (*pb.RemoveQueueEntryResponse, error) {
	if req.GetEventId() <= 0 || req.GetQueueEntryId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "event_id and queue_entry_id are required")
	}
	queries := db.New(s.pool)
	rows, err := queries.RemoveQueueEntry(ctx, req.GetQueueEntryId())
	if err != nil {
		return nil, databaseError(err)
	}
	if rows == 0 {
		return nil, status.Error(codes.FailedPrecondition, "this song is no longer queued")
	}

	event, err := queries.GetEventByID(ctx, req.GetEventId())
	if err != nil {
		return nil, databaseError(err)
	}
	queueDto, err := s.listQueue(ctx, req.GetEventId(), req.GetUserId())
	if err != nil {
		return nil, err
	}
	s.hub.Publish(realtime.Event(req.GetEventId()))
	return &pb.RemoveQueueEntryResponse{Event: eventDTO(event), Queue: queueDto}, nil
}

func (s *Service) GetMusicEvent(ctx context.Context, req *pb.GetMusicEventRequest) (*pb.GetMusicEventResponse, error) {
	if req.GetId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "id is required")
	}
	found, err := db.New(s.pool).GetEventByID(ctx, req.GetId())
	if err != nil {
		return nil, databaseError(err)
	}
	dto := eventDTO(found)
	dto.ViewerIsHost = found.HostID == req.GetViewerId()
	if err := s.fillPlayback(ctx, []*pb.MusicEventDTO{dto}); err != nil {
		return nil, err
	}
	return &pb.GetMusicEventResponse{Event: dto}, nil
}

// fillPlayback sets MusicEventDTO.playback and cover_url for events a list
// or an info page shows: one query each for all of them.
func (s *Service) fillPlayback(ctx context.Context, events []*pb.MusicEventDTO) error {
	ids := make([]int64, len(events))
	for i, e := range events {
		ids[i] = e.GetId()
	}
	rows, err := db.New(s.pool).GetEventPlaybackSummaries(ctx, ids)
	if err != nil {
		return databaseError(err)
	}
	byEvent := make(map[int64]db.GetEventPlaybackSummariesRow, len(rows))
	for _, row := range rows {
		byEvent[row.EventID] = row
	}
	covers, err := db.New(s.pool).GetEventCovers(ctx, ids)
	if err != nil {
		return databaseError(err)
	}
	coverOf := make(map[int64]string, len(covers))
	for _, row := range covers {
		coverOf[row.EventID] = row.CoverUrl
	}
	for _, e := range events {
		e.Playback = playbackLabel(byEvent[e.GetId()])
		e.CoverUrl = coverOf[e.GetId()]
	}
	return nil
}

// playbackLabel: idle without a song (also the zero row: never started),
// otherwise paused or playing.
func playbackLabel(row db.GetEventPlaybackSummariesRow) string {
	switch {
	case !row.HasSong:
		return "idle"
	case row.IsPaused:
		return "paused"
	default:
		return "playing"
	}
}

// InviteToEvent ajoute invitee_user_id aux invités d'un événement, pour
// qu'il puisse le trouver et voter même si l'événement est privé (V.2.1 :
// "invited users are the only ones who can find the event and vote"). Seul
// l'hôte peut inviter ; pas de flux d'acceptation séparé, le sujet ne
// décrit que des "invited users", jamais une invitation en attente.
func (s *Service) InviteToEvent(ctx context.Context, req *pb.InviteToEventRequest) (*pb.InviteToEventResponse, error) {
	if req.GetEventId() <= 0 || req.GetInviterUserId() <= 0 || req.GetInviteeUserId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "event_id, inviter_user_id and invitee_user_id are required")
	}
	// event#can_invite (hôte, admin ou editor) et user#can_receive_invitation
	// sur l'invité : deux objets, deux contrôles, déjà faits.
	if err := s.repo.AddMember(ctx, req.GetEventId(), req.GetInviteeUserId()); err != nil {
		return nil, databaseError(err)
	}
	return &pb.InviteToEventResponse{}, nil
}

// ListEventMembers liste les membres d'un événement (l'hôte inclus), pour
// qu'un appelant puisse savoir qui est invité à un événement privé.
func (s *Service) ListEventMembers(ctx context.Context, req *pb.ListEventMembersRequest) (*pb.ListEventMembersResponse, error) {
	if req.GetEventId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "event_id is required")
	}
	rows, err := db.New(s.pool).ListEventMembers(ctx, req.GetEventId())
	if err != nil {
		return nil, databaseError(err)
	}
	members := make([]*pb.EventMemberDTO, len(rows))
	for i, row := range rows {
		members[i] = &pb.EventMemberDTO{
			UserId: row.UserID, UserPublicId: row.PublicID.String(),
			DisplayName: row.DisplayName, AvatarStorageKey: row.AvatarStorageKey.String,
			Role: string(row.Role), JoinedAt: row.JoinedAt.Time.Unix(),
		}
	}
	return &pb.ListEventMembersResponse{Members: members}, nil
}

// SetEventVisibility rend un événement public ou privé après sa création.
// event#can_change_settings (hôte ou admin) a déjà répondu. Passé en privé,
// seuls ses membres le trouvent encore : les autres perdent can_view, et
// leurs WatchEvent ouverts se ferment au prochain envoi (watch.go).
func (s *Service) SetEventVisibility(ctx context.Context, req *pb.SetEventVisibilityRequest) (*pb.SetEventVisibilityResponse, error) {
	if req.GetEventId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "event_id is required")
	}
	visibility, err := validVisibility(req.GetVisibility())
	if err != nil {
		return nil, err
	}
	updated, err := s.repo.SetVisibility(ctx, req.GetEventId(), db.ResourceVisibility(visibility))
	if err != nil {
		return nil, databaseError(err)
	}
	s.hub.Publish(realtime.Event(req.GetEventId()))
	return &pb.SetEventVisibilityResponse{Event: eventDTO(updated)}, nil
}

// SetEventVoteLicense change la licence de vote (et son lieu/créneau pour
// location_time) après création. Réservé à l'hôte.
func (s *Service) SetEventVoteLicense(ctx context.Context, req *pb.SetEventVoteLicenseRequest) (*pb.SetEventVoteLicenseResponse, error) {
	if req.GetEventId() <= 0 || req.GetUserId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "event_id and user_id are required")
	}
	voteLicense, err := validVoteLicense(req.GetVoteLicense())
	if err != nil {
		return nil, err
	}
	venueLatitude := optionalNumeric(req.GetVenueLatitude())
	venueLongitude := optionalNumeric(req.GetVenueLongitude())
	windowStart, err := parseVoteWindowTime(req.GetVoteWindowStart())
	if err != nil {
		return nil, err
	}
	windowEnd, err := parseVoteWindowTime(req.GetVoteWindowEnd())
	if err != nil {
		return nil, err
	}
	if voteLicense == string(db.VoteLicenseLocationTime) {
		hasVenue := venueLatitude.Valid && venueLongitude.Valid && req.GetVenueRadiusMeters() > 0
		hasWindow := windowStart.Valid && windowEnd.Valid && req.GetVoteWindowTimezone() != ""
		if err := requireVenueAndWindow(hasVenue, hasWindow); err != nil {
			return nil, err
		}
	}

	// event#can_change_settings (hôte ou admin) a déjà répondu.
	updated, err := s.repo.SetVoteLicense(ctx, db.SetEventVoteLicenseParams{
		ID: req.GetEventId(), VoteLicense: db.VoteLicense(voteLicense),
		VenueLatitude: venueLatitude, VenueLongitude: venueLongitude, VenueRadiusMeters: req.GetVenueRadiusMeters(),
		VoteWindowStart: windowStart, VoteWindowEnd: windowEnd, VoteWindowTimezone: req.GetVoteWindowTimezone(),
	})
	if err != nil {
		return nil, databaseError(err)
	}
	s.hub.Publish(realtime.Event(req.GetEventId()))
	return &pb.SetEventVoteLicenseResponse{Event: eventDTO(updated)}, nil
}

// GetMusicEvents liste tout événement que l'appelant peut voir : les siens
// (host, admin, editor ou simple viewer -- n'importe quel rôle), plus tout
// événement public, tout hôte confondu.
//
// Avant docs/todo.md §3, cette RPC ne listait QUE les events hébergés par
// l'appelant (ListEventsByHost) -- un event public ou privé où il était
// seulement invité restait invisible ici, alors que GetMusicEvent (au
// singulier) l'aurait laissé passer. Même remède que
// PlaylistService.ListPlaylists (internal/playlist/service.go) : l'ancien
// filtre Go est remplacé par OpenFGA ListObjects(can_view), qui répond
// exactement la même question que celle déjà posée à l'intercepteur pour
// GetMusicEvent -- pas une seconde copie de la règle qui pourrait diverger.
func (s *Service) GetMusicEvents(ctx context.Context, req *pb.GetMusicEventsRequest) (*pb.GetMusicEventsResponse, error) {
	if req.GetUserId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "user_id is required")
	}
	publicIDs, err := s.authz.ListObjects(ctx, authz.UserRef(req.GetUserPublicId()), authz.PermEventView, authz.TypeEvent)
	if err != nil {
		return nil, status.Error(codes.Internal, "could not list visible events")
	}
	if len(publicIDs) == 0 {
		return &pb.GetMusicEventsResponse{Events: []*pb.MusicEventDTO{}}, nil
	}

	ids := make([]pgtype.UUID, 0, len(publicIDs))
	for _, id := range publicIDs {
		var parsed pgtype.UUID
		if err := parsed.Scan(id); err != nil {
			// Same tolerance as ListPlaylists: an id ListObjects returned
			// that Postgres does not recognise as a UUID can only come from
			// a hand-written tuple, not a real event -- skip it rather than
			// fail the whole list for everyone else's.
			continue
		}
		ids = append(ids, parsed)
	}

	found, err := db.New(s.pool).GetEventsByPublicIDs(ctx, ids)
	if err != nil {
		return nil, databaseError(err)
	}
	eventIDs := make([]int64, len(found))
	for i, e := range found {
		eventIDs[i] = e.ID
	}
	memberOf, err := db.New(s.pool).ListUserEventMemberships(ctx, db.ListUserEventMembershipsParams{
		UserID: req.GetUserId(), EventIds: eventIDs,
	})
	if err != nil {
		return nil, databaseError(err)
	}
	member := make(map[int64]bool, len(memberOf))
	for _, id := range memberOf {
		member[id] = true
	}
	events := make([]*pb.MusicEventDTO, len(found))
	for i, e := range found {
		events[i] = eventDTO(e)
		events[i].ViewerIsHost = e.HostID == req.GetUserId()
		events[i].ViewerIsMember = events[i].ViewerIsHost || member[e.ID]
	}
	if err := s.fillPlayback(ctx, events); err != nil {
		return nil, err
	}
	return &pb.GetMusicEventsResponse{Events: events}, nil
}

// listQueue charge la file de vote d'un événement, déjà convertie en DTO.
func (s *Service) listQueue(ctx context.Context, eventID, viewerID int64) ([]*pb.EventQueueEntryDTO, error) {
	rows, err := db.New(s.pool).ListEventQueue(ctx, db.ListEventQueueParams{
		EventID: eventID, ViewerID: viewerID,
	})
	if err != nil {
		return nil, databaseError(err)
	}
	dtos := make([]*pb.EventQueueEntryDTO, len(rows))
	for i, row := range rows {
		dtos[i] = &pb.EventQueueEntryDTO{
			Id: row.ID, PublicId: row.PublicID.String(), EventId: eventID, VoteCount: int64(row.VoteCount),
			ScoreReachedAt: row.ScoreReachedAt.Time.Unix(), SuggestedById: row.SuggestedByID.Int64,
			ViewerHasVoted: row.ViewerHasVoted, Song: songDTO(row.Song),
		}
	}
	return dtos, nil
}
