use axum::http::{header, HeaderMap, HeaderValue};
use axum::response::{Html, IntoResponse};

const SUPPORT_EMAIL: &str = "support@flapjack.foo";
const CANONICAL_URL: &str = "https://cloud.flapjack.foo/";
const PREVIEW_IMAGE_URL: &str = "https://cloud.flapjack.foo/flapjack_cloud_preview.png";
const ROBOTS_TXT: &str = include_str!("../../../../web/static/robots.txt");
const FAVICON_ICO: &[u8] = include_bytes!("../../../../web/src/lib/assets/favicon.ico");
const PREVIEW_IMAGE: &[u8] = include_bytes!("../../../../web/static/flapjack_cloud_preview.png");

/// Serves the temporary public beta landing page used for Stripe review.
pub async fn landing_page() -> Html<String> {
    Html(landing_page_html())
}

/// Serves the crawler policy from `web/static` so Svelte and API-hosted pages
/// keep one source of truth for bot behavior during beta.
pub async fn robots_txt() -> impl IntoResponse {
    with_content_type("text/plain; charset=utf-8", ROBOTS_TXT)
}

/// Serves the same favicon used by the Flapjack web dashboard.
pub async fn favicon() -> impl IntoResponse {
    with_content_type("image/x-icon", FAVICON_ICO)
}

/// Serves a real dashboard preview for Slack, Discord, Twitter/X, and other
/// unfurl agents that read Open Graph/Twitter card metadata.
pub async fn preview_image() -> impl IntoResponse {
    with_content_type("image/png", PREVIEW_IMAGE)
}

