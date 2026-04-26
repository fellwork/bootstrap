# Animal sprite sources

These 6 PNGs are the source-of-truth for the bootstrap script's ASCII error animals.
After updating a PNG, run `../regen.ps1` to refresh the corresponding `.ansi` file.

## Style spec

- **Aesthetic:** Stardew Valley pixel art. Muted earth tones, soft pastel highlights,
  slight golden warmth across everything.
- **Resolution:** 32×40 pixels (square-ish, slightly taller than wide).
- **Background:** Solid black (#000000) or fully transparent. NOT white. NOT gradient.
  This matters because chafa renders the background as the terminal's bg color,
  and the sprite needs to read clearly against a dark terminal.
- **Composition:** Head-and-shoulders portrait, animal facing slightly off-camera.
  Generous padding around the silhouette (3-4 px on each side). The animal should
  feel like a charming portrait, not a full-body action shot.
- **Palette:** No more than 8 distinct colors per sprite. High-saturation primaries
  (bright red, electric blue, fluorescent green) are forbidden — Stardew never uses
  them. Stick to dusty jewel tones, soft browns, ochres, sage greens, muted purples.
- **Expression:** Calm and a bit knowing. The raccoon shouldn't look angry; the
  octopus shouldn't look scary. They're delivering helpful diagnostic notes, not
  bad news.

## Prompts (for image-generation tools)

Use these as base prompts. Tweak per tool — for DALL-E/ChatGPT image gen, prepend
"in the visual style of Stardew Valley pixel art"; for Midjourney, append
`--style raw --v 6` and `--ar 4:5`; for Stable Diffusion, use a Stardew/16-bit LoRA.

### raccoon (config-mismatch errors)
> Stardew Valley style pixel art, 32x40 pixels. Soft cute raccoon head-and-shoulders
> portrait, looking up and slightly to the side with curious knowing eyes. Classic
> bandit mask in dark gray-brown, fluffy ear tufts, small black nose. Muted earth
> tones — dusty grays, warm browns, soft cream highlights on chest fur. Black
> background. No text. Calm helpful expression.

### hedgehog (security/secrets warnings)
> Stardew Valley style pixel art, 32x40 pixels. Cute hedgehog head-and-shoulders
> portrait, slight tilt, gentle alert eyes. Spines in muted brown and tan with soft
> highlights, pale belly fur, small dark nose. Warm sage and ochre palette. Black
> background. No text. Quietly cautious expression — concerned but kind.

### octopus (dependency-tangle errors)
> Stardew Valley style pixel art, 32x40 pixels. Cute octopus head-and-tentacles
> portrait, two visible tentacles curling outward gently. Body is dusty muted purple
> with cream underside, large gentle eyes with bright pupil dots. Stardew-style soft
> shading. Black background. No text. Friendly thoughtful expression — like it's
> about to explain something complicated.

### owl (general "you should know" notes)
> Stardew Valley style pixel art, 32x40 pixels. Wise owl head-and-shoulders portrait,
> head turned slightly. Plumage in warm browns with cream and ochre accents on the
> chest. Big round eyes with bright golden iris and small black pupils. Small hooked
> beak. Black background. No text. Knowing and kind expression — ready to share a
> useful tip.

### fox (clever-fix-available notes)
> Stardew Valley style pixel art, 32x40 pixels. Cute fox head-and-shoulders portrait,
> half-smiling, looking off to one side. Russet-orange fur with cream chest and
> muzzle, dark ear tips and paws. Bright but not saturated palette — warm dusty
> oranges. Black background. No text. Mischievous-but-helpful expression, like it's
> about to share a shortcut.

### turtle (optional/no-rush warnings)
> Stardew Valley style pixel art, 32x40 pixels. Cute turtle head-and-shoulders
> portrait emerging from a green shell with hexagonal pattern. Soft sage green skin
> with darker green shell, gentle round eyes with dot pupils. Stardew-style soft
> shading. Black background. No text. Calm patient expression — completely
> unbothered, in no hurry at all.

## File naming

Save each PNG as exactly:

- `raccoon.png`
- `hedgehog.png`
- `octopus.png`
- `owl.png`
- `fox.png`
- `turtle.png`

After all 6 are in place, run from the bootstrap repo root:

```powershell
./animals/regen.ps1
```

This produces 6 `.ansi` files alongside the sources, ready to commit.
