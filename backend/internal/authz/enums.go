package authz

// Mirrors of the Postgres enums that drive permissions.
//
// Duplicated rather than imported, for the same reason Scope is (see tuple.go):
// this package projects rows onto the graph and must not depend on the
// persistence layer to do it. The values are strings on both sides, so a caller
// converts with a cast -- and a cast is the point at which a renamed enum value
// stops matching, which is why every switch below has a fail-closed default.

// Visibility mirrors the resource_visibility enum, used by playlists and events.
type Visibility string

const (
	VisibilityPublic  Visibility = "public"
	VisibilityPrivate Visibility = "private"
)

// EditLicense mirrors the edit_license enum on playlists.
type EditLicense string

const (
	EditLicenseEveryone    EditLicense = "everyone"
	EditLicenseInvitedOnly EditLicense = "invited_only"
)

// VoteLicense mirrors the vote_license enum on events.
type VoteLicense string

const (
	VoteLicenseEveryone     VoteLicense = "everyone"
	VoteLicenseInvitedOnly  VoteLicense = "invited_only"
	VoteLicenseLocationTime VoteLicense = "location_time"
)

// MemberRole mirrors the member_role enum shared by playlist_members and
// event_members.
type MemberRole string

const (
	RoleOwner  MemberRole = "owner"
	RoleAdmin  MemberRole = "admin"
	RoleEditor MemberRole = "editor"
	RoleViewer MemberRole = "viewer"
)

// exclusiveFor returns the tuple for the relation a value maps to, plus the
// tuples for every OTHER relation in the same mutually exclusive set.
//
// Every enum-backed permission in the model has this shape: one column, several
// candidate relations, exactly one of which may exist. A playlist member's role,
// an event's vote licence, a profile field's visibility. Writing the new relation
// without deleting the others leaves a graph that answers yes twice -- and since
// these relations only ever GRANT, two yeses is the permissive failure. A
// demotion from admin to viewer that only wrote `viewer` still resolves as admin.
//
// So the deletes are always returned, including for relations the caller is
// confident are absent. Deleting an absent tuple is free (client.go swallows it),
// and the alternative is trusting a belief about current state, which is the
// assumption the whole outbox exists because we cannot make.
//
// selected may be the zero Relation, meaning "none of them apply": then every
// relation in the set is deleted and nothing is written. That is how a removed
// member, a private resource, or a field set back to private is spelled -- and it
// is why an unrecognised enum value fails closed rather than needing its own
// branch at each call site.
func exclusiveFor(object, subject string, set []Relation, selected Relation, condition *Condition) (writes, deletes []Tuple) {
	for _, relation := range set {
		// Deletes carry no condition -- a tuple is identified by its three parts.
		tuple := Tuple{User: subject, Relation: relation, Object: object}
		if relation == selected {
			writes = append(writes, Tuple{
				User: subject, Relation: relation, Object: object, Condition: condition,
			})
			continue
		}
		deletes = append(deletes, tuple)
	}
	return writes, deletes
}

// exclusive is exclusiveFor on the public wildcard, for the sets whose subject is
// always [user:*] -- visibility and licence flags.
func exclusive(object string, set []Relation, selected Relation, condition *Condition) (writes, deletes []Tuple) {
	return exclusiveFor(object, Everyone, set, selected, condition)
}
