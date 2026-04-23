use std::fs;
use std::path::PathBuf;

pub const TEST_PRIVATE_KEY_PEM: &str = r#"-----BEGIN RSA PRIVATE KEY-----
MIICWwIBAAKBgQDN4A3XQTxPtLA+pvVxqPooxamu/q8Al4mWQBSjITGSoQ3doQzd
R07ahin2R+mgbZ0oi6nQ5QA7C9mrF/wmlrkHe1pnNYUn8AI9/LjeycdVPK/faKuG
vZ6HSiYtLZJ7v1HlODownLKaQKZx5H0DfY1Atb6skxGT3njIFRF8Eg0NhwIDAQAB
AoGAVgd8gSi3hS8iPuwRwK816fe/UmsGwh6Q1gJtHUXvqzA11RlJgOYdY1+RBWND
k1B6zcie67XmBMaM7NwW+CEfq+p1C3PeKf5fA1jAYYY23UPa5dKD86m1Uz/wv6Ix
3S/+53J1WoegexZJHfQZSdiSLT7SHiUkfkVDxCfsU627auECQQD0nVlQMty6ewFD
byadUdcEx92K0+CniMOR+iBnqK6WgEckNZB6e486Evd8MX69ImHyogNRO9kiqZRE
lUBi2yCvAkEA13UdN7xRfGAg41sVy8xzl67IZspV9bHiG1WAkLqQLOmNnP5tkkR6
hQNZ1AIGvnkP2QKz2IjqEsgHVxu/mb2mqQJAD1/AWEkKFHJcrvdSbvrQz80cAHi2
mvD+kbMtzDYO2wiu7/ip3vjbFKRSh6y4sXxyuYQzPyzKxeHwnqrexBfPowJAUcnF
U5kLHbmoAmZbOcfcwWG59TstslzaRiII8efAPyxRc50pnvKbx85j1RUH1lpCZ9Cc
0L/4izSfhLOl4giaMQJAbtAiDDaIIfyRbfSZNZ967YEKn/v4MEB/10N1FVM9PDl1
KgNlFjr6MrDnNWJl1H4WMuIaiRd+5WQnsK1rldRdTg==
-----END RSA PRIVATE KEY-----
"#;

#[allow(dead_code)]
pub fn write_test_key_file() -> PathBuf {
    let path =
        std::env::temp_dir().join(format!("fjcloud-oci-test-key-{}.pem", uuid::Uuid::new_v4()));
    fs::write(&path, TEST_PRIVATE_KEY_PEM).expect("test private key should be written");
    path
}
