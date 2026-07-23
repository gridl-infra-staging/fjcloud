use chrono::Utc;
use uuid::Uuid;

use super::{
    AlgoliaImportDispatchIntentState, AlgoliaImportEngineAckState, AlgoliaImportErrorCode,
    AlgoliaImportJob, AlgoliaImportJobStatus, AlgoliaImportPublicationDisposition,
    AlgoliaImportSummary, EngineResumeMirror,
};

#[derive(Debug, Clone)]
pub struct AlgoliaImportJobState {
    pub status: AlgoliaImportJobStatus,
    pub publication_disposition: AlgoliaImportPublicationDisposition,
    pub engine_ack_state: AlgoliaImportEngineAckState,
    pub dispatch_intent_state: AlgoliaImportDispatchIntentState,
    pub engine_job_id: Option<Uuid>,
    pub lifecycle_generation: i64,
    pub retryable: bool,
    pub resume_intent_generation: i64,
    pub resume_mirror: Option<EngineResumeMirror>,
    pub resumable: bool,
    pub resume_count: i64,
    pub summary: AlgoliaImportSummary,
    pub warnings: serde_json::Value,
    pub error_code: Option<AlgoliaImportErrorCode>,
    pub error_message: Option<String>,
}

impl AlgoliaImportJobState {
    pub fn validate(&self) -> Result<(), &'static str> {
        use AlgoliaImportDispatchIntentState::Absent;
        use AlgoliaImportEngineAckState::{
            Acknowledged, NotApplicable, OutboxPending, Pending, SealAcknowledged,
        };
        use AlgoliaImportJobStatus::{Failed, Interrupted};
        use AlgoliaImportPublicationDisposition::{NotStarted, Unchanged};

        if self.dispatch_intent_state == Absent && self.engine_job_id.is_some() {
            return Err("absent dispatch intent cannot have an engine job");
        }
        if self.resume_count < 0 {
            return Err("resume count cannot be negative");
        }
        if self.status.is_terminal()
            && !self
                .status
                .has_valid_terminal_disposition(self.publication_disposition)
        {
            return Err("terminal status has an invalid publication disposition");
        }
        if self.resumable
            && (!matches!(self.status, Failed | Interrupted)
                || self.dispatch_intent_state == Absent
                || self.engine_job_id.is_none()
                || self.resume_mirror.is_none()
                || self.publication_disposition != Unchanged
                || self.engine_ack_state != Pending)
        {
            return Err("resumable state requires an engine-linked pending failure mirror");
        }
        if self.status == Interrupted {
            if self.error_code != Some(AlgoliaImportErrorCode::Interrupted) {
                return Err("interrupted status requires the interrupted error code");
            }
            match self.publication_disposition {
                NotStarted
                    if self.engine_job_id.is_none()
                        && self.dispatch_intent_state != Absent
                        && self.engine_ack_state == SealAcknowledged => {}
                Unchanged
                    if self.engine_job_id.is_some()
                        && self.dispatch_intent_state != Absent
                        && matches!(
                            self.engine_ack_state,
                            Pending | OutboxPending | Acknowledged
                        ) => {}
                _ => return Err("interrupted state has an invalid persistence origin"),
            }
        } else if self.error_code == Some(AlgoliaImportErrorCode::Interrupted) {
            return Err("interrupted error code requires interrupted status");
        }

