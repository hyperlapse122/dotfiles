use dotfiles_pinentry::{CardId, PinStore, Secret, StoreError, serve};
use std::io::Cursor;

#[derive(Default)]
struct Store {
    value: Option<Secret>,
    calls: Vec<String>,
    fail: Option<&'static str>,
}
impl PinStore for Store {
    fn get(&mut self, card: &CardId) -> Result<Option<Secret>, StoreError> {
        self.calls.push(format!("get:{card}"));
        if self.fail == Some("get") {
            return Err(StoreError);
        }
        Ok(self.value.as_ref().map(|v| Secret::new(v.to_vec())))
    }
    fn set(&mut self, card: &CardId, value: &[u8]) -> Result<(), StoreError> {
        self.calls.push(format!("set:{card}"));
        if self.fail == Some("set") {
            return Err(StoreError);
        }
        self.value = Some(Secret::new(value.to_vec()));
        Ok(())
    }
    fn delete(&mut self, card: &CardId) -> Result<(), StoreError> {
        self.calls.push(format!("delete:{card}"));
        if self.fail == Some("delete") {
            return Err(StoreError);
        }
        self.value = None;
        Ok(())
    }
}

fn request(serial: &str, suffix: &str) -> String {
    format!(
        "OPTION allow-external-password-cache\nSETDESC Please unlock the card%0A%0ANumber: {serial}%0AHolder: Example{suffix}\nSETPROMPT PIN\nGETPIN\nBYE\n"
    )
}
fn run(input: &str, frontend: &str, store: &mut Store) -> (String, String, bool) {
    let mut output = Vec::new();
    let mut downstream = Vec::new();
    let result = serve(
        &mut Cursor::new(input),
        &mut output,
        &mut Cursor::new(frontend),
        &mut downstream,
        store,
    );
    (
        String::from_utf8(output).unwrap(),
        String::from_utf8(downstream).unwrap(),
        result.is_ok(),
    )
}
const SETUP: &str = "OK ready\nOK\nOK\nOK\n";

#[test]
fn cached_pin_uses_canonical_card_and_no_frontend_getpin() {
    let mut store = Store {
        value: Some(Secret::new(b"123456".to_vec())),
        ..Default::default()
    };
    let (out, child, ok) = run(
        &request("12 345 678", ""),
        &(SETUP.to_owned() + "OK bye\n"),
        &mut store,
    );
    assert!(ok);
    assert_eq!(store.calls, ["get:12345678"]);
    assert!(!child.contains("GETPIN"));
    assert!(out.contains("S PASSWORD_FROM_CACHE\nD 123456\nOK\n"));
}

#[test]
fn enrollment_waits_for_success_and_persists_decoded_stream() {
    let mut store = Store::default();
    let (out, _, ok) = run(
        &request("12345678", ""),
        &(SETUP.to_owned() + "S progress 1\nD 123%25\nD 456\nOK done\nOK bye\n"),
        &mut store,
    );
    assert!(ok);
    assert_eq!(store.calls, ["get:12345678", "set:12345678"]);
    assert_eq!(&**store.value.as_ref().unwrap(), b"123%456");
    assert!(out.contains("S progress 1\nD 123%25\nD 456\nOK done\n"));
}

#[test]
fn warning_deletes_before_manual_entry_and_never_reads() {
    let mut store = Store::default();
    let (_, _, ok) = run(
        &request("12345678", "%0A%0ARemaining attempts: 2"),
        &(SETUP.to_owned() + "D 987654\nOK\nOK\n"),
        &mut store,
    );
    assert!(ok);
    assert_eq!(store.calls, ["delete:12345678", "set:12345678"]);
}

#[test]
fn cancellation_discards_partial_secret_and_preserves_error() {
    let mut store = Store::default();
    let (out, _, ok) = run(
        &request("12345678", ""),
        &(SETUP.to_owned() + "D never-return\nERR 83886179 Operation cancelled\nOK\n"),
        &mut store,
    );
    assert!(ok);
    assert_eq!(store.calls, ["get:12345678"]);
    assert!(!out.contains("never-return"));
    assert!(out.contains("ERR 83886179 Operation cancelled\n"));
}

