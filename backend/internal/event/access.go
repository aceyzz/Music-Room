package event

import (
	"context"
	"errors"
	"math"
	"time"

	db "example.com/music-app/db/sqlc"
	"example.com/music-app/internal/auth/authn"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// canViewEvent et canVoteInEvent vivaient ici.
//
// Elles répondaient en Go, depuis events.visibility / events.vote_license /
// event_members, à ce que le graphe répond maintenant : event#can_view et
// event#can_vote (ou can_suggest_song), posés par l'intercepteur avant le
// handler (internal/interceptor/policy.go). Elles sont supprimées plutôt que
// gardées en second avis : deux systèmes de permissions qui répondent à la
// même question finissent par diverger, et c'est alors le plus permissif qui
// gagne.
//
// Ce qui reste dans ce fichier est exactement ce que le graphe ne peut pas
// savoir, et la liste est courte : la distance au lieu (CEL n'a pas de
// fonctions géospatiales), la validation d'entrée de la licence
// location_time, et la délégation de lecture -- voir canControlPlayback.

// requireVoteResiduals vérifie ce qu'il reste à vérifier après event#can_vote,
// sous une licence location_time.
//
// Le créneau horaire est une condition CEL portée par le tuple window_vote et
// a donc déjà été évalué ; il est revérifié ici pour une raison précise : la
// condition compare l'heure au créneau, et la vérification Go compare la même
// chose à la même horloge, donc elles ne peuvent pas diverger -- mais le
// rayon, lui, n'existe que de ce côté. Un Check qui passe veut dire "dans le
// créneau", jamais "sur place" (docs/permissions.md §11).
//
// Coordonnées absentes (0,0) : refusé. Sous cette licence, ne pas dire où on
// est n'est pas la même chose qu'être au bon endroit.
func requireVoteResiduals(event db.Event, lat, lon float64) error {
	// docs/permissions.md §11 : on suggère et on vote tant que l'événement
	// n'est pas `ended` (terminal) -- avant le début comme pendant une pause,
	// pour préparer la suite. Pas un tuple et ça ne le sera pas (le statut
	// change à chaque pause, ce serait une écriture de tuple par action de
	// lecture) : c'est le seul endroit qui le vérifie.
	if event.Status == db.EventStatusEnded {
		return status.Error(codes.FailedPrecondition, "this event is not open for suggestions or votes")
	}
	if event.VoteLicense != db.VoteLicenseLocationTime {
		return nil
	}
	if !withinVoteWindow(event) {
		return status.Error(codes.PermissionDenied, "outside this event's vote window")
	}
	if !withinVenueRadius(event, lat, lon) {
		return status.Error(codes.PermissionDenied, "outside this event's venue radius")
	}
	return nil
}

// canControlPlayback : l'hôte pilote toujours la lecture ; un ami, s'il a une
// licence active pour cet événement sur l'enceinte (speaker_device_id,
// l'appareil du premier play de l'hôte). Une licence donne tout le lecteur :
// pause / reprise, suivant, position.
//
// L'enceinte, pas un appareil nommé dans la requête : la licence est propre à
// un appareil (V.2.2), celui qui joue le son, et un délégué ne peut pas en
// choisir un autre. Sans enceinte, seul l'hôte pilote.
//
// En SQL, pas dans OpenFGA : une licence est propre à un couple (appareil,
// événement), et un ami peut en avoir une par événement sur le même appareil,
// alors qu'un tuple est unique par (ami, appareil). La requête
// (ResolveDeviceControlLicense) écarte elle-même les licences révoquées ou
// expirées.
func (s *Service) canControlPlayback(ctx context.Context, queries *db.Queries, event db.Event, userID int64) (bool, error) {
	if event.HostID == userID {
		return true, nil
	}
	playback, err := queries.GetEventPlaybackState(ctx, event.ID)
	if err != nil {
		return false, databaseError(err)
	}
	if !playback.SpeakerDeviceID.Valid {
		return false, nil
	}
	_, err = queries.ResolveDeviceControlLicense(ctx, db.ResolveDeviceControlLicenseParams{
		DeviceID: playback.SpeakerDeviceID.Int64, GranteeUserID: userID,
		EventID: pgtype.Int8{Int64: event.ID, Valid: true},
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return false, nil
		}
		return false, databaseError(err)
	}
	return true, nil
}

// claimSpeaker fait de l'appareil de la session l'enceinte de l'événement
// s'il n'en a pas encore (docs/todo.md §4, D1) -- seulement quand c'est
// l'hôte qui appuie : un délégué pilote l'enceinte, il ne la déplace pas
// chez lui. DeviceID vaut 0 tant que l'app n'a pas appelé RegisterDevice :
// pas d'enceinte alors, et l'hôte reste seul à piloter.
func (s *Service) claimSpeaker(ctx context.Context, queries *db.Queries, event db.Event, userID int64) error {
	identity, _ := authn.FromContext(ctx)
	if event.HostID != userID || identity.DeviceID <= 0 {
		return nil
	}
	if err := queries.ClaimEventSpeaker(ctx, db.ClaimEventSpeakerParams{
		EventID: event.ID, DeviceID: pgtype.Int8{Int64: identity.DeviceID, Valid: true},
	}); err != nil {
		return databaseError(err)
	}
	return nil
}

// requireVenueAndWindow vérifie, à la création d'un événement, que la
// licence "location_time" a bien tous les champs dont elle a besoin
// (contrainte events_location_time_license_check en base).
func requireVenueAndWindow(hasVenue, hasWindow bool) error {
	if !hasVenue || !hasWindow {
		return status.Error(codes.InvalidArgument,
			"vote_license location_time requires venue_latitude, venue_longitude, venue_radius_meters, "+
				"vote_window_start, vote_window_end and vote_window_timezone")
	}
	return nil
}

// withinVoteWindow reporte si l'heure actuelle, dans le fuseau horaire du
// lieu, tombe dans le créneau quotidien autorisé (ex. 16h-18h). Gère le cas
// d'un créneau qui traverse minuit.
func withinVoteWindow(event db.Event) bool {
	loc, err := time.LoadLocation(event.VoteWindowTimezone.String)
	if err != nil {
		return false
	}
	now := time.Now().In(loc)
	nowOfDay := time.Duration(now.Hour())*time.Hour +
		time.Duration(now.Minute())*time.Minute +
		time.Duration(now.Second())*time.Second
	start := time.Duration(event.VoteWindowStart.Microseconds) * time.Microsecond
	end := time.Duration(event.VoteWindowEnd.Microseconds) * time.Microsecond
	if start <= end {
		return nowOfDay >= start && nowOfDay <= end
	}
	return nowOfDay >= start || nowOfDay <= end // le créneau traverse minuit.
}

// withinVenueRadius reporte si (lat, lon) se trouve à moins de
// venue_radius_meters du lieu de l'événement.
func withinVenueRadius(event db.Event, lat, lon float64) bool {
	venueLat, err := event.VenueLatitude.Float64Value()
	if err != nil || !venueLat.Valid {
		return false
	}
	venueLon, err := event.VenueLongitude.Float64Value()
	if err != nil || !venueLon.Valid {
		return false
	}
	if !event.VenueRadiusMeters.Valid {
		return false
	}
	distance := haversineMeters(venueLat.Float64, venueLon.Float64, lat, lon)
	return distance <= float64(event.VenueRadiusMeters.Int32)
}

const earthRadiusMeters = 6371000.0

// haversineMeters calcule la distance orthodromique entre deux points en
// mètres.
func haversineMeters(lat1, lon1, lat2, lon2 float64) float64 {
	toRad := func(deg float64) float64 { return deg * math.Pi / 180 }
	dLat := toRad(lat2 - lat1)
	dLon := toRad(lon2 - lon1)
	a := math.Sin(dLat/2)*math.Sin(dLat/2) +
		math.Cos(toRad(lat1))*math.Cos(toRad(lat2))*math.Sin(dLon/2)*math.Sin(dLon/2)
	c := 2 * math.Atan2(math.Sqrt(a), math.Sqrt(1-a))
	return earthRadiusMeters * c
}
