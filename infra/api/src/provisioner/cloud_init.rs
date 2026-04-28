/// Cloud-init user-data generation for flapjack VM bootstrapping.
///
/// Supports multiple providers: AWS uses SSM for secrets, Hetzner receives
/// secrets directly in user-data (encrypted in transit via HTTPS API).
/// How the VM should retrieve its secrets at boot time.
pub enum SecretDelivery {
    /// Read secrets from AWS SSM Parameter Store (used by AWS VMs).
    AwsSsm { region: String },
    /// Secrets embedded directly in user-data (used by Hetzner VMs).
    /// The Hetzner API transmits user-data over HTTPS, so secrets are
    /// encrypted in transit. On-disk, cloud-init stores user-data at
    /// /var/lib/cloud/instance/user-data.txt — permissions are 0600 root.
    Direct { db_url: String, api_key: String },
}

/// Parameters for generating flapjack cloud-init user-data.
pub struct CloudInitParams {
    pub customer_id: String,
    pub node_id: String,
    pub region: String,
    pub environment: String,
    pub secrets: SecretDelivery,
}

fn shell_single_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

/// Generate cloud-init user-data script for a flapjack VM.
pub fn generate_cloud_init(params: &CloudInitParams) -> String {
    let customer_id = &params.customer_id;
    let node_id = &params.node_id;
    let region = &params.region;
    let environment = &params.environment;

    let secret_block = match &params.secrets {
        SecretDelivery::AwsSsm { region: ssm_region } => {
            let quoted_region = shell_single_quote(ssm_region);
            format!(
                r#"# Read secrets from AWS SSM Parameter Store
get_optional_ssm() {{
  aws ssm get-parameter --name "$1" --with-decryption --query "Parameter.Value" --output text --region {quoted_region} 2>/dev/null || true
}}
DB_URL=$(aws ssm get-parameter --name "/fjcloud/$ENVIRONMENT/database_url" --with-decryption --query "Parameter.Value" --output text --region {quoted_region})
API_KEY=$(aws ssm get-parameter --name "/fjcloud/$NODE_ID/api-key" --with-decryption --query "Parameter.Value" --output text --region {quoted_region})
DNS_DOMAIN=$(aws ssm get-parameter --name "/fjcloud/$ENVIRONMENT/dns_domain" --query "Parameter.Value" --output text --region {quoted_region})
INTERNAL_AUTH_TOKEN=$(aws ssm get-parameter --name "/fjcloud/$ENVIRONMENT/internal_auth_token" --with-decryption --query "Parameter.Value" --output text --region {quoted_region})
SLACK_WEBHOOK_URL=$(get_optional_ssm "/fjcloud/$ENVIRONMENT/slack_webhook_url")
DISCORD_WEBHOOK_URL=$(get_optional_ssm "/fjcloud/$ENVIRONMENT/discord_webhook_url")"#
            )
        }
        SecretDelivery::Direct { db_url, api_key } => format!(
            r#"# Secrets delivered via user-data (Hetzner)
DB_URL={}
API_KEY={}
INTERNAL_AUTH_TOKEN=$API_KEY
DNS_DOMAIN=example.invalid
SLACK_WEBHOOK_URL=
DISCORD_WEBHOOK_URL="#,
            shell_single_quote(db_url),
            shell_single_quote(api_key)
        ),
    };

    let quoted_customer_id = shell_single_quote(customer_id);
    let quoted_node_id = shell_single_quote(node_id);
    let quoted_region = shell_single_quote(region);
    let quoted_environment = shell_single_quote(environment);

    format!(
        r#"#!/bin/bash
set -euo pipefail

LOG_TAG="fjcloud-bootstrap"
logger -t "$LOG_TAG" "starting bootstrap (user-data)"

# Instance metadata
CUSTOMER_ID={quoted_customer_id}
NODE_ID={quoted_node_id}
REGION={quoted_region}
ENVIRONMENT={quoted_environment}

logger -t "$LOG_TAG" "customer_id=$CUSTOMER_ID node_id=$NODE_ID region=$REGION environment=$ENVIRONMENT"

{secret_block}

# Write environment files
mkdir -p /etc/flapjack /etc/fjcloud
cat > /etc/flapjack/env <<ENVEOF
DATABASE_URL=$DB_URL
FLAPJACK_API_KEY=$API_KEY
ENVEOF

cat > /etc/fjcloud/metering-env <<ENVEOF
DATABASE_URL=$DB_URL
FLAPJACK_URL=http://$NODE_ID:7700
FLAPJACK_API_KEY=$API_KEY
INTERNAL_KEY=$INTERNAL_AUTH_TOKEN
CUSTOMER_ID=$CUSTOMER_ID
NODE_ID=$NODE_ID
REGION=$REGION
ENVIRONMENT=$ENVIRONMENT
TENANT_MAP_URL=https://api.$DNS_DOMAIN/internal/tenant-map
COLD_STORAGE_USAGE_URL=https://api.$DNS_DOMAIN/internal/cold-storage-usage
SLACK_WEBHOOK_URL=$SLACK_WEBHOOK_URL
DISCORD_WEBHOOK_URL=$DISCORD_WEBHOOK_URL
ENVEOF

chmod 600 /etc/flapjack/env /etc/fjcloud/metering-env
chown flapjack:flapjack /etc/flapjack/env
chown fjcloud:fjcloud /etc/fjcloud/metering-env
# Metering unit contract (owned in ops/systemd/fj-metering-agent.service):
# User=fjcloud
# Group=fjcloud

logger -t "$LOG_TAG" "env files written"

# Enable and start services
systemctl daemon-reload
systemctl enable flapjack fj-metering-agent
systemctl start flapjack fj-metering-agent

logger -t "$LOG_TAG" "services started, bootstrap complete"
"#
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Verifies AWS-mode user-data includes `aws ssm get-parameter` calls and single-quoted metadata fields, and starts flapjack services.
    #[test]
    fn cloud_init_aws_includes_ssm_commands() {
        let params = CloudInitParams {
            customer_id: "cust-123".to_string(),
            node_id: "node-abc".to_string(),
            region: "us-east-1".to_string(),
            environment: "staging".to_string(),
            secrets: SecretDelivery::AwsSsm {
                region: "us-east-1".to_string(),
            },
        };
        let script = generate_cloud_init(&params);

        assert!(script.contains("aws ssm get-parameter"));
        assert!(script.contains("CUSTOMER_ID='cust-123'"));
        assert!(script.contains("NODE_ID='node-abc'"));
        assert!(script.contains("REGION='us-east-1'"));
        assert!(script.contains("ENVIRONMENT='staging'"));
        assert!(script.contains(r#"/fjcloud/$ENVIRONMENT/database_url"#));
        assert!(script.contains(r#"/fjcloud/$ENVIRONMENT/internal_auth_token"#));
        assert!(!script.contains("runtime-env.conf"));
        assert!(!script.contains("/etc/flapjack/metering-env"));
        assert!(script.contains("cat > /etc/fjcloud/metering-env <<ENVEOF"));
        assert!(script.contains("ENVIRONMENT=$ENVIRONMENT"));
        assert!(script.contains("TENANT_MAP_URL=https://api.$DNS_DOMAIN/internal/tenant-map"));
        assert!(script.contains(
            "COLD_STORAGE_USAGE_URL=https://api.$DNS_DOMAIN/internal/cold-storage-usage"
        ));
        assert!(script.contains("SLACK_WEBHOOK_URL=$SLACK_WEBHOOK_URL"));
        assert!(script.contains("DISCORD_WEBHOOK_URL=$DISCORD_WEBHOOK_URL"));
        assert!(script.contains("User=fjcloud"));
        assert!(script.contains("Group=fjcloud"));
        assert!(script.contains("systemctl start flapjack"));
    }

    /// Verifies Hetzner-mode user-data embeds DB URL and API key directly (no SSM), uses the direct-secrets comment header, and starts flapjack services.
    #[test]
    fn cloud_init_hetzner_includes_direct_secrets() {
        let params = CloudInitParams {
            customer_id: "cust-456".to_string(),
            node_id: "node-xyz".to_string(),
            region: "eu-central-1".to_string(),
            environment: "prod".to_string(),
            secrets: SecretDelivery::Direct {
                db_url: "postgres://db.example.com/fjcloud".to_string(),
                api_key: "sk-secret-key".to_string(),
            },
        };
        let script = generate_cloud_init(&params);

        assert!(
            !script.contains("aws ssm"),
            "should not use SSM for Hetzner"
        );
        assert!(script.contains("Secrets delivered via user-data (Hetzner)"));
        assert!(script.contains("postgres://db.example.com/fjcloud"));
        assert!(script.contains("sk-secret-key"));
        assert!(!script.contains("runtime-env.conf"));
        assert!(!script.contains("/etc/flapjack/metering-env"));
        assert!(script.contains("cat > /etc/fjcloud/metering-env <<ENVEOF"));
        assert!(script.contains("ENVIRONMENT=$ENVIRONMENT"));
        assert!(script.contains("TENANT_MAP_URL=https://api.$DNS_DOMAIN/internal/tenant-map"));
        assert!(script.contains(
            "COLD_STORAGE_USAGE_URL=https://api.$DNS_DOMAIN/internal/cold-storage-usage"
        ));
        assert!(script.contains("SLACK_WEBHOOK_URL=$SLACK_WEBHOOK_URL"));
        assert!(script.contains("DISCORD_WEBHOOK_URL=$DISCORD_WEBHOOK_URL"));
        assert!(script.contains("User=fjcloud"));
        assert!(script.contains("Group=fjcloud"));
        assert!(script.contains("systemctl start flapjack"));
    }

    /// Confirms that direct-delivery secrets containing shell metacharacters (`$`, backticks, single quotes) are single-quoted with proper escape sequences to prevent command injection.
    #[test]
    fn cloud_init_hetzner_escapes_direct_secrets_for_shell() {
        let params = CloudInitParams {
            customer_id: "cust".to_string(),
            node_id: "node".to_string(),
            region: "eu-central-1".to_string(),
            environment: "prod".to_string(),
            secrets: SecretDelivery::Direct {
                db_url: "postgres://user:pass@db.example.com/fjcloud".to_string(),
                api_key: "sk-'unsafe'-$HOME-$(whoami)".to_string(),
            },
        };

        let script = generate_cloud_init(&params);
        let db_line = script
            .lines()
            .find(|line| line.starts_with("DB_URL="))
            .expect("DB_URL assignment should exist");
        let api_line = script
            .lines()
            .find(|line| line.starts_with("API_KEY="))
            .expect("API_KEY assignment should exist");

        assert!(
            db_line.starts_with("DB_URL='") && db_line.ends_with('\''),
            "DB_URL should be single-quoted for shell safety: {db_line}"
        );
        assert!(
            api_line.starts_with("API_KEY='") && api_line.ends_with('\''),
            "API_KEY should be single-quoted for shell safety: {api_line}"
        );
        assert!(
            api_line.contains("'\"'\"'"),
            "embedded single quotes should be escaped safely: {api_line}"
        );
    }

    /// Defense-in-depth: even though customer_id/node_id are UUIDs and region comes from an allowlist, all bash-interpolated values must be single-quoted to block injection if upstream constraints change.
    #[test]
    fn cloud_init_single_quotes_metadata_fields_for_shell_safety() {
        // Defense in depth: even though customer_id/node_id are UUIDs and region
        // comes from an allowlist, all values interpolated into bash must be
        // single-quoted to prevent command injection if upstream constraints change.
        let params = CloudInitParams {
            customer_id: "cust-$(whoami)".to_string(),
            node_id: "node-`id`".to_string(),
            region: "us-east-1\"; rm -rf /; \"".to_string(),
            environment: "staging$(rm -rf /)".to_string(),
            secrets: SecretDelivery::AwsSsm {
                region: "us-east-1\"; rm -rf /; \"".to_string(),
            },
        };
        let script = generate_cloud_init(&params);

        // Metadata assignments must use single quotes, not double quotes
        let cid_line = script
            .lines()
            .find(|l| l.starts_with("CUSTOMER_ID="))
            .expect("CUSTOMER_ID assignment should exist");
        assert!(
            cid_line.starts_with("CUSTOMER_ID='") && cid_line.ends_with('\''),
            "CUSTOMER_ID must be single-quoted for shell safety: {cid_line}"
        );

        let nid_line = script
            .lines()
            .find(|l| l.starts_with("NODE_ID="))
            .expect("NODE_ID assignment should exist");
        assert!(
            nid_line.starts_with("NODE_ID='") && nid_line.ends_with('\''),
            "NODE_ID must be single-quoted for shell safety: {nid_line}"
        );

        let region_line = script
            .lines()
            .find(|l| l.starts_with("REGION="))
            .expect("REGION assignment should exist");
        assert!(
            region_line.starts_with("REGION='") && region_line.ends_with('\''),
            "REGION must be single-quoted for shell safety: {region_line}"
        );

        // SSM --region flag must also be single-quoted
        let ssm_lines: Vec<&str> = script.lines().filter(|l| l.contains("--region")).collect();
        for ssm_line in &ssm_lines {
            assert!(
                !ssm_line.contains("--region \""),
                "SSM --region must not use double quotes: {ssm_line}"
            );
        }
        assert!(
            script.contains("ENVIRONMENT='staging$(rm -rf /)'"),
            "ENVIRONMENT must be single-quoted for shell safety"
        );
    }

    #[test]
    fn cloud_init_sets_secure_permissions() {
        let params = CloudInitParams {
            customer_id: "c".to_string(),
            node_id: "n".to_string(),
            region: "r".to_string(),
            environment: "staging".to_string(),
            secrets: SecretDelivery::AwsSsm {
                region: "r".to_string(),
            },
        };
        let script = generate_cloud_init(&params);

        assert!(script.contains("chmod 600"));
        assert!(script.contains("chown fjcloud:fjcloud"));
        assert!(script.contains("/etc/fjcloud/metering-env"));
        assert!(!script.contains("/etc/flapjack/metering-env"));
    }
}
