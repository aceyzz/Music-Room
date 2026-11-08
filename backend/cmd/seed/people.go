package main

import (
	"fmt"
	"strings"
	"time"
)

// Accounts: 8 personas to log in as, 6 edge accounts that each show one state
// of an account, and a crowd of 108 that makes every list long enough to
// scroll, page and search.

// Fixed indices of the accounts other files refer to by name.
const (
	uAlex = iota
	uSarah
	uLiam
	uEmma
	uNoah
	uFresh
	uUnverified
	uGhost
	uSuspended
	uDeleted
	uGoogle
	uIntra42
	uOAuthOnly
	uLongName
	firstCrowd
)

const crowdSize = 108

var (
	visDefault = vis("friends", "friends", "public", "private", "friends", "private", "public")
	visPublic  = vis("public", "public", "public", "public", "public", "public", "public")
	visFriends = vis("friends", "friends", "friends", "friends", "friends", "friends", "friends")
	visPrivate = vis("private", "private", "private", "private", "private", "private", "private")
)

// vis builds a profile's visibility, in Profile.Visibility order.
func vis(scopes ...string) [7]string {
	return [7]string(scopes)
}

func (w *World) addUser(local, display string, created time.Time) *User {
	u := &User{
		Idx: len(w.Users), PublicID: publicID(kindUser, len(w.Users)+1),
		Email: local + "@" + EmailDomain, DisplayName: display,
		HasPassword: true, Status: "active", Verified: true, CreatedAt: created,
		Profile: Profile{Visibility: visDefault},
	}
	w.Users = append(w.Users, u)
	return u
}

func (w *World) prefs(u *User, genreWeights ...any) {
	for i := 0; i+1 < len(genreWeights); i += 2 {
		id := genreWeights[i].(int64)
		u.Prefs = append(u.Prefs, Pref{GenreID: id, Genre: genreName(id), Weight: genreWeights[i+1].(int)})
	}
}

