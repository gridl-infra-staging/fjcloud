mod common;

use axum::body::Body;
use axum::http::{header, Request, StatusCode};
use http_body_util::BodyExt;
use std::collections::HashSet;
use tower::ServiceExt;

const ROBOTS_TAG: &str = "noindex, nofollow, noarchive, nosnippet, noimageindex, noai, noimageai";
const ROBOTS_TXT_OWNER_FILE: &str = include_str!("../../../web/static/robots.txt");
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

    common::test_app()
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
    assert!(body.contains("Managed hosting for Flapjack search."));
    assert!(body.contains("https://github.com/gridlhq/flapjack"));
    assert!(body.contains(r#"property="og:title" content="Flapjack Cloud""#));
    assert!(body.contains("https://cloud.flapjack.foo/flapjack_cloud_preview.png"));
    assert!(body.contains("BETA"));
    assert!(body.contains("Privacy Policy"));
    assert!(body.contains("Terms of Service"));
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
