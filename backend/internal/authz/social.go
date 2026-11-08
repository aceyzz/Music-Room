package authz

// Tuple constructors for blocks, the social half of the user type.
//
// Blocking is SYMMETRIC in the graph and asymmetric in Postgres: user_blocks is
// directional by design, but a one-way block is a mute, not a harassment
// control. The model's comment on `blocked` says so. Enforcement is symmetric,
// so one row becomes two tuples.
//
// The change concerns TWO objects, and ObjectKey only holds one. Ordering is
// per-object, so the key has to be stable across every change to the same
// pair -- otherwise a block and an unblock can be ordered against different
// keys and applied out of order. pairKey picks the lexicographically smaller of
// the two, which is stable regardless of who initiated.
//
// Friendships are not in the graph: nothing in the model reads them. The
// friends-only profile fields are applied by GetUser from the friendships row.

// pairKey is the deterministic ObjectKey for a change concerning two users.
func pairKey(aPublicID, bPublicID string) string {
	first, second := UserRef(aPublicID), UserRef(bPublicID)
	if second < first {
		first, second = second, first
	}
	return first
}

// mirrored returns the tuple in both directions.
func mirrored(relation Relation, aPublicID, bPublicID string) []Tuple {
	a, b := UserRef(aPublicID), UserRef(bPublicID)
	return []Tuple{
		{User: b, Relation: relation, Object: a},
		{User: a, Relation: relation, Object: b},
	}
}

// Block writes the symmetric block.
//
// `blocked` subtracts from can_view_profile, can_send_friend_request and
// can_receive_invitation, so these two tuples are what stands between a
// blocked user and a profile. The device grants the friendship authorised are
// revoked in Postgres by the same transaction (user.Repository.Block).
func Block(blockerPublicID, blockedPublicID string) Change {
	return Change{
		ObjectKey: pairKey(blockerPublicID, blockedPublicID),
		Origin:    OriginBlock,
		Writes:    mirrored(RelBlocked, blockerPublicID, blockedPublicID),
	}
}

// Unblock removes the symmetric block.
//
// It does NOT restore the friendship: blocking deleted the friendships row,
// and the two users must befriend again, which is the product behaviour.
func Unblock(blockerPublicID, blockedPublicID string) Change {
	return Change{
		ObjectKey: pairKey(blockerPublicID, blockedPublicID),
		Origin:    OriginUnblock,
		Deletes:   mirrored(RelBlocked, blockerPublicID, blockedPublicID),
	}
}