        match self.engine_ack_state {
            Pending
                if !self
                    .status
                    .is_finally_terminal(self.resumable, self.publication_disposition)
                    || (self.dispatch_intent_state != Absent && self.engine_job_id.is_some()) =>
            {
                Ok(())
            }
            NotApplicable
                if self.status == Failed
                    && self.publication_disposition == NotStarted
                    && self.dispatch_intent_state == Absent
                    && self.engine_job_id.is_none()
                    && !self.retryable =>
            {
                Ok(())
            }
            SealAcknowledged if self.status == Interrupted => Ok(()),
            OutboxPending | Acknowledged
                if self
                    .status
                    .is_finally_terminal(self.resumable, self.publication_disposition)
                    && self.dispatch_intent_state != Absent
                    && self.engine_job_id.is_some() =>
            {
                Ok(())
            }
            _ => Err("engine acknowledgement is incompatible with persisted job state"),
        }
    }

    pub fn validate_transition_from(&self, previous: &Self) -> Result<(), &'static str> {
        previous.validate()?;
        self.validate()?;
        if self.lifecycle_generation < previous.lifecycle_generation {
            return Err("lifecycle generation cannot rewind");
        }
        if self.resume_intent_generation < previous.resume_intent_generation {
            return Err("resume intent generation cannot rewind");
        }
        if self.resume_count < previous.resume_count {
            return Err("resume count cannot rewind");
        }
        if !summary_is_monotonic(&self.summary, &previous.summary) {
            return Err("summary progress cannot rewind");
        }
        if is_in_place_update(previous, self)
            || is_normal_forward_transition(previous.status, self.status)
            || is_engine_failure_transition(previous, self)
            || is_cancel_request_transition(previous, self)
            || is_cancel_reconciliation_transition(previous, self)
            || is_resume_preparation_transition(previous, self)
            || is_resume_accepted_transition(previous, self)
        {
            return Ok(());
        }
        Err("undeclared Algolia import job transition")
    }
}

impl TryFrom<&AlgoliaImportJob> for AlgoliaImportJobState {
    type Error = &'static str;

    fn try_from(job: &AlgoliaImportJob) -> Result<Self, Self::Error> {
        let resume_mirror = match (
            job.resume_checkpoint.clone(),
            job.resume_status_observed_at,
            job.resume_deadline,
        ) {
            (None, None, None) => None,
            (Some(checkpoint), Some(observed_at), Some(deadline)) => {
                Some(EngineResumeMirror::new(checkpoint, observed_at, deadline)?)
            }
            _ => return Err("persisted resume mirror is incomplete"),
        };
        Ok(Self {
            status: job.status,
            publication_disposition: job.publication_disposition,
            engine_ack_state: job.engine_ack_state,
            dispatch_intent_state: job.dispatch_intent_state,
            engine_job_id: job.engine_job_id,
            lifecycle_generation: job.lifecycle_generation,
            retryable: job.retryable,
            resume_intent_generation: job.resume_intent_generation,
            resume_mirror,
            resumable: job.resumable,
            resume_count: job.resume_count,
            summary: job.summary.clone(),
            warnings: job.warnings.clone(),
            error_code: job.error_code,
            error_message: job.error_message.clone(),
        })
    }
}

fn is_in_place_update(previous: &AlgoliaImportJobState, next: &AlgoliaImportJobState) -> bool {
    previous.status == next.status
}

fn is_normal_forward_transition(
    previous: AlgoliaImportJobStatus,
    next: AlgoliaImportJobStatus,
) -> bool {
    use AlgoliaImportJobStatus::{
        Completed, CompletedWithWarnings, CopyingConfiguration, CopyingDocuments, Promoting,
        Queued, ValidatingSource, Verifying,
    };
    matches!(
        (previous, next),
        (Queued, ValidatingSource)
            | (ValidatingSource, CopyingConfiguration)
            | (CopyingConfiguration, CopyingDocuments)
            | (CopyingDocuments, Verifying)
            | (Verifying, Promoting)
            | (Promoting, Completed)
            | (Promoting, CompletedWithWarnings)
    )
}

fn is_engine_failure_transition(
    previous: &AlgoliaImportJobState,
    next: &AlgoliaImportJobState,
) -> bool {
    use AlgoliaImportJobStatus::{
        CopyingConfiguration, CopyingDocuments, Failed, Interrupted, Promoting, Resuming,
        ValidatingSource, Verifying,
    };
    matches!(
        previous.status,
        ValidatingSource
            | CopyingConfiguration
            | CopyingDocuments
            | Verifying
            | Promoting
            | Resuming
    ) && matches!(next.status, Failed | Interrupted)
        && next.engine_job_id == previous.engine_job_id
        && next.dispatch_intent_state != AlgoliaImportDispatchIntentState::Absent
}

