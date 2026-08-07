use super::*;

impl NewSourceMigrationJob {
    pub fn create(
        customer_id: Uuid,
        destination: AlgoliaImportCreateDestination,
        source: AlgoliaImportSource,
        idempotency_key: impl Into<String>,
    ) -> Self {
        Self::create_for_provider(
            SourceImportProvider::Algolia,
            customer_id,
            destination,
            source,
            idempotency_key,
        )
    }

    pub fn create_for_provider(
        source_provider: SourceImportProvider,
        customer_id: Uuid,
        destination: AlgoliaImportCreateDestination,
        source: AlgoliaImportSource,
        idempotency_key: impl Into<String>,
    ) -> Self {
        Self::from_destination(
            source_provider,
            customer_id,
            AlgoliaImportDestination::Create(destination),
            source,
            idempotency_key,
            None,
        )
    }

    /// TODO: Document NewAlgoliaImportJob.replace.
    pub fn replace(
        customer_id: Uuid,
        destination: AuthenticatedAlgoliaReplacementTarget,
        source: AlgoliaImportSource,
        idempotency_key: impl Into<String>,
        target_binding: Option<AlgoliaImportTargetBinding>,
    ) -> Self {
        Self::replace_for_provider(
            SourceImportProvider::Algolia,
            customer_id,
            destination,
            source,
            idempotency_key,
            target_binding,
        )
    }

    pub fn replace_for_provider(
        source_provider: SourceImportProvider,
        customer_id: Uuid,
        destination: AuthenticatedAlgoliaReplacementTarget,
        source: AlgoliaImportSource,
        idempotency_key: impl Into<String>,
        target_binding: Option<AlgoliaImportTargetBinding>,
    ) -> Self {
        Self::from_destination(
            source_provider,
            customer_id,
            AlgoliaImportDestination::Replace(destination),
            source,
            idempotency_key,
            target_binding,
        )
    }

    /// TODO: Document NewAlgoliaImportJob.from_destination.
    pub(super) fn from_destination(
        source_provider: SourceImportProvider,
        customer_id: Uuid,
        destination: AlgoliaImportDestination,
        source: AlgoliaImportSource,
        idempotency_key: impl Into<String>,
        target_binding: Option<AlgoliaImportTargetBinding>,
    ) -> Self {
        let canonical_fingerprint =
            request_fingerprint(&source.canonical_fingerprint, &destination);
        Self {
            source_provider,
            customer_id,
            algolia_app_id: source.algolia_app_id,
            destination,
            source_name: source.source_name,
            idempotency_key: idempotency_key.into(),
            canonical_fingerprint,
            source_size_bytes: source.source_size_bytes,
            target_binding,
        }
    }

    pub fn customer_id(&self) -> Uuid {
        self.customer_id
    }

    pub fn source_provider(&self) -> SourceImportProvider {
        self.source_provider
    }

    pub fn tenant_id(&self) -> &str {
        self.destination.logical_target()
    }

    pub fn algolia_app_id(&self) -> &str {
        &self.algolia_app_id
    }

    pub fn destination(&self) -> &AlgoliaImportDestination {
        &self.destination
    }

    pub fn source_name(&self) -> &str {
        &self.source_name
    }

    pub fn idempotency_key(&self) -> &str {
        &self.idempotency_key
    }

    pub fn canonical_fingerprint(&self) -> &str {
        &self.canonical_fingerprint
    }

    pub fn source_size_bytes(&self) -> i64 {
        self.source_size_bytes
    }

    pub(crate) fn with_create_placement(
        mut self,
        vm_id: Uuid,
        physical_uid: String,
    ) -> Result<Self, &'static str> {
        let AlgoliaImportDestination::Create(destination) = self.destination else {
            return Err("Algolia create admission requires a create destination");
        };
        self.destination =
            AlgoliaImportDestination::Create(destination.with_placement(vm_id, physical_uid));
        Ok(self)
    }
}

fn request_fingerprint(source_fingerprint: &str, destination: &AlgoliaImportDestination) -> String {
    let mut hasher = Sha256::new();
    for part in [
        source_fingerprint,
        destination.kind().as_str(),
        destination.logical_target(),
        destination.region(),
    ] {
        hasher.update(part.as_bytes());
        hasher.update([0]);
    }
    format!("sha256:{}", hex::encode(hasher.finalize()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;

    #[test]
    fn engine_resume_mirror_validates_checkpoint_and_deadline() {
        let observed_at = Utc::now();
        let deadline = observed_at + Duration::seconds(1);
        assert!(EngineResumeMirror::new("opaque".into(), observed_at, deadline).is_ok());
        assert!(EngineResumeMirror::new(String::new(), observed_at, deadline).is_err());
        assert!(EngineResumeMirror::new("x".repeat(1025), observed_at, deadline).is_err());
        assert!(EngineResumeMirror::new("opaque".into(), observed_at, observed_at).is_err());
    }

    #[test]
    fn resumable_engine_failure_is_not_finally_terminal() {
        let observed_at = Utc::now();
        let state = AlgoliaImportJobState {
            status: AlgoliaImportJobStatus::Failed,
            publication_disposition: AlgoliaImportPublicationDisposition::Unchanged,
            engine_ack_state: AlgoliaImportEngineAckState::Pending,
            dispatch_intent_state: AlgoliaImportDispatchIntentState::Committed,
            engine_job_id: Some(Uuid::new_v4()),
            lifecycle_generation: 1,
            retryable: true,
            resume_intent_generation: 0,
            resume_mirror: Some(
                EngineResumeMirror::new(
                    "opaque".into(),
                    observed_at,
                    observed_at + Duration::minutes(5),
                )
                .unwrap(),
            ),
            resumable: true,
            resume_count: 0,
            summary: AlgoliaImportSummary::default(),
            terminal_outcome_observed: false,
            warnings: Vec::new(),
            error_code: Some(AlgoliaImportErrorCode::InvalidCredentials),
            error_message: None,
        };
        assert!(state.validate().is_ok());
        assert!(!state
            .status
            .is_finally_terminal(true, state.publication_disposition));
        let mut acknowledged = state;
        acknowledged.engine_ack_state = AlgoliaImportEngineAckState::Acknowledged;
        assert!(acknowledged.validate().is_err());
    }
}