func (w *World) buildPeople() {
	// --- personas -----------------------------------------------------------
	alex := w.addUser("alex", "Alex Martin", w.ago(400*day))
	alex.Persona = "Main demo account"
	alex.LastLoginAt = ptr(w.ago(2 * hour))
	alex.Profile = Profile{
		FirstName: "Alex", LastName: "Martin",
		Bio:  "Runs the Friday warm-ups at 42 Paris. Will always queue Daft Punk. Ask me about vinyl.",
		City: "Paris", Country: "FR", Phone: "+33 6 12 34 56 78", BirthDate: "1997-04-18",
		Visibility: vis("public", "public", "public", "friends", "friends", "private", "public"),
	}
	alex.Avatar = w.newImage(alex.Idx, "avatar", w.ago(380*day))
	w.prefs(alex, int64(106), 5, int64(113), 4, int64(85), 3, int64(129), 2)

	sarah := w.addUser("sarah", "Sarah Chen", w.ago(390*day))
	sarah.Persona = "Alex's best friend, hosts events Alex is invited to"
	sarah.LastLoginAt = ptr(w.ago(5 * hour))
	sarah.Profile = Profile{
		FirstName: "Sarah", LastName: "Chen", Bio: "Jazz on weekdays, techno on weekends. Co-hosts Rooftop Sessions.",
		City: "Lyon", Country: "FR", Phone: "+33 6 98 76 54 32", BirthDate: "1996-11-02",
		Visibility: vis("public", "public", "public", "public", "public", "private", "public"),
	}
	sarah.Avatar = w.newImage(sarah.Idx, "avatar", w.ago(300*day))
	w.prefs(sarah, int64(129), 5, int64(106), 4, int64(165), 3)

	liam := w.addUser("liam", "Liam O'Connor", w.ago(350*day))
	liam.Persona = "Friend of Alex, default privacy settings"
	liam.LastLoginAt = ptr(w.ago(26 * hour))
	liam.Profile = Profile{
		FirstName: "Liam", LastName: "O'Connor", Bio: "Guitar, folk and too many festival wristbands.",
		City: "Dublin", Country: "IE", Phone: "+353 85 123 4567", BirthDate: "1994-03-09",
		Visibility: visDefault,
	}
	liam.Avatar = w.newImage(liam.Idx, "avatar", w.ago(340*day))
	w.prefs(liam, int64(466), 5, int64(152), 4, int64(85), 4)

	emma := w.addUser("emma", "Emma Rossi", w.ago(320*day))
	emma.Persona = "Friend of Alex, shares everything with friends only"
	emma.LastLoginAt = ptr(w.ago(3 * day))
	emma.Profile = Profile{
		FirstName: "Emma", LastName: "Rossi", Bio: "Classical pianist by day. Reggaeton by night.",
		City: "Milano", Country: "IT", Phone: "+39 333 123 4567", BirthDate: "1999-08-27",
		Visibility: visFriends,
	}
	emma.Avatar = w.newImage(emma.Idx, "avatar", w.ago(310*day))
	w.prefs(emma, int64(98), 5, int64(197), 4)

	noah := w.addUser("noah", "Noah Dubois", w.ago(60*day))
	noah.Persona = "Not Alex's friend yet: has sent Alex a friend request"
	noah.LastLoginAt = ptr(w.ago(40 * minute))
	noah.Profile = Profile{
		FirstName: "Noah", LastName: "Dubois", Bio: "New in Paris, looking for people to go to gigs with.",
		City: "Bruxelles", Country: "BE", Phone: "+32 470 12 34 56", BirthDate: "2001-01-15",
		Visibility: vis("friends", "friends", "public", "friends", "friends", "private", "friends"),
	}
	noah.Avatar = w.newImage(noah.Idx, "avatar", w.ago(59*day))
	w.prefs(noah, int64(116), 5, int64(2), 4, int64(165), 2)

	fresh := w.addUser("fresh", "Fresh Start", w.ago(10*minute))
	fresh.Persona = "Brand-new account: every empty state"
	fresh.LastLoginAt = ptr(w.ago(10 * minute))
	fresh.Profile = Profile{Visibility: visDefault}

	unverified := w.addUser("unverified", "Pending Pat", w.ago(5*minute))
	unverified.Persona = "Email not verified: the app opens /verify-email"
	unverified.Verified = false
	unverified.LastLoginAt = ptr(w.ago(5 * minute))

	ghost := w.addUser("ghost", "Ghost Mode", w.ago(200*day))
	ghost.Persona = "Every profile field private, no avatar"
	ghost.LastLoginAt = ptr(w.ago(9 * day))
	ghost.Profile = Profile{
		FirstName: "Gaspard", LastName: "Holt", Bio: "You will not read this.",
		City: "Genève", Country: "CH", Phone: "+41 79 123 45 67", BirthDate: "1990-12-01",
		Visibility: visPrivate,
	}
	w.prefs(ghost, int64(464), 5)

	// --- edge accounts ------------------------------------------------------
	suspended := w.addUser("suspended", "Suspended Sam", w.ago(250*day))
	suspended.Persona = "Status suspended: sign-in refused, hidden from search and friend lists"
	suspended.Status = "suspended"
	suspended.LastLoginAt = ptr(w.ago(30 * day))
	suspended.Profile = Profile{FirstName: "Sam", LastName: "Keller", City: "Zürich", Country: "CH", Visibility: visDefault}

	deleted := w.addUser("deleted", "Deleted Dana", w.ago(280*day))
	deleted.Persona = "Status deleted: hidden everywhere, sign-in refused"
	deleted.Status = "deleted"
	deleted.LastLoginAt = ptr(w.ago(90 * day))

	google := w.addUser("google", "Gabrielle Moreau", w.ago(150*day))
	google.Persona = "Password plus a linked Google account"
	google.LastLoginAt = ptr(w.ago(7 * hour))
	google.OAuth = []OAuthLink{{Provider: "google", ProviderUserID: "109876543210987654321"}}
	google.Profile = Profile{FirstName: "Gabrielle", LastName: "Moreau", City: "Nantes", Country: "FR", Visibility: visDefault}
	google.Avatar = w.newImage(google.Idx, "avatar", w.ago(149*day))
	w.prefs(google, int64(132), 5, int64(113), 3)

	intra := w.addUser("intra42", "ytanaka", w.ago(120*day))
	intra.Persona = "Password plus a linked 42 intra account"
	intra.LastLoginAt = ptr(w.ago(20 * hour))
	intra.OAuth = []OAuthLink{{Provider: "intra42", ProviderUserID: "184467"}}
	intra.Profile = Profile{
		FirstName: "Yuki", LastName: "Tanaka", Bio: "42 Paris student. Lo-fi while coding.",
		City: "Paris", Country: "FR", Visibility: visDefault,
	}
	intra.Avatar = w.newImage(intra.Idx, "avatar", w.ago(119*day))
	w.prefs(intra, int64(173), 5, int64(106), 4, int64(16), 2)

	oauthOnly := w.addUser("oauth-only", "Olivia Bennett", w.ago(45*day))
	oauthOnly.Persona = "Google only, no password: cannot sign in with a password"
	oauthOnly.HasPassword = false
	oauthOnly.LastLoginAt = ptr(w.ago(2 * day))
	oauthOnly.OAuth = []OAuthLink{{Provider: "google", ProviderUserID: "118273645546372819283"}}
	oauthOnly.Profile = Profile{FirstName: "Olivia", LastName: "Bennett", City: "London", Country: "GB", Visibility: visDefault}

	long := w.addUser("longname", "Maximilian Alexander Konstantin von Hohenberg-Wittelsbach III", w.ago(210*day))
	long.Persona = "60-character display name, very long bio"
	long.LastLoginAt = ptr(w.ago(4 * day))
	long.Profile = Profile{
		FirstName: "Maximilian Alexander Konstantin", LastName: "von Hohenberg-Wittelsbach",
		Bio:  strings.Repeat("Collector of obscure B-sides, rare pressings and unreasonably long sentences. ", 6),
		City: "Garmisch-Partenkirchen", Country: "DE", Phone: "+49 151 23456789", BirthDate: "1985-06-30",
		Visibility: visPublic,
	}
	long.Avatar = w.newImage(long.Idx, "avatar", w.ago(200*day))
	w.prefs(long, int64(98), 5, int64(129), 5, int64(169), 4, int64(152), 3, int64(466), 1)

	w.buildCrowd()
}

