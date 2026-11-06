use dotfiles_pinentry::{CardId, PinStore, Secret, StoreError};
use keyring::v1::{Entry, Error};

#[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
compile_error!("native PIN storage is supported only on Windows, macOS, and Linux");

const SERVICE: &str = "dotfiles.pinentry.openpgp";

pub struct NativeStore;

fn username(card: &CardId) -> String {
    format!("yubikey:{card}:user")
}

fn entry(card: &CardId) -> Result<Entry, StoreError> {
    Entry::new(SERVICE, &username(card)).map_err(|_| StoreError)
}

fn missing_or_error<T>(result: Result<T, Error>) -> Result<Option<T>, StoreError> {
    match result {
        Ok(value) => Ok(Some(value)),
        Err(Error::NoEntry) => Ok(None),
        Err(_) => Err(StoreError),
    }
}

impl PinStore for NativeStore {
    fn get(&mut self, card: &CardId) -> Result<Option<Secret>, StoreError> {
        missing_or_error(entry(card)?.get_secret().map(Secret::new))
    }

    fn set(&mut self, card: &CardId, value: &[u8]) -> Result<(), StoreError> {
        entry(card)?.set_secret(value).map_err(|_| StoreError)
    }

    fn delete(&mut self, card: &CardId) -> Result<(), StoreError> {
        missing_or_error(entry(card)?.delete_credential()).map(|_| ())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_no_entry_is_an_absent_record() {
        assert_eq!(missing_or_error::<()>(Err(Error::NoEntry)), Ok(None));
        assert_eq!(missing_or_error(Ok(())), Ok(Some(())));
        for error in [
            Error::NoStorageAccess(Box::new(std::io::Error::other("synthetic-secret"))),
            Error::PlatformFailure(Box::new(std::io::Error::other("synthetic-secret"))),
            Error::NoDefaultStore,
            Error::Ambiguous(vec![]),
            Error::BadEncoding(b"synthetic-secret".to_vec()),
            Error::BadDataFormat(
                b"synthetic-secret".to_vec(),
                Box::new(std::io::Error::other("synthetic-secret")),
            ),
            Error::BadStoreFormat("synthetic-secret".into()),
            Error::Invalid("synthetic-secret".into(), "synthetic-secret".into()),
            Error::TooLong("synthetic-secret".into(), 1),
            Error::NotSupportedByStore("synthetic-secret".into()),
        ] {
            let failure = missing_or_error::<()>(Err(error));
            assert_eq!(failure, Err(StoreError));
            assert_eq!(failure.unwrap_err().to_string(), "native PIN store failed");
        }
    }

    #[test]
    fn canonical_serial_and_purpose_define_one_record_per_card() {
        assert_eq!(
            username(&"12 345 678".parse().unwrap()),
            "yubikey:12345678:user"
        );
        assert_eq!(
            username(&"12345678".parse().unwrap()),
            "yubikey:12345678:user"
        );
        assert_ne!(
            username(&"12345678".parse().unwrap()),
            username(&"87654321".parse().unwrap())
        );
    }
}