fn with_content_type<T>(content_type: &'static str, body: T) -> impl IntoResponse
where
    T: IntoResponse,
{
    let mut headers = HeaderMap::new();
    headers.insert(header::CONTENT_TYPE, HeaderValue::from_static(content_type));
    (headers, body)
}

fn landing_page_html() -> String {
    format!(
        r##"<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Flapjack Cloud - Managed search hosting</title>
  <meta name="description" content="Managed hosting for Flapjack search. Algolia-compatible API, public beta, usage-based pricing in USD.">
  <link rel="canonical" href="{CANONICAL_URL}">
  <link rel="icon" href="/favicon.ico">
  <meta property="og:type" content="website">
  <meta property="og:site_name" content="Flapjack Cloud">
  <meta property="og:title" content="Flapjack Cloud">
  <meta property="og:description" content="Managed hosting for Flapjack search. Algolia-compatible API, public beta, usage-based pricing in USD.">
  <meta property="og:url" content="{CANONICAL_URL}">
  <meta property="og:image" content="{PREVIEW_IMAGE_URL}">
  <meta property="og:image:width" content="1280">
  <meta property="og:image:height" content="720">
  <meta property="og:image:alt" content="Flapjack Cloud dashboard overview">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="Flapjack Cloud">
  <meta name="twitter:description" content="Managed hosting for Flapjack search. Algolia-compatible API, public beta, usage-based pricing in USD.">
  <meta name="twitter:image" content="{PREVIEW_IMAGE_URL}">
  <style>
    :root {{
      color-scheme: light;
      --ink: #1f1b18;
      --muted: #4b4640;
      --teal: #9fd8d2;
      --teal-shadow: #78b8b2;
      --cream: #fff8ea;
      --cream-shadow: #e2d5b8;
      --gold: #f6c15b;
      --pink: #ffb3c7;
      --pink-shadow: #e889a7;
      --red: #b83f5f;
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      background: var(--teal);
      color: var(--ink);
      font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      line-height: 1.5;
    }}
    a {{ color: inherit; }}
    .wrap {{ width: min(1120px, calc(100% - 32px)); margin: 0 auto; }}
    .topbar {{ background: var(--cream); border-bottom: 4px solid var(--gold); }}
    .topbar-inner {{
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 16px;
      padding: 14px 0;
    }}
    .brand {{
      display: flex;
      align-items: center;
      gap: 12px;
      font-family: "Iowan Old Style", "Palatino Linotype", Georgia, serif;
      font-variant-caps: small-caps;
      font-size: clamp(28px, 5vw, 46px);
      font-weight: 900;
      letter-spacing: 0.04em;
      text-decoration: none;
    }}
    .badge {{
      display: inline-flex;
      align-items: center;
      border: 2px solid var(--ink);
      background: var(--gold);
      color: var(--ink);
      font-size: 12px;
      font-weight: 900;
      letter-spacing: 0.14em;
      padding: 4px 10px;
      text-transform: uppercase;
    }}
    .nav {{ display: flex; align-items: center; gap: 12px; }}
    .icon-link, .button, .card, .price-list, .notice {{
      border: 2px solid var(--ink);
      box-shadow: 6px 6px 0 var(--shadow);
    }}
    .icon-link {{
      --shadow: var(--cream-shadow);
      display: inline-flex;
      align-items: center;
      justify-content: center;
      width: 40px;
      height: 40px;
      background: var(--cream);
    }}
    .icon-link svg {{ width: 18px; height: 18px; fill: currentColor; }}
    .button {{
      --shadow: var(--pink-shadow);
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-height: 44px;
      background: var(--pink);
      color: var(--ink);
      font-weight: 900;
      padding: 10px 18px;
      text-decoration: none;
    }}
    .hero {{ padding: 64px 0 72px; }}
    .hero-grid {{
      display: grid;
      grid-template-columns: minmax(0, 1.1fr) minmax(280px, 0.9fr);
      gap: 40px;
      align-items: center;
    }}
    .eyebrow {{
      color: #8d2842;
      font-size: 13px;
      font-weight: 900;
      letter-spacing: 0.18em;
      margin: 0 0 16px;
      text-transform: uppercase;
    }}
    h1, h2, h3, p {{ margin-top: 0; }}
    h1 {{
      font-family: "Iowan Old Style", "Palatino Linotype", Georgia, serif;
      font-variant-caps: small-caps;
      font-size: clamp(54px, 10vw, 96px);
      font-weight: 900;
      letter-spacing: 0.04em;
      line-height: 0.95;
      margin-bottom: 22px;
    }}
    h2 {{ font-size: clamp(28px, 4vw, 38px); line-height: 1.1; margin-bottom: 14px; }}
    h3 {{ font-size: 18px; margin-bottom: 8px; }}
    .lede {{ max-width: 650px; font-size: 22px; font-weight: 900; }}
    .copy {{ max-width: 650px; color: #3f3a34; }}
    .actions {{ display: flex; flex-wrap: wrap; gap: 14px; margin-top: 28px; }}
    .outline {{
      --shadow: var(--teal-shadow);
      background: var(--cream);
      border: 2px solid var(--ink);
      box-shadow: 6px 6px 0 var(--shadow);
      color: var(--ink);
      display: inline-flex;
      font-weight: 900;
      min-height: 44px;
      padding: 10px 18px;
      text-decoration: none;
    }}
    .card {{ --shadow: var(--teal-shadow); background: var(--cream); padding: 24px; }}
    .facts {{ margin: 0; }}
    .facts div {{ padding: 14px 0; border-top: 1px solid #d7d0c2; }}
    .facts div:first-child {{ border-top: 0; padding-top: 0; }}
    dt {{ font-weight: 900; }}
    dd {{ margin: 4px 0 0; color: var(--muted); }}
    .band {{ background: var(--cream); padding: 56px 0; }}
    .plain {{ padding: 56px 0; }}
    .grid {{ display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 16px; }}
    .feature {{ --shadow: var(--cream-shadow); background: white; padding: 20px; }}
    .price-list {{ --shadow: var(--teal-shadow); background: white; max-width: 560px; }}
    .price-row {{
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      gap: 16px;
      padding: 14px 16px;
      border-top: 1px solid #d7d0c2;
    }}
    .price-row:first-child {{ border-top: 0; }}
    .price-name {{ font-weight: 900; }}
    .price-unit {{ color: var(--muted); font-size: 14px; }}
    .price-value {{ align-self: center; font-size: 18px; font-weight: 900; }}
    .policy-links {{ display: flex; flex-wrap: wrap; gap: 16px; margin-top: 22px; font-weight: 900; }}
    .policy-links a {{ color: var(--red); }}
    .notice {{ --shadow: var(--teal-shadow); background: var(--cream); padding: 22px; }}
    footer {{ background: var(--cream); border-top: 4px solid var(--gold); padding: 24px 0; color: var(--muted); }}
    .footer-inner {{ display: flex; justify-content: space-between; gap: 16px; flex-wrap: wrap; }}
    @media (max-width: 760px) {{
      .topbar-inner, .hero-grid {{ align-items: flex-start; flex-direction: column; grid-template-columns: 1fr; }}
      .nav {{ width: 100%; justify-content: space-between; }}
      .grid {{ grid-template-columns: 1fr; }}
      .hero {{ padding-top: 44px; }}
    }}
  </style>
</head>
<body>
  <header class="topbar">
    <div class="wrap topbar-inner">
      <a class="brand" href="{CANONICAL_URL}">Flapjack Cloud <span class="badge">BETA</span></a>
      <nav class="nav" aria-label="Primary">
        <a class="icon-link" href="https://github.com/gridlhq/flapjack" aria-label="GitHub repository" rel="noreferrer">
          <svg viewBox="0 0 16 16" aria-hidden="true" focusable="false"><path d="M8 0C3.58 0 0 3.67 0 8.19c0 3.62 2.29 6.69 5.47 7.78.4.08.55-.18.55-.4v-1.52c-2.23.5-2.69-.97-2.69-.97-.36-.95-.89-1.2-.89-1.2-.73-.51.05-.5.05-.5.81.06 1.24.85 1.24.85.71 1.26 1.87.9 2.33.69.07-.53.28-.9.51-1.1-1.78-.21-3.64-.91-3.64-4.03 0-.89.31-1.62.82-2.19-.08-.21-.36-1.04.08-2.16 0 0 .68-.22 2.2.84A7.45 7.45 0 0 1 8 4c.68 0 1.36.09 1.99.28 1.53-1.06 2.2-.84 2.2-.84.44 1.12.16 1.95.08 2.16.51.57.82 1.3.82 2.19 0 3.13-1.87 3.82-3.65 4.02.29.26.55.76.55 1.54v2.22c0 .22.15.48.55.4A8.14 8.14 0 0 0 16 8.19C16 3.67 12.42 0 8 0Z"></path></svg>
        </a>
        <a class="button" href="mailto:{SUPPORT_EMAIL}?subject=Flapjack%20Cloud%20beta%20access">Request Beta Access</a>
      </nav>
    </div>
  </header>

  <main>
    <section class="hero">
      <div class="wrap hero-grid">
        <div>
          <p class="eyebrow">Managed search hosting</p>
          <h1>Flapjack Cloud</h1>
          <p class="lede">Managed hosting for Flapjack search.</p>
          <p class="copy">Use an Algolia-compatible API without running your own search servers. Create indexes, upload documents, and query from your app.</p>
          <p class="copy"><strong>Public beta.</strong> Contact by email. Pricing and limits may change before general availability.</p>
          <div class="actions">
            <a class="button" href="mailto:{SUPPORT_EMAIL}?subject=Flapjack%20Cloud%20beta%20access">Request Beta Access</a>
            <a class="outline" href="https://api.flapjack.foo/docs">View API Docs</a>
          </div>
        </div>
        <section class="card" aria-label="Quick facts">
          <p class="eyebrow">Quick facts</p>
          <dl class="facts">
            <div><dt>What it is</dt><dd>Hosted Flapjack indexes with an Algolia-compatible API.</dd></div>
            <div><dt>What you manage</dt><dd>Indexes, API keys, regions, usage, billing, and account settings.</dd></div>
            <div><dt>Beta status</dt><dd>Public beta. Contact email: {SUPPORT_EMAIL}</dd></div>
          </dl>
        </section>
      </div>
    </section>

    <section class="band" id="product">
      <div class="wrap">
        <p class="eyebrow">Product</p>
        <h2>What you get</h2>
        <p class="copy">Flapjack Cloud runs Flapjack search for you. The public beta focuses on hosted search, Algolia migration, and a cloud dashboard for your indexes.</p>
        <div class="grid">
          <section class="card feature"><h3>Algolia-compatible API</h3><p>Use the `/1/` API shape your existing Algolia client code already expects.</p></section>
          <section class="card feature"><h3>InstantSearch works</h3><p>React, Vue, and plain JavaScript InstantSearch widgets can point at Flapjack.</p></section>
          <section class="card feature"><h3>Search features</h3><p>Typo tolerance, filters, faceting, geo search, synonyms, query rules, and custom ranking.</p></section>
          <section class="card feature"><h3>Algolia migration</h3><p>List Algolia indexes, choose what to move, and start migration from the dashboard.</p></section>
        </div>
      </div>
    </section>

    <section class="plain" id="pricing">
      <div class="wrap">
        <p class="eyebrow">Pricing</p>
        <h2>Simple pricing</h2>
        <p class="copy">Prices are in USD. Paid billing starts only after billing is enabled for the account.</p>
        <div class="price-list" aria-label="Pricing">
          <div class="price-row"><div><div class="price-name">Hot index storage</div><div class="price-unit">per MB-month</div></div><div class="price-value">$0.05</div></div>
          <div class="price-row"><div><div class="price-name">Cold snapshot storage</div><div class="price-unit">per GB-month</div></div><div class="price-value">$0.02</div></div>
          <div class="price-row"><div><div class="price-name">Minimum paid spend</div><div class="price-unit">per month</div></div><div class="price-value">$10.00</div></div>
        </div>
        <p class="copy" style="margin-top: 18px;">Search and write requests are quota-limited, not billed per request.</p>
      </div>
    </section>

    <section class="band" id="policies">
      <div class="wrap">
        <p class="eyebrow">Customer information</p>
        <h2>Policies</h2>
        <div class="grid">
          <section class="card feature"><h3>Delivery</h3><p>Flapjack Cloud is a digital service. Nothing is shipped. Account access is provided through the web dashboard and API.</p></section>
          <section class="card feature"><h3>Cancellation</h3><p>You can cancel by closing your account or contacting support. Usage already incurred may still be billed.</p></section>
          <section class="card feature"><h3>Refunds</h3><p>Refund requests are reviewed for duplicate charges, billing errors, or service unavailability.</p></section>
          <section class="card feature"><h3>Payment security</h3><p>Payment details are handled by Stripe over HTTPS. Flapjack Cloud does not store card numbers.</p></section>
        </div>
        <div class="policy-links">
          <a href="#terms">Terms of Service</a>
          <a href="#privacy">Privacy Policy</a>
          <a href="#contact">Contact</a>
        </div>
      </div>
    </section>

    <section class="plain" id="terms">
      <div class="wrap">
        <div class="notice">
          <p class="eyebrow">Terms of Service</p>
          <p>Flapjack Cloud is provided as a public beta digital service. Do not use it for unlawful content, abusive traffic, credential theft, or systems that require uninterrupted availability. We may suspend accounts that harm the service or violate these terms.</p>
        </div>
      </div>
    </section>

    <section class="plain" id="privacy">
      <div class="wrap">
        <div class="notice">
          <p class="eyebrow">Privacy Policy</p>
          <p>We collect account contact information, service usage, billing metadata, and operational logs needed to run Flapjack Cloud. Payment details are processed by Stripe. Contact {SUPPORT_EMAIL} for privacy or account deletion requests.</p>
        </div>
      </div>
    </section>

    <section class="band" id="contact">
      <div class="wrap">
        <h2>Contact</h2>
        <p class="copy">Email <a href="mailto:{SUPPORT_EMAIL}">{SUPPORT_EMAIL}</a> for beta access, account help, cancellation, refunds, privacy requests, or security reports.</p>
      </div>
    </section>
  </main>

  <footer>
    <div class="wrap footer-inner">
      <span>&copy; 2026 Flapjack Cloud. Contact: {SUPPORT_EMAIL}</span>
      <span><a href="#terms">Terms</a> · <a href="#privacy">Privacy</a> · <a href="https://github.com/gridlhq/flapjack">GitHub</a></span>
    </div>
  </footer>
</body>
</html>"##
    )
}
