## Identity

This is the VLM rubric for the shipped diner aesthetic on fjcloud public marketing and legal surfaces, for reviewers validating customer-facing pages against a bold retro diner voice and feel; rule IDs are stable and cited by `vlm_judge.sh`.

## Palette

- `M.palette.1`: Public marketing route page background is diner teal `#9fd8d2`; flag any other large flat page color on landing or pricing.
- `M.palette.2`: Primary ink for high-contrast text and borders is `#1f1b18`; avoid near-black substitutions.
- `M.palette.3`: Cream surface for cards, headers, and footer surfaces is `#fff8ea`; do not replace with gray neutrals.
- `M.palette.4`: Gold accent and nav divider color is `#f6c15b` for bordered chrome accents.
- `M.palette.5`: Raised elements on teal contexts cast hard shadow `#78b8b2`.
- `M.palette.6`: Raised elements on cream contexts cast hard shadow `#e2d5b8`.
- `M.palette.7`: Primary CTA button fill is pink `#ffb3c7`.
- `M.palette.8`: Primary CTA hard shadow is `#e889a7`.
- `M.palette.9`: Primary CTA hover fill is `#ffc3d2`.
- `M.palette.10`: Action links and legal links use rose `#b83f5f` at rest.
- `M.palette.11`: Action links and legal links use darker rose `#8d2842` on hover.
- `M.palette.12`: Public beta banner background teal is `#d9f2ef`.
- `M.palette.13`: In-card row divider line uses `#d7d0c2`.
- `M.palette.14`: Muted ink ramp for supporting text uses only `#4b4640`, `#3f3a34`, and `#2d2925`.

## Typography

- `M.typography.1`: Wordmark text uses serif family `'Iowan Old Style', 'Palatino Linotype', Georgia, serif`.
- `M.typography.2`: Wordmark enforces `font-variant-caps: small-caps` with letter-spacing, preserving diner masthead identity.
- `M.typography.3`: Eyebrow labels are uppercase with wide tracking (`tracking-[0.18em]`) and heavy weight.
- `M.typography.4`: Primary public headings (`h1`, major `h2`) use black weight (`font-black`, 900).
- `M.typography.5`: Body copy defaults to regular/medium weight while emphasis lines use bold/black selectively, not globally.

## Voice

- `M.voice.1`: Public chrome includes explicit beta framing (badge or "Public beta" copy) so launch state is never ambiguous.
- `M.voice.2`: Pricing-facing copy includes the disclaimer that pricing and limits may change before general availability.
- `M.voice.3`: Dollar-denominated pricing language is explicit about USD on public pricing surfaces.
- `M.voice.4`: Marketing and legal copy stays plain-text professional with no emoji.
- `M.voice.5`: Support contact is presented as direct email contact for beta-era customer communication.

## Density

- `M.density.1`: Marketing hero and shared public chrome containers use `max-w-6xl`.
- `M.density.2`: Pricing and legal longform content use tighter containers (`max-w-5xl` or `max-w-4xl`) for readable line length.
- `M.density.3`: Major public sections use roomy vertical rhythm (`py-16`, with `sm:py-20` where defined).
- `M.density.4`: Desktop header rail height resolves to `h-16` in the public chrome.
- `M.density.5`: Branded diner components keep square corners (no rounding), while the legal longform article uses `rounded-3xl` as a documented exception.
- `M.density.6`: Border weight follows route intent: branded marketing cards/chrome use `2px` to `4px` ink borders; the legal longform article uses a lighter `1px` border.
- `M.density.7`: Shadow style follows route intent: branded diner affordances use hard-offset `4px` to `6px` no-blur shadows; the legal longform article uses `shadow-sm`.

## Component invariants

- `M.component.1`: `.diner-button` stays pink (`#ffb3c7`) with `2px` ink border `#1f1b18`, hard pink shadow `#e889a7`, hover `#ffc3d2`, and font-weight 900.
- `M.component.2`: `.beta-badge` is always bordered, uppercase, tightly tracked (`0.16em`), and heavy-weight for unmistakable beta signaling.
- `M.component.3`: `.raised` applies a `6px 6px 0` hard shadow; `.shadow-on-teal` maps to `#78b8b2`, `.shadow-on-cream` maps to `#e2d5b8`.
- `M.component.4`: `.wordmark` remains small-caps serif with the defined diner masthead family and spacing.
- `M.component.5`: `.github-link` is a cream square (`#fff8ea`) with `2px` ink border and hard cream shadow (`#e2d5b8`).

## What must be true

- `M.universal.1`: Public pages use diner palette surfaces, not neutral gray UI defaults; primary canvases are teal `#9fd8d2` (landing/pricing) or cream `#fff8ea` (legal), and cards may use cream/white variants from the declared palette.
- `M.universal.2`: Primary page titles keep diner emphasis with black weight (`font-black`, 900); secondary legal section headings may step down to `font-bold`.
- `M.universal.3`: When a page presents a primary signup CTA button, it uses the diner pink CTA treatment from `.diner-button`.
- `M.universal.4`: Public legal/marketing palette and signed-in app chrome remain visually separated; neither style system bleeds into the other.
- `M.universal.5`: Shared marketing chrome preserves explicit beta framing in badge/copy treatment; standalone legal pages may omit that chrome.
