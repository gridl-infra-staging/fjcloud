use axum::body::Body;
use axum::http::{header, Request, StatusCode};
use http_body_util::BodyExt;
use std::collections::HashSet;
use tower::ServiceExt;

const ROBOTS_TAG: &str = "noindex, nofollow, noarchive, nosnippet, noimageindex, noai, noimageai";
const ROBOTS_TXT_OWNER_FILE: &str = include_str!("../../../../web/static/robots.txt");
const PINNED_AI_CRAWLER_NAMES: &[&str] = &[
    "AddSearchBot",
    "AI2Bot",
    "AI2Bot-DeepResearchEval",
    "Ai2Bot-Dolma",
    "aiHitBot",
    "amazon-kendra",
    "Amazonbot",
    "AmazonBuyForMe",
    "Amzn-SearchBot",
    "Amzn-User",
    "Andibot",
    "Anomura",
    "anthropic-ai",
    "ApifyBot",
    "ApifyWebsiteContentCrawler",
    "Applebot",
    "Applebot-Extended",
    "Aranet-SearchBot",
    "atlassian-bot",
    "Awario",
    "AzureAI-SearchBot",
    "bedrockbot",
    "bigsur.ai",
    "Bravebot",
    "Brightbot 1.0",
    "BuddyBot",
    "Bytespider",
    "CCBot",
    "Channel3Bot",
    "ChatGLM-Spider",
    "ChatGPT Agent",
    "ChatGPT-User",
    "Claude-SearchBot",
    "Claude-User",
    "Claude-Web",
    "ClaudeBot",
    "Cloudflare-AutoRAG",
    "CloudVertexBot",
    "cohere-ai",
    "cohere-training-data-crawler",
    "Cotoyogi",
    "Crawl4AI",
    "Crawlspace",
    "Datenbank Crawler",
    "DeepSeekBot",
    "Devin",
    "Diffbot",
    "DuckAssistBot",
    "Echobot Bot",
    "EchoboxBot",
    "ExaBot",
    "FacebookBot",
    "facebookexternalhit",
    "Factset_spyderbot",
    "FirecrawlAgent",
    "FriendlyCrawler",
    "Gemini-Deep-Research",
    "Google-Agent",
    "Google-CloudVertexBot",
    "Google-Extended",
    "Google-Firebase",
    "Google-NotebookLM",
    "GoogleAgent-Mariner",
    "GoogleOther",
    "GoogleOther-Image",
    "GoogleOther-Video",
    "GPTBot",
    "iAskBot",
    "iaskspider",
    "iaskspider/2.0",
    "IbouBot",
    "ICC-Crawler",
    "ImagesiftBot",
    "imageSpider",
    "img2dataset",
    "ISSCyberRiskCrawler",
    "kagi-fetcher",
    "Kangaroo Bot",
    "KlaviyoAIBot",
    "KunatoCrawler",
    "laion-huggingface-processor",
    "LAIONDownloader",
    "LCC",
    "LinerBot",
    "Linguee Bot",
    "LinkupBot",
    "Manus-User",
    "meta-externalagent",
    "Meta-ExternalAgent",
    "meta-externalfetcher",
    "Meta-ExternalFetcher",
    "meta-webindexer",
    "MistralAI-User",
    "MistralAI-User/1.0",
    "MyCentralAIScraperBot",
    "NagetBot",
    "netEstate Imprint Crawler",
    "newsai",
    "NotebookLM",
    "NovaAct",
    "OAI-SearchBot",
    "omgili",
    "omgilibot",
    "OpenAI",
    "Operator",
    "PanguBot",
    "Panscient",
    "panscient.com",
    "Perplexity-User",
    "PerplexityBot",
    "PetalBot",
    "PhindBot",
    "Poggio-Citations",
    "Poseidon Research Crawler",
    "QualifiedBot",
    "QuillBot",
    "quillbot.com",
    "SBIntuitionsBot",
    "Scrapy",
    "SemrushBot-OCOB",
    "SemrushBot-SWA",
    "ShapBot",
    "Sidetrade indexer bot",
    "Spider",
    "TavilyBot",
    "TerraCotta",
    "Thinkbot",
    "TikTokSpider",
    "Timpibot",
    "TwinAgent",
    "VelenPublicWebCrawler",
    "WARDBot",
    "Webzio-Extended",
    "webzio-extended",
    "wpbot",
    "WRTNBot",
    "YaK",
    "YandexAdditional",
    "YandexAdditionalBot",
    "YouBot",
    "ZanistaBot",
];