// --- the crowd --------------------------------------------------------------

type nameGroup struct {
	country string
	phone   string
	firsts  []string
	lasts   []string
	cities  []string
}

var nameGroups = []nameGroup{
	{"FR", "+33 6", []string{"Camille", "Léa", "Hugo", "Lucas", "Chloé", "Inès", "Mathis", "Manon", "Théo", "Zoé"},
		[]string{"Bernard", "Lefèvre", "Moreau", "Laurent", "Girard", "Fournier", "Mercier", "Faure"},
		[]string{"Paris", "Lyon", "Marseille", "Bordeaux", "Lille", "Nantes", "Toulouse"}},
	{"US", "+1 415", []string{"Jordan", "Taylor", "Morgan", "Riley", "Avery", "Jamal", "Brooke", "Tyler"},
		[]string{"Johnson", "Williams", "Brown", "Davis", "Miller", "Garcia"},
		[]string{"New York", "Austin", "Chicago", "Seattle", "New Orleans"}},
	{"DE", "+49 160", []string{"Lukas", "Mia", "Jonas", "Lena", "Felix", "Hannah"},
		[]string{"Müller", "Schmidt", "Fischer", "Weber", "Wagner"},
		[]string{"Berlin", "Hamburg", "München", "Köln", "Leipzig"}},
	{"ES", "+34 612", []string{"Lucía", "Mateo", "Sofía", "Pablo", "Valeria", "Álvaro"},
		[]string{"García", "Fernández", "López", "Martínez", "Núñez"},
		[]string{"Madrid", "Barcelona", "Sevilla", "Valencia"}},
	{"BR", "+55 11", []string{"João", "Ana", "Pedro", "Beatriz", "Gabriel", "Luíza"},
		[]string{"Silva", "Santos", "Oliveira", "Souza", "Conceição"},
		[]string{"São Paulo", "Rio de Janeiro", "Recife", "Salvador"}},
	{"JP", "+81 90", []string{"Kenji", "Yui", "Haruto", "Sakura", "Ren", "Aoi"},
		[]string{"Watanabe", "Suzuki", "Takahashi", "Sato", "Nakamura"},
		[]string{"Tokyo", "Osaka", "Kyoto", "Fukuoka"}},
	{"NG", "+234 803", []string{"Chinedu", "Amara", "Tunde", "Ngozi", "Femi", "Zainab"},
		[]string{"Okafor", "Adeyemi", "Balogun", "Eze", "Okonkwo"},
		[]string{"Lagos", "Abuja", "Port Harcourt"}},
	{"IN", "+91 98", []string{"Aarav", "Priya", "Rohan", "Ananya", "Vikram", "Meera"},
		[]string{"Sharma", "Patel", "Iyer", "Gupta", "Reddy"},
		[]string{"Mumbai", "Bengaluru", "Delhi", "Chennai"}},
	{"MA", "+212 6", []string{"Yasmine", "Karim", "Salma", "Mehdi", "Nour"},
		[]string{"El Amrani", "Benali", "Alaoui", "Tazi"},
		[]string{"Casablanca", "Rabat", "Marrakech"}},
	{"DK", "+45 20", []string{"Freja", "Oskar", "Astrid", "Emil", "Søren", "Ida"},
		[]string{"Kjær", "Nielsen", "Lindqvist", "Østergaard"},
		[]string{"København", "Aarhus", "Odense"}},
	{"CA", "+1 514", []string{"Félix", "Maëlle", "Olivier", "Charlotte", "Étienne"},
		[]string{"Tremblay", "Gagnon", "Roy", "Côté", "Bouchard"},
		[]string{"Montréal", "Québec", "Toronto", "Vancouver"}},
}