#[test]
fn failed_write_never_returns_pin_or_backend_diagnostics() {
    let mut store = Store {
        fail: Some("set"),
        ..Default::default()
    };
    let (out, _, _) = run(
        &request("12345678", ""),
        &(SETUP.to_owned() + "D sensitive-test-pin\nOK\nOK\n"),
        &mut store,
    );
    assert!(out.contains("ERR "));
    assert!(!out.contains("sensitive-test-pin"));
}

#[test]
fn unknown_prompt_and_inquiry_are_forwarded_without_store() {
    let mut store = Store::default();
    let input = "SETDESC Ordinary passphrase\nGETPIN\nD response%25\nEND\nBYE\n";
    let frontend =
        "OK ready\nOK\nS opaque status\nINQUIRE QUALITY secret\nD result\nOK native\nOK bye\n";
    let (out, child, ok) = run(input, frontend, &mut store);
    assert!(ok);
    assert!(store.calls.is_empty());
    assert!(child.contains("GETPIN\nD response%25\nEND\n"));
    assert!(out.contains("S opaque status\nINQUIRE QUALITY secret\nD result\nOK native\n"));
}

#[test]
fn card_identity_does_not_use_shared_key_information() {
    for (serial, expected) in [
        ("12 345 678", "get:12345678"),
        ("87 654 321", "get:87654321"),
    ] {
        let mut store = Store::default();
        let input = request(serial, "").replace("SETDESC", "SETKEYINFO n/SAMEKEYGRIP\nSETDESC");
        let frontend = SETUP.to_owned() + "OK\nD 123456\nOK\nOK\n";
        let (_, _, ok) = run(&input, &frontend, &mut store);
        assert!(ok);
        assert_eq!(store.calls[0], expected);
    }
}

#[test]
fn unsupported_requests_have_zero_store_access() {
    for input in [
        request("12345678", "").replace("SETPROMPT PIN", "SETPROMPT Admin PIN"),
        request("12345678", "").replace("Please unlock the card", "Please enter the PIN"),
        request("12345678", "").replace("Please unlock the card", "Repeat this PIN"),
        request("12345678", "").replace("Please unlock the card", "Bitte entsperren"),
        request("12345678", "").replace("Number: 12345678", "Number: 12345678%0ANumber: 87654321"),
        request("0006 12345678", ""),
        request("12345678", "").replace("GETPIN", "SETREPEAT Repeat PIN\nGETPIN"),
    ] {
        let mut store = Store::default();
        let extra = if input.contains("SETREPEAT") {
            "OK\n"
        } else {
            ""
        };
        let (out, child, ok) = run(
            &input,
            &(SETUP.to_owned() + extra + "D delegated\nOK\nOK\n"),
            &mut store,
        );
        assert!(ok);
        assert!(store.calls.is_empty(), "{input}");
        assert!(child.contains("GETPIN"));
        assert!(out.contains("D delegated\nOK\n"));
    }
}

#[test]
fn native_cache_response_is_not_enrolled() {
    let mut store = Store::default();
    let (out, _, ok) = run(
        &request("12345678", ""),
        &(SETUP.to_owned() + "S PASSWORD_FROM_CACHE\nD cached-by-frontend\nOK\nOK\n"),
        &mut store,
    );
    assert!(ok);
    assert_eq!(store.calls, ["get:12345678"]);
    assert!(out.contains("S PASSWORD_FROM_CACHE\nD cached-by-frontend\nOK\n"));
}

#[test]
fn absent_cache_permission_preserves_manual_frontend() {
    let mut store = Store::default();
    let input = request("12345678", "").replace("OPTION allow-external-password-cache\n", "");
    let (out, child, ok) = run(&input, "OK\nOK\nOK\nD 123456\nOK\nOK\n", &mut store);
    assert!(ok);
    assert!(store.calls.is_empty());
    assert!(child.contains("GETPIN"));
    assert!(out.contains("D 123456"));
}

