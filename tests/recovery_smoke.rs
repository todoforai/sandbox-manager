use std::process::Command;
use std::path::PathBuf;

#[path = "../src/recovery.rs"]
mod recovery;

#[test]
fn ca_signs_recovery_cert() {
    let dir = tempdir();
    let ca_path = dir.join("recovery_ca");
    let ca = recovery::RecoveryCa::load_or_init(&ca_path).expect("load ca");
    assert!(ca_path.exists());
    let user_key = dir.join("user");
    let st = Command::new("ssh-keygen")
        .args(["-t", "ed25519", "-N", "", "-q", "-f"])
        .arg(&user_key).status().unwrap();
    assert!(st.success());
    let pub_str = std::fs::read_to_string(user_key.with_extension("pub")).unwrap();
    let (cert, ttl) = ca.sign_recovery_cert(&pub_str, "sbx-abc", "user-1", 600).expect("sign");
    assert_eq!(ttl, 600);
    // TTL clamp: huge request gets clamped to MAX (3600).
    let (_c2, ttl2) = ca.sign_recovery_cert(&pub_str, "sbx-abc", "user-1", 999_999).expect("sign2");
    assert_eq!(ttl2, 3600);
    let cert_path = dir.join("user-cert.pub");
    std::fs::write(&cert_path, &cert).unwrap();
    let out = Command::new("ssh-keygen").arg("-L").arg("-f").arg(&cert_path).output().unwrap();
    assert!(out.status.success(), "ssh-keygen -L failed: {}", String::from_utf8_lossy(&out.stderr));
    let s = String::from_utf8_lossy(&out.stdout);
    assert!(s.contains("recovery:sbx-abc"), "principal missing: {s}");
    let ca2 = recovery::RecoveryCa::load_or_init(&ca_path).expect("reload");
    assert_eq!(ca.authorized_key_line(), ca2.authorized_key_line());
}

fn tempdir() -> PathBuf {
    let p = std::env::temp_dir().join(format!("sm-recovery-test-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&p);
    std::fs::create_dir_all(&p).unwrap();
    p
}