async fn get(path: &str) -> axum::response::Response {
    let req = Request::builder()
        .uri(path)
        .body(Body::empty())
        .expect("test request should build");

    crate::common::test_app()
        .oneshot(req)
        .await
        .expect("test router should respond")
}

async fn response_text(response: axum::response::Response) -> String {
    let body = response
        .into_body()
        .collect()
        .await
        .expect("response body should collect")
        .to_bytes();

    String::from_utf8(body.to_vec()).expect("response should be UTF-8")
}

async fn response_body_len(response: axum::response::Response) -> usize {
    response
        .into_body()
        .collect()
        .await
        .expect("response body should collect")
        .to_bytes()
        .len()
}

fn normalize_newlines(value: &str) -> String {
    value.replace("\r\n", "\n")
}

fn owner_allowlisted_unfurl_agents() -> HashSet<String> {
    let mut allowlisted_agents = HashSet::new();
    let mut lines = ROBOTS_TXT_OWNER_FILE.lines().peekable();

    while let Some(line) = lines.next() {
        if line == "User-agent: *" {
            break;
        }
        if let Some(agent_name) = line.strip_prefix("User-agent: ") {
            if lines.peek().copied() == Some("Allow: /") {
                allowlisted_agents.insert(agent_name.to_string());
            }
        }
    }

    allowlisted_agents
}

fn owner_unfurl_allowlist_section() -> String {
    let mut section_lines: Vec<String> = Vec::new();
    let mut lines = ROBOTS_TXT_OWNER_FILE.lines().peekable();

    while let Some(line) = lines.next() {
        if line == "User-agent: *" {
            break;
        }

        if line.starts_with('#') || line.is_empty() {
            section_lines.push(line.to_string());
            continue;
        }

        if let Some(agent_name) = line.strip_prefix("User-agent: ") {
            if lines.peek().copied() == Some("Allow: /") {
                section_lines.push(format!("User-agent: {agent_name}"));
                section_lines.push("Allow: /".to_string());
                continue;
            }
        }
    }

    while section_lines.last().is_some_and(|line| line.is_empty()) {
        section_lines.pop();
    }

    let mut section = section_lines.join("\n");
    section.push('\n');
    section
}

fn owner_wildcard_backstop() -> &'static str {
    let wildcard_start = ROBOTS_TXT_OWNER_FILE
        .find("User-agent: *\n")
        .expect("web/static/robots.txt should contain a wildcard backstop");
    &ROBOTS_TXT_OWNER_FILE[wildcard_start..]
}

fn pinned_ai_disallow_section() -> String {
    let allowlisted_agents = owner_allowlisted_unfurl_agents();
    let mut section = String::new();

    for agent_name in PINNED_AI_CRAWLER_NAMES {
        if allowlisted_agents.contains(*agent_name) {
            continue;
        }
        section.push_str("User-agent: ");
        section.push_str(agent_name);
        section.push('\n');
        section.push_str("Disallow: /\n\n");
    }

    section
}

fn expected_robots_txt_contract_body() -> String {
    let mut expected = owner_unfurl_allowlist_section();
    expected.push('\n');
    expected.push_str(&pinned_ai_disallow_section());
    expected.push_str(owner_wildcard_backstop());
    expected
}