#[test]
fn read_and_delete_failures_stop_before_frontend_or_pin_output() {
    for (operation, suffix) in [("get", ""), ("delete", "%0A%0ARemaining attempts: 1")] {
        let mut store = Store {
            fail: Some(operation),
            ..Default::default()
        };
        let (out, child, ok) = run(&request("12345678", suffix), SETUP, &mut store);
        assert!(!ok);
        assert!(!child.contains("GETPIN"));
        assert!(out.contains("ERR "));
        assert!(!out.contains("D "));
    }
}

#[test]
fn reset_and_changed_descriptor_discard_previous_card() {
    for change in [
        "RESET\n",
        "SETDESC Unknown request\n",
        "SETKEYINFO --clear\n",
        "CONFIRM\n",
        "MESSAGE\n",
    ] {
        let mut store = Store::default();
        let input = request("12345678", "").replace("GETPIN", &format!("{change}GETPIN"));
        let (_, child, ok) = run(
            &input,
            &(SETUP.to_owned() + "OK\nD manual\nOK\nOK\n"),
            &mut store,
        );
        assert!(ok);
        assert!(store.calls.is_empty());
        assert!(child.contains("GETPIN"));
    }
}

#[test]
fn repeated_getpin_cannot_reuse_a_consumed_identity() {
    let mut store = Store {
        value: Some(Secret::new(b"123456".to_vec())),
        ..Default::default()
    };
    let input = request("12345678", "").replace("GETPIN", "GETPIN\nGETPIN");
    let (_, child, ok) = run(
        &input,
        &(SETUP.to_owned() + "D manual\nOK\nOK\n"),
        &mut store,
    );
    assert!(ok);
    assert_eq!(store.calls, ["get:12345678"]);
    assert_eq!(child.matches("GETPIN").count(), 1);
}

#[test]
fn repeated_warning_never_automatically_retries() {
    let mut store = Store::default();
    let input =
        request("12345678", "%0A%0ARemaining attempts: 2").replace("GETPIN", "GETPIN\nGETPIN");
    let (_, child, ok) = run(
        &input,
        &(SETUP.to_owned() + "D first\nOK\nD second\nOK\nOK\n"),
        &mut store,
    );
    assert!(ok);
    assert_eq!(store.calls, ["delete:12345678", "set:12345678"]);
    assert_eq!(child.matches("GETPIN").count(), 2);
}

#[test]
fn percent_decoding_happens_once() {
    let mut store = Store::default();
    let input = request("12345678%250AHolder: Forged", "");
    let (_, _, _) = run(
        &input,
        &(SETUP.to_owned() + "D manual\nOK\nOK\n"),
        &mut store,
    );
    assert!(store.calls.is_empty());
    let mut store = Store::default();
    let (_, _, ok) = run(
        &request("12345678", ""),
        &(SETUP.to_owned() + "D %250A\nOK\nOK\n"),
        &mut store,
    );
    assert!(ok);
    assert_eq!(&**store.value.as_ref().unwrap(), b"%0A");
}

#[test]
fn malformed_or_oversized_frontend_stream_never_enrolls() {
    for stream in [
        "D broken%\nOK\n".to_owned(),
        format!("D {}\nOK\n", "s".repeat(1000)),
        "D unfinished\n".to_owned(),
        "OK\n".to_owned(),
        format!("{}OK\n", format!("D {}\n", "s".repeat(900)).repeat(5)),
    ] {
        let mut store = Store::default();
        let (out, _, ok) = run(
            &request("12345678", ""),
            &(SETUP.to_owned() + &stream),
            &mut store,
        );
        assert!(!ok);
        assert_eq!(store.calls, ["get:12345678"]);
        assert!(!out.contains("unfinished"));
        assert!(out.contains("ERR "));
    }
}

