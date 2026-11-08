package main

import "fmt"

// Devices: every account that signs in from somewhere has at least one, and
// Alex has the two the Permissions mock page already names. Control grants are
// built after the events (buildGrants), because some are scoped to one.

type deviceSpec struct {
	owner              int
	name, platform     string
	model, os, version string
	active             bool
}

func (w *World) addDevice(s deviceSpec) *Device {
	created := w.between(w.Users[s.owner].CreatedAt, w.ago(day))
	d := &Device{
		Idx: len(w.Devices), PublicID: publicID(kindDevice, len(w.Devices)+1),
		Owner: s.owner, Identifier: fmt.Sprintf("seed-%s-%04d", s.platform, len(w.Devices)+1),
		Name: s.name, Platform: s.platform, Model: s.model, OSVersion: s.os, AppVersion: s.version,
		Active: s.active, CreatedAt: created,
	}
	d.LastSeen = w.between(created, w.ago(10*minute))
	w.Devices = append(w.Devices, d)
	return d
}

// Named devices other steps refer to.
var (
	devAlexPhone, devAlexSoundbar, devSarahPhone, devLiamPhone int
)

func (w *World) buildDevices() {
	personas := []deviceSpec{
		{uAlex, "Alex's iPhone 15 Pro", "ios", "iPhone16,1", "iOS 18.6", "1.4.0", true},
		{uAlex, "Living Room Soundbar", "android", "Sonos Arc (Android TV)", "Android 13", "1.4.0", true},
		{uAlex, "MacBook Air", "desktop", "MacBookAir15,12", "macOS 15.5", "1.3.2", true},
		{uAlex, "Old Pixel 6", "android", "Pixel 6", "Android 14", "1.1.0", false},
		{uSarah, "Sarah's Pixel 8", "android", "Pixel 8", "Android 15", "1.4.0", true},
		{uSarah, "Studio PC", "desktop", "Windows 11 desktop", "Windows 11 24H2", "1.4.0", true},
		{uSarah, "Chrome on Linux", "web", "Chrome 139", "Ubuntu 24.04", "1.4.0", true},
		{uLiam, "Liam's iPhone 13", "ios", "iPhone14,5", "iOS 17.7", "1.3.2", true},
		{uLiam, "Chromebook", "web", "Chrome 138", "ChromeOS 138", "1.3.0", true},
		{uEmma, "Galaxy S24", "android", "SM-S921B", "Android 15", "1.4.0", true},
		{uEmma, "Emma's iPad", "ios", "iPad13,18", "iPadOS 18.5", "1.4.0", true},
		{uNoah, "iPhone SE", "ios", "iPhone14,6", "iOS 18.6", "1.4.0", true},
		{uGhost, "Firefox", "web", "Firefox 141", "Windows 10", "1.2.0", true},
		{uGoogle, "Pixel 7a", "android", "Pixel 7a", "Android 15", "1.4.0", true},
		{uIntra42, "42 iMac e1r2p3", "desktop", "iMac21,1", "macOS 14.7", "1.4.0", true},
		{uSuspended, "Galaxy A54", "android", "SM-A546B", "Android 14", "1.2.0", true},
		{uLongName, "ThinkPad X1", "desktop", "ThinkPad X1 Carbon Gen 12", "Fedora 42", "1.4.0", true},
		{uLongName, "Safari on iPhone", "web", "Safari 18", "iOS 18.6", "1.4.0", true},
	}
	for i, s := range personas {
		d := w.addDevice(s)
		switch i {
		case 0:
			devAlexPhone = d.Idx
		case 1:
			devAlexSoundbar = d.Idx
		case 4:
			devSarahPhone = d.Idx
		case 7:
			devLiamPhone = d.Idx
		}
	}

	models := []deviceSpec{
		{0, "iPhone", "ios", "iPhone15,2", "iOS 18.5", "1.4.0", true},
		{0, "Android phone", "android", "Pixel 9", "Android 15", "1.4.0", true},
		{0, "Galaxy", "android", "SM-S911B", "Android 14", "1.3.2", true},
		{0, "Laptop", "desktop", "Dell XPS 13", "Windows 11 23H2", "1.4.0", true},
		{0, "Browser", "web", "Chrome 139", "macOS 15", "1.4.0", true},
		{0, "Tablet", "ios", "iPad14,1", "iPadOS 17.7", "1.2.0", false},
	}
	for _, c := range pick(w, w.crowd(), 52) {
		s := models[w.rng.IntN(len(models))]
		s.owner = c
		s.name = fmt.Sprintf("%s's %s", firstWord(w.Users[c].DisplayName), s.name)
		w.addDevice(s)
	}
}

func firstWord(s string) string {
	for i, r := range s {
		if r == ' ' {
			return s[:i]
		}
	}
	return s
}

// devicesOf lists u's devices.
func (w *World) devicesOf(u int) []int {
	var out []int
	for _, d := range w.Devices {
		if d.Owner == u {
			out = append(out, d.Idx)
		}
	}
	return out
}
