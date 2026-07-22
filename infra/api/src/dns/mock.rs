use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;

use chrono::{DateTime, Utc};

use super::{DnsARecord, DnsError, DnsManager};

pub struct MockDnsManager {
    records: Mutex<HashMap<String, String>>,
    created_at: Mutex<HashMap<String, DateTime<Utc>>>,
    delete_calls: AtomicUsize,
    pub should_fail: Arc<AtomicBool>,
}

impl MockDnsManager {
    pub fn new() -> Self {
        Self {
            records: Mutex::new(HashMap::new()),
            created_at: Mutex::new(HashMap::new()),
            delete_calls: AtomicUsize::new(0),
            should_fail: Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn set_should_fail(&self, fail: bool) {
        self.should_fail.store(fail, Ordering::SeqCst);
    }

    fn check_failure(&self) -> Result<(), DnsError> {
        if self.should_fail.load(Ordering::SeqCst) {
            Err(DnsError::Api("injected failure".into()))
        } else {
            Ok(())
        }
    }

    /// Returns a snapshot of current records for test assertions.
    pub fn get_records(&self) -> HashMap<String, String> {
        self.records.lock().unwrap().clone()
    }

    pub fn seed_a_record_at(&self, hostname: &str, ip: &str, created_at: DateTime<Utc>) {
        self.records
            .lock()
            .unwrap()
            .insert(hostname.to_string(), ip.to_string());
        self.created_at
            .lock()
            .unwrap()
            .insert(hostname.to_string(), created_at);
    }

    pub fn delete_call_count(&self) -> usize {
        self.delete_calls.load(Ordering::SeqCst)
    }
}

impl Default for MockDnsManager {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl DnsManager for MockDnsManager {
    async fn create_record(&self, hostname: &str, ip: &str) -> Result<(), DnsError> {
        self.check_failure()?;
        let mut records = self.records.lock().unwrap();
        records.insert(hostname.to_string(), ip.to_string());
        self.created_at
            .lock()
            .unwrap()
            .insert(hostname.to_string(), Utc::now());
        Ok(())
    }

    async fn delete_record(&self, hostname: &str) -> Result<(), DnsError> {
        self.delete_calls.fetch_add(1, Ordering::SeqCst);
        self.check_failure()?;
        let mut records = self.records.lock().unwrap();
        records.remove(hostname);
        self.created_at.lock().unwrap().remove(hostname);
        Ok(())
    }

    async fn list_a_records(&self) -> Result<Vec<DnsARecord>, DnsError> {
        self.check_failure()?;
        let records = self.records.lock().unwrap();
        let timestamps = self.created_at.lock().unwrap();
        let mut listed = records
            .keys()
            .map(|hostname| DnsARecord {
                hostname: hostname.clone(),
                created_at: timestamps.get(hostname).cloned().unwrap_or_else(Utc::now),
            })
            .collect::<Vec<_>>();
        listed.sort_by(|left, right| left.hostname.cmp(&right.hostname));
        Ok(listed)
    }
}