#[test]
fn oversized_upstream_line_aborts_without_forwarding_partial_command() {
    let mut store = Store::default();
    let (out, child, ok) = run(
        &format!("SETDESC {}\nGETPIN\n", "x".repeat(1000)),
        "OK\n",
        &mut store,
    );
    assert!(!ok);
    assert!(child.is_empty());
    assert!(store.calls.is_empty());
    assert!(out.contains("ERR "));
}

#[test]
fn eligible_inquiry_and_cancellation_reach_the_frontend() {
    for end in ["END", "CAN"] {
        let mut store = Store::default();
        let input =
            request("12345678", "").replace("GETPIN\n", &format!("GETPIN\nD answer%25\n{end}\n"));
        let (out, child, ok) = run(
            &input,
            &(SETUP.to_owned() + "S progress 1\nINQUIRE QUALITY text\nERR 99 Cancelled\nOK\n"),
            &mut store,
        );
        assert!(ok);
        assert!(out.contains("S progress 1\nINQUIRE QUALITY text\nERR 99 Cancelled\n"));
        assert!(child.contains(&format!("D answer%25\n{end}\n")));
        assert_eq!(store.calls, ["get:12345678"]);
    }
}

#[test]
fn feature_status_and_non_pin_dialogs_are_transparent() {
    let mut store = Store::default();
    let input = "GETINFO flavor\nOPTION arbitrary=value\nCONFIRM\nMESSAGE\nBYE\n";
    let frontend =
        "OK ready\nS FEATURES tabbing other\nD qt\nOK\nOK\nERR 99 Cancelled\nOK message\nOK bye\n";
    let (out, child, ok) = run(input, frontend, &mut store);
    assert!(ok);
    assert_eq!(out, frontend);
    assert_eq!(child, input);
    assert!(store.calls.is_empty());
}

#[test]
fn cached_secret_escaping_is_bounded_and_round_trips() {
    let secret = b"x%\r\n".repeat(600);
    let mut store = Store {
        value: Some(Secret::new(secret.clone())),
        ..Default::default()
    };
    let (out, _, ok) = run(
        &request("12345678", ""),
        &(SETUP.to_owned() + "OK\n"),
        &mut store,
    );
    assert!(ok);
    let mut decoded = Vec::new();
    for line in out.lines().filter_map(|line| line.strip_prefix("D ")) {
        assert!(line.len() + 3 <= 1000);
        let mut bytes = line.bytes();
        while let Some(byte) = bytes.next() {
            if byte == b'%' {
                let digits = [bytes.next().unwrap(), bytes.next().unwrap()];
                decoded
                    .push(u8::from_str_radix(std::str::from_utf8(&digits).unwrap(), 16).unwrap());
            } else {
                decoded.push(byte);
            }
        }
    }
    assert_eq!(decoded, secret);
}

#[test]
fn fallback_rejects_relative_path_and_its_own_executable() {
    use dotfiles_pinentry::{ProxyError, serve_with_fallback};
    let mut store = Store::default();
    let mut output = Vec::new();
    for path in [
        std::path::PathBuf::from("pinentry"),
        std::env::current_exe().unwrap(),
    ] {
        assert_eq!(
            serve_with_fallback(&mut Cursor::new(""), &mut output, &path, &[], &mut store),
            Err(ProxyError::Frontend)
        );
    }
    assert!(store.calls.is_empty());
}

#[test]
fn malformed_descriptor_is_delegated_without_a_second_decode() {
    let mut store = Store::default();
    let input = request("12345678", "").replace("Holder: Example", "Holder: malformed%Q1");
    let (out, child, ok) = run(
        &input,
        &(SETUP.to_owned() + "D manual\nOK\nOK\n"),
        &mut store,
    );
    assert!(ok);
    assert!(store.calls.is_empty());
    assert!(child.contains("Holder: malformed%Q1"));
    assert!(out.contains("D manual"));
}
