package main

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"math"
	"math/rand/v2"
)

// Generated pictures for avatars and playlist covers: soft gradients and
// shapes, drawn with the standard library from a per-image seed, so a reseed
// draws the same files and no photo of anyone is needed.
//
// Both sizes are drawn rather than one resized into the other: the image
// service is not needed for seeding, and drawing at the target size looks the
// same. The thumbnail is 512 px, the size the upload paths store; the
// original is a little larger, as an upload would be.

const (
	thumbSize    = 512
	originalSize = 640
)

func hsv(h, s, v float64) color.RGBA {
	h = math.Mod(h, 360)
	c := v * s
	x := c * (1 - math.Abs(math.Mod(h/60, 2)-1))
	m := v - c
	var r, g, b float64
	switch {
	case h < 60:
		r, g, b = c, x, 0
	case h < 120:
		r, g, b = x, c, 0
	case h < 180:
		r, g, b = 0, c, x
	case h < 240:
		r, g, b = 0, x, c
	case h < 300:
		r, g, b = x, 0, c
	default:
		r, g, b = c, 0, x
	}
	return color.RGBA{uint8((r + m) * 255), uint8((g + m) * 255), uint8((b + m) * 255), 255}
}

func mix(a, b color.RGBA, t float64) color.RGBA {
	t = math.Max(0, math.Min(1, t))
	l := func(x, y uint8) uint8 { return uint8(float64(x)*(1-t) + float64(y)*t) }
	return color.RGBA{l(a.R, b.R), l(a.G, b.G), l(a.B, b.B), 255}
}

// renderImage draws one picture. Avatars are a gradient with soft blobs;
// covers add rings or stripes, so the two never look alike.
func renderImage(seed uint64, kind string, size int) []byte {
	r := rand.New(rand.NewPCG(seed, 7))
	hue := r.Float64() * 360
	from := hsv(hue, 0.55+r.Float64()*0.3, 0.85)
	to := hsv(hue+60+r.Float64()*120, 0.6+r.Float64()*0.3, 0.45+r.Float64()*0.3)
	angle := r.Float64() * math.Pi
	dx, dy := math.Cos(angle), math.Sin(angle)

	type blob struct {
		x, y, rad float64
		c         color.RGBA
	}
	blobs := make([]blob, 2+r.IntN(3))
	for i := range blobs {
		blobs[i] = blob{r.Float64(), r.Float64(), 0.15 + r.Float64()*0.3, hsv(hue+r.Float64()*200, 0.5, 0.95)}
	}
	pattern := r.IntN(3)
	freq := 6 + r.Float64()*10
	cx, cy := 0.3+r.Float64()*0.4, 0.3+r.Float64()*0.4

	img := image.NewRGBA(image.Rect(0, 0, size, size))
	for py := 0; py < size; py++ {
		y := float64(py) / float64(size)
		for px := 0; px < size; px++ {
			x := float64(px) / float64(size)
			c := mix(from, to, (x-0.5)*dx+(y-0.5)*dy+0.5)
			for _, b := range blobs {
				d := math.Hypot(x-b.x, y-b.y) / b.rad
				if d < 1 {
					c = mix(c, b.c, 0.45*(1-d*d))
				}
			}
			if kind == "cover" {
				var v float64
				switch pattern {
				case 0: // rings
					v = math.Sin(math.Hypot(x-cx, y-cy) * freq * 2 * math.Pi)
				case 1: // stripes
					v = math.Sin((x*dy - y*dx) * freq * 2 * math.Pi)
				default: // waves
					v = math.Sin((y + 0.08*math.Sin(x*freq)) * freq * 2 * math.Pi)
				}
				if v > 0.6 {
					c = mix(c, color.RGBA{255, 255, 255, 255}, 0.18)
				}
			}
			img.SetRGBA(px, py, c)
		}
	}
	var buf bytes.Buffer
	enc := png.Encoder{CompressionLevel: png.BestSpeed}
	if err := enc.Encode(&buf, img); err != nil {
		panic(err) // encoding an in-memory RGBA cannot fail
	}
	return buf.Bytes()
}