#[tokio::test]
async fn root_serves_public_landing_page_with_review_metadata() {
    let response = get("/").await;

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response
            .headers()
            .get("x-robots-tag")
            .and_then(|v| v.to_str().ok()),
        Some(ROBOTS_TAG),
        "public beta pages should discourage indexing while preserving direct access"
    );
    assert!(
        response
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .is_some_and(|value| value.starts_with("text/html")),
        "root page should be served as HTML"
    );

    let body = response_text(response).await;
    assert!(body.contains("<title>Flapjack Cloud - Managed search hosting</title>"));
    assert!(body.contains("Search hosting for real apps"));
    assert!(body.contains("Hosted Flapjack search without search-server operations."));
    assert!(
        body.contains("Bring your existing Algolia-shaped client code, create indexes from the dashboard or API, and keep storage, keys, regions, usage, and billing in one place."),
        "landing narrative should render the shared owner copy for the hero body text"
    );
    assert!(
        body.contains("Public beta is intentionally narrow: email support, review pricing before paid billing, and expect limits to change before GA."),
        "landing beta note should set expectations without adding signup CTAs"
    );
    assert!(
        body.contains("Managed Flapjack indexes behind an Algolia-compatible search API."),
        "quick facts should explain the hosted search product"
    );
    assert!(
        body.contains("Documents, settings, keys, regions, usage, and billing from the dashboard."),
        "quick facts should explain what customers manage"
    );
    assert!(
        body.contains("Public beta with support at support@flapjack.foo"),
        "quick facts should keep support contact visible"
    );
    assert!(
        body.contains("Support: support@flapjack.foo"),
        "footer should expose direct support contact copy"
    );
    assert!(body.contains("https://github.com/griddlehq/flapjack"));
    assert!(body.contains(r#"property="og:title" content="Flapjack Cloud""#));
    assert!(body.contains("https://cloud.flapjack.foo/flapjack_cloud_preview.png"));
    assert!(
        body.contains(r#"href="https://cloud.flapjack.foo/login""#) && body.contains(">Log in</a>"),
        "public root HTML should expose the APP_BASE_URL login target for unauthenticated users"
    );
    assert!(
        !body.contains("Sign Up"),
        "invite-only beta gate should keep signup CTA copy off the public root HTML"
    );
    assert!(
        !body.contains("Request Beta Access"),
        "beta access CTA copy should stay absent from public landing during invite-only gate"
    );
    assert!(
        !body.contains("subject=Flapjack%20Cloud%20beta%20access"),
        "public root HTML should not expose beta-access mailto CTAs"
    );
    assert!(body.contains("BETA"));
    assert!(body.contains("Privacy Policy"));
    assert!(body.contains("Terms of Service"));
    assert!(body.contains(r#"data-testid="brand-logo""#));

    for mirrored_brand_declaration in [
        r#"--font-brand: "Cabinet", "Inter", system-ui, sans-serif;"#,
        "--color-flapjack-ink: #1f1b18;",
        "--color-flapjack-cream: #fff8ea;",
        "--color-flapjack-rose: #b83f5f;",
        "--color-flapjack-plum: #8d2842;",
        "--color-flapjack-yellow: #f6c15b;",
        "--color-flapjack-mint: #9fd8d2;",
    ] {
        assert!(
            body.contains(mirrored_brand_declaration),
            "landing page must mirror web brand declaration `{mirrored_brand_declaration}`"
        );
    }

    // Prove the brand selectors actually consume `--font-brand`, not just that
    // the token is defined somewhere in the document. Otherwise a regression
    // that restored a hard-coded serif stack on `.brand` or `h1` would pass.
    let brand_rule = css_rule_body(&body, ".brand");
    assert!(
        brand_rule.contains("font-family: var(--font-brand)"),
        ".brand must consume var(--font-brand); rule body was: {brand_rule}"
    );
    let h1_rule = css_rule_body(&body, "h1");
    assert!(
        h1_rule.contains("font-family: var(--font-brand)"),
        "h1 must consume var(--font-brand); rule body was: {h1_rule}"
    );
}

fn css_rule_body<'a>(css: &'a str, selector: &str) -> &'a str {
    let needle = format!("{selector} {{");
    let start = css
        .find(&needle)
        .unwrap_or_else(|| panic!("CSS selector `{selector}` not found in landing page"));
    let body_start = start + needle.len();
    let end_offset = css[body_start..]
        .find('}')
        .unwrap_or_else(|| panic!("CSS selector `{selector}` has no closing brace"));
    &css[body_start..body_start + end_offset]
}

#[tokio::test]
async fn robots_txt_blocks_generic_crawlers_and_allows_unfurl_bots() {
    let response = get("/robots.txt").await;

    assert_eq!(response.status(), StatusCode::OK);
    assert!(
        response
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .is_some_and(|value| value.starts_with("text/plain")),
        "robots.txt should be served as plain text"
    );

    let body = response_text(response).await;
    assert_eq!(
        normalize_newlines(&body),
        expected_robots_txt_contract_body(),
        "robots.txt must preserve the unfurl allowlist from web/static, add pinned AI disallow blocks in upstream order, and keep the wildcard backstop last"
    );
}

#[tokio::test]
async fn favicon_and_preview_image_are_served_with_asset_content_types() {
    let favicon = get("/favicon.ico").await;
    assert_eq!(favicon.status(), StatusCode::OK);
    assert_eq!(
        favicon
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok()),
        Some("image/x-icon")
    );
    assert!(
        response_body_len(favicon).await > 1_000,
        "favicon should be the real Flapjack icon, not an empty placeholder"
    );

    let preview = get("/flapjack_cloud_preview.png").await;
    assert_eq!(preview.status(), StatusCode::OK);
    assert_eq!(
        preview
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok()),
        Some("image/png")
    );
    assert!(
        response_body_len(preview).await > 10_000,
        "link preview image should be a meaningful preview asset"
    );
}