// Names in scripts other than Latin, spelled as their owners would. The email
// carries a romanised form, like a real sign-up would.
var unicodeNames = []struct{ display, first, last, local, country, city string }{
	{"李娜", "娜", "李", "li.na", "CN", "上海"},
	{"王伟", "伟", "王", "wang.wei", "CN", "北京"},
	{"김민준", "민준", "김", "kim.minjun", "KR", "서울"},
	{"محمد العلي", "محمد", "العلي", "mohammed.alali", "AE", "دبي"},
	{"Αλέξανδρος Παπαδόπουλος", "Αλέξανδρος", "Παπαδόπουλος", "alexandros.p", "GR", "Αθήνα"},
	{"Наталья Иванова", "Наталья", "Иванова", "natalia.ivanova", "UA", "Київ"},
}

var bios = []string{
	"Here for the music, staying for the people.",
	"Vinyl hunter. Sunday crate-digging is a sport.",
	"I make playlists for every mood, including 'Tuesday 4pm'.",
	"Bass player in a band you have never heard of (yet).",
	"Festival season is a state of mind.",
	"Will skip your song if it has a 2-minute intro.",
	"Night owl, synthwave enthusiast.",
	"Learning to DJ one awkward transition at a time.",
	"Karaoke champion of my building, 2025.",
	"Classical training, punk heart.",
	"Coffee, code and Afrobeats.",
	"Always the one holding the aux cable.",
	"",
}

var djTemplates = []string{"DJ %s", "dj_%s", "%s the DJ", "DJ %s Beats", "DJ Lil %s", "%s DJ Set", "DJ %s & Friends"}

// fold turns a display name into the local part of an email: lower case, ASCII,
// dots between words.
func fold(s string) string {
	r := strings.NewReplacer(
		"é", "e", "è", "e", "ê", "e", "ë", "e", "à", "a", "á", "a", "â", "a", "ã", "a",
		"í", "i", "ï", "i", "ó", "o", "ô", "o", "ú", "u", "ü", "u", "ç", "c", "ø", "o",
		"ö", "o", "ñ", "n", "æ", "ae", "å", "a", "ß", "ss", "Á", "a", "É", "e", "Ø", "o",
		"'", "", " ", ".",
	)
	return r.Replace(strings.ToLower(s))
}

