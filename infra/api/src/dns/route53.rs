//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/dns/route53.rs.
use async_trait::async_trait;
use aws_sdk_route53::types::{
    Change, ChangeAction, ChangeBatch, ResourceRecord, ResourceRecordSet, RrType,
};

use super::{hostname_for_domain, DnsError, DnsManager};

pub struct Route53DnsManager {
    client: aws_sdk_route53::Client,
    hosted_zone_id: String,
    domain: String,
}

impl Route53DnsManager {
    pub fn new(client: aws_sdk_route53::Client, hosted_zone_id: String, domain: String) -> Self {
        Self {
            client,
            hosted_zone_id,
            domain,
        }
    }

    /// Build the fully qualified domain name with trailing dot (required by Route53).
    fn fqdn(&self, hostname: &str) -> String {
        fqdn_for_domain(&self.domain, hostname)
    }

    /// Builds a Route53 change batch for a single A record (UPSERT or DELETE)
    /// with a fully qualified domain name and 300-second TTL.
    async fn change_record(
        &self,
        action: ChangeAction,
        hostname: &str,
        ip: &str,
    ) -> Result<(), DnsError> {
        let fqdn = self.fqdn(hostname);

        let resource_record = ResourceRecord::builder()
            .value(ip)
            .build()
            .map_err(|e| DnsError::Api(format!("failed to build resource record: {e}")))?;

        let record_set = ResourceRecordSet::builder()
            .name(&fqdn)
            .r#type(RrType::A)
            .ttl(300)
            .resource_records(resource_record)
            .build()
            .map_err(|e| DnsError::Api(format!("failed to build record set: {e}")))?;

        let change = Change::builder()
            .action(action)
            .resource_record_set(record_set)
            .build()
            .map_err(|e| DnsError::Api(format!("failed to build change: {e}")))?;

        let batch = ChangeBatch::builder()
            .changes(change)
            .build()
            .map_err(|e| DnsError::Api(format!("failed to build change batch: {e}")))?;

        self.client
            .change_resource_record_sets()
            .hosted_zone_id(&self.hosted_zone_id)
            .change_batch(batch)
            .send()
            .await
            .map_err(|e| DnsError::Api(format!("Route53 API error: {e}")))?;

        Ok(())
    }
}

#[async_trait]
impl DnsManager for Route53DnsManager {
    async fn create_record(&self, hostname: &str, ip: &str) -> Result<(), DnsError> {
        self.change_record(ChangeAction::Upsert, hostname, ip).await
    }

    /// Deletes a DNS record by first looking up its current value (Route53
    /// DELETE requires the exact record value). Treats not-found as idempotent
    /// success.
    async fn delete_record(&self, hostname: &str) -> Result<(), DnsError> {
        // Route53 DELETE requires the exact record value. Look up the current
        // record first, then delete with the value. Treat "not found" as
        // idempotent success.
        let fqdn = self.fqdn(hostname);

        let resp = self
            .client
            .list_resource_record_sets()
            .hosted_zone_id(&self.hosted_zone_id)
            .start_record_name(&fqdn)
            .start_record_type(RrType::A)
            .max_items(1)
            .send()
            .await
            .map_err(|e| DnsError::Api(format!("Route53 list error: {e}")))?;

        let record_set = resp
            .resource_record_sets()
            .iter()
            .find(|r| r.name() == fqdn && r.r#type() == &RrType::A);

        let Some(existing) = record_set else {
            // Record doesn't exist — idempotent success
            return Ok(());
        };

        let ip = existing
            .resource_records()
            .first()
            .map(|r| r.value())
            .ok_or_else(|| DnsError::Api("record has no value".into()))?;

        self.change_record(ChangeAction::Delete, hostname, ip).await
    }
}

fn fqdn_for_domain(domain: &str, hostname: &str) -> String {
    format!("{}.", hostname_for_domain(domain, hostname))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fqdn_adds_trailing_dot_to_subdomain() {
        assert_eq!(
            fqdn_for_domain("flapjack.foo", "vm-abcd1234.flapjack.foo"),
            "vm-abcd1234.flapjack.foo."
        );
    }

    #[test]
    fn fqdn_preserves_existing_trailing_dot() {
        assert_eq!(
            fqdn_for_domain("flapjack.foo", "vm-abcd1234.flapjack.foo."),
            "vm-abcd1234.flapjack.foo."
        );
    }

    #[test]
    fn fqdn_appends_domain_for_bare_hostname() {
        assert_eq!(
            fqdn_for_domain("flapjack.foo", "vm-abcd1234"),
            "vm-abcd1234.flapjack.foo."
        );
    }

    #[test]
    fn fqdn_does_not_false_match_domain_suffix() {
        // "notflapjack.foo" ends with "flapjack.foo" but is NOT a subdomain —
        // it must be treated as a bare hostname and get the domain appended.
        assert_eq!(
            fqdn_for_domain("flapjack.foo", "notflapjack.foo"),
            "notflapjack.foo.flapjack.foo."
        );
    }

    // --- canonical and generic domain coverage ---

    #[test]
    fn fqdn_flapjack_foo_bare_hostname() {
        assert_eq!(
            fqdn_for_domain("flapjack.foo", "vm-abcd1234"),
            "vm-abcd1234.flapjack.foo."
        );
    }

    #[test]
    fn fqdn_example_domain_already_qualified() {
        assert_eq!(
            fqdn_for_domain("example.net", "vm-abcd1234.example.net"),
            "vm-abcd1234.example.net."
        );
    }

    #[test]
    fn fqdn_example_domain_preserves_trailing_dot() {
        assert_eq!(
            fqdn_for_domain("example.net", "vm-abcd1234.example.net."),
            "vm-abcd1234.example.net."
        );
    }

    #[test]
    fn fqdn_example_domain_false_suffix_match() {
        // "notexample.net" ends with "example.net" but is NOT a subdomain.
        assert_eq!(
            fqdn_for_domain("example.net", "notexample.net"),
            "notexample.net.example.net."
        );
    }
}
