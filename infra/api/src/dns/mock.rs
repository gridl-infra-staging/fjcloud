use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;

use super::{DnsError, DnsManager};

pub struct MockDnsManager {
    records: Mutex<HashMap<String, String>>,
    pub should_fail: Arc<AtomicBool>,
}

impl MockDnsManager {
    pub fn new() -> Self {
        Self {
            records: Mutex::new(HashMap::new()),
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
        Ok(())
    }

    async fn delete_record(&self, hostname: &str) -> Result<(), DnsError> {
        self.check_failure()?;
        let mut records = self.records.lock().unwrap();
        records.remove(hostname);
        Ok(())
    }
}