func (w *World) buildCrowd() {
	usedEmails := map[string]bool{}
	usedNames := map[string]bool{}
	for _, u := range w.Users {
		usedEmails[strings.ToLower(u.Email)] = true
		usedNames[strings.ToLower(u.DisplayName)] = true
	}
	unique := func(set map[string]bool, s string, sep string) string {
		candidate := s
		for n := 2; set[strings.ToLower(candidate)]; n++ {
			candidate = fmt.Sprintf("%s%s%d", s, sep, n)
		}
		set[strings.ToLower(candidate)] = true
		return candidate
	}

	// Which crowd members get a DJ name: 30 of them, so a search for "dj"
	// returns more than the 20 the app shows.
	djs := map[int]bool{}
	for _, i := range w.rng.Perm(crowdSize - len(unicodeNames))[:30] {
		djs[i+len(unicodeNames)] = true
	}

	for i := 0; i < crowdSize; i++ {
		var first, last, local, display, country, city, phone string
		if i < len(unicodeNames) {
			n := unicodeNames[i]
			first, last, local, display, country, city = n.first, n.last, n.local, n.display, n.country, n.city
		} else {
			g := nameGroups[w.rng.IntN(len(nameGroups))]
			first = g.firsts[w.rng.IntN(len(g.firsts))]
			last = g.lasts[w.rng.IntN(len(g.lasts))]
			country, city = g.country, g.cities[w.rng.IntN(len(g.cities))]
			phone = fmt.Sprintf("%s %02d %02d %02d %02d", g.phone, w.rng.IntN(100), w.rng.IntN(100), w.rng.IntN(100), w.rng.IntN(100))
			local = fold(first + " " + last)
			switch {
			case djs[i]:
				display = fmt.Sprintf(djTemplates[w.rng.IntN(len(djTemplates))], first)
			case w.rng.IntN(4) == 0:
				display = fmt.Sprintf("%s.%s", strings.ToLower(fold(first)), strings.ToLower(fold(last)))
			case w.rng.IntN(6) == 0:
				display = fmt.Sprintf("%s%02d", fold(first), w.rng.IntN(100))
			default:
				display = first + " " + last
			}
		}
		display = unique(usedNames, display, " ")
		email := local + "@" + EmailDomain
		for n := 2; usedEmails[email]; n++ {
			email = fmt.Sprintf("%s%d@%s", local, n, EmailDomain)
		}
		usedEmails[email] = true

		u := w.addUser(strings.TrimSuffix(email, "@"+EmailDomain), display, w.between(w.ago(540*day), w.ago(3*day)))
		if w.rng.IntN(10) > 0 {
			u.LastLoginAt = ptr(w.between(u.CreatedAt, w.ago(10*minute)))
		}

		// Six profile shapes, from nothing filled in to everything private.
		bio := bios[w.rng.IntN(len(bios))]
		birth := fmt.Sprintf("%d-%02d-%02d", 1972+w.rng.IntN(35), 1+w.rng.IntN(12), 1+w.rng.IntN(28))
		switch w.rng.IntN(6) {
		case 0: // nothing filled in
			u.Profile = Profile{Visibility: visDefault}
		case 1:
			u.Profile = Profile{first, last, bio, city, country, phone, birth, visPublic}
		case 2:
			u.Profile = Profile{first, last, bio, city, country, phone, birth, visDefault}
		case 3: // partial
			u.Profile = Profile{FirstName: first, City: city, Country: country, Visibility: visFriends}
		case 4:
			u.Profile = Profile{first, last, bio, city, country, phone, birth, visFriends}
		default:
			u.Profile = Profile{first, last, bio, city, country, phone, birth, visPrivate}
		}
		if w.rng.IntN(4) > 0 {
			u.Avatar = w.newImage(u.Idx, "avatar", w.between(u.CreatedAt, w.ago(day)))
		}
		if w.rng.IntN(5) > 0 {
			for _, gi := range w.rng.Perm(len(Genres))[:1+w.rng.IntN(5)] {
				g := Genres[gi]
				u.Prefs = append(u.Prefs, Pref{GenreID: g.ID, Genre: g.Name, Weight: 1 + w.rng.IntN(5)})
			}
		}
	}
}

// crowd returns the indices of the crowd accounts.
func (w *World) crowd() []int {
	out := make([]int, 0, crowdSize)
	for i := firstCrowd; i < len(w.Users); i++ {
		out = append(out, i)
	}
	return out
}