fn is_cancel_request_transition(
    previous: &AlgoliaImportJobState,
    next: &AlgoliaImportJobState,
) -> bool {
    use AlgoliaImportJobStatus::{
        Cancelling, CopyingConfiguration, CopyingDocuments, Promoting, Queued, Resuming,
        ValidatingSource, Verifying,
    };
    matches!(
        previous.status,
        Queued
            | ValidatingSource
            | CopyingConfiguration
            | CopyingDocuments
            | Verifying
            | Resuming
            | Promoting
    ) && next.status == Cancelling
        && next.engine_job_id == previous.engine_job_id
        && next.dispatch_intent_state == previous.dispatch_intent_state
        && next.publication_disposition == previous.publication_disposition
}

fn is_cancel_reconciliation_transition(
    previous: &AlgoliaImportJobState,
    next: &AlgoliaImportJobState,
) -> bool {
    use AlgoliaImportEngineAckState::{Acknowledged, OutboxPending, SealAcknowledged};
    use AlgoliaImportJobStatus::{Cancelled, Cancelling, Interrupted};
    let pre_admission = next.status == Interrupted
        && next.publication_disposition == AlgoliaImportPublicationDisposition::NotStarted
        && next.engine_ack_state == SealAcknowledged
        && next.engine_job_id.is_none()
        && next.error_code == Some(AlgoliaImportErrorCode::Interrupted);
    let engine_admitted = next.status == Cancelled
        && next.publication_disposition == AlgoliaImportPublicationDisposition::Unchanged
        && matches!(next.engine_ack_state, OutboxPending | Acknowledged)
        && next.engine_job_id == previous.engine_job_id
        && next.engine_job_id.is_some();
    previous.status == Cancelling && (pre_admission || engine_admitted)
}

fn is_resume_preparation_transition(
    previous: &AlgoliaImportJobState,
    next: &AlgoliaImportJobState,
) -> bool {
    use AlgoliaImportJobStatus::{Failed, Interrupted, Resuming};
    let mirror_is_current = previous
        .resume_mirror
        .as_ref()
        .map(|mirror| mirror.deadline() > Utc::now())
        .unwrap_or(false);
    matches!(previous.status, Failed | Interrupted)
        && previous.resumable
        && mirror_is_current
        && next.status == Resuming
        && !next.resumable
        && next.resume_mirror.is_none()
        && next.engine_job_id == previous.engine_job_id
        && next.dispatch_intent_state == previous.dispatch_intent_state
        && next.error_code.is_none()
}

fn is_resume_accepted_transition(
    previous: &AlgoliaImportJobState,
    next: &AlgoliaImportJobState,
) -> bool {
    previous.status == AlgoliaImportJobStatus::Resuming
        && next.status == AlgoliaImportJobStatus::CopyingDocuments
        && !next.resumable
        && next.resume_mirror.is_none()
        && next.engine_job_id == previous.engine_job_id
        && next.resume_count == previous.resume_count + 1
        && next.error_code.is_none()
}

fn summary_is_monotonic(next: &AlgoliaImportSummary, previous: &AlgoliaImportSummary) -> bool {
    next.documents_expected >= previous.documents_expected
        && next.documents_imported >= previous.documents_imported
        && next.documents_rejected >= previous.documents_rejected
        && next.settings_applied >= previous.settings_applied
        && next.settings_unsupported >= previous.settings_unsupported
        && next.synonyms_expected >= previous.synonyms_expected
        && next.synonyms_imported >= previous.synonyms_imported
        && next.synonyms_rejected >= previous.synonyms_rejected
        && next.rules_expected >= previous.rules_expected
        && next.rules_imported >= previous.rules_imported
        && next.rules_rejected >= previous.rules_rejected
}
