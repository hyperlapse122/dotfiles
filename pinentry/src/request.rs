use std::{fmt, str::FromStr};

/// Public, canonical decimal YubiKey serial, shared with explicit deletion.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct CardId(u32);

impl fmt::Display for CardId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

impl FromStr for CardId {
    type Err = InvalidCardId;
    fn from_str(value: &str) -> Result<Self, Self::Err> {
        let parts: Vec<_> = value.split(' ').collect();
        let valid = match parts.as_slice() {
            [one] => !one.is_empty() && one.bytes().all(|b| b.is_ascii_digit()),
            [first, middle, last] => {
                !first.is_empty()
                    && first.len() <= 4
                    && middle.len() == 3
                    && last.len() == 3
                    && parts.iter().all(|p| p.bytes().all(|b| b.is_ascii_digit()))
                    && (*first == "0" || !first.starts_with('0'))
            }
            _ => false,
        };
        if !valid || value.len() > 12 {
            return Err(InvalidCardId);
        }
        let digits = parts.concat();
        let number: u32 = digits.parse().map_err(|_| InvalidCardId)?;
        if number == 0 {
            return Err(InvalidCardId);
        }
        Ok(Self(number))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InvalidCardId;
impl fmt::Display for InvalidCardId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("invalid card serial")
    }
}
impl std::error::Error for InvalidCardId {}

#[derive(Default)]
pub(crate) struct Request {
    description: Option<String>,
    prompt: Option<String>,
    uncertain: bool,
}

impl Request {
    pub fn update(&mut self, command: &[u8], argument: &[u8]) {
        if matches!(command, b"RESET" | b"SETKEYINFO" | b"CONFIRM" | b"MESSAGE") {
            *self = Self::default();
        } else if command == b"SETDESC" {
            *self = Self::default();
            self.description = crate::protocol::decode(argument)
                .ok()
                .and_then(|v| String::from_utf8(v.to_vec()).ok());
        } else if command == b"SETPROMPT" {
            self.prompt = crate::protocol::decode(argument)
                .ok()
                .and_then(|v| String::from_utf8(v.to_vec()).ok());
        } else if command.starts_with(b"SETREPEAT") || command == b"SETERROR" {
            self.uncertain = true;
        }
    }

    pub fn classify(&self) -> Option<(CardId, bool)> {
        if self.uncertain || self.prompt.as_deref() != Some("PIN") {
            return None;
        }
        classify_description(self.description.as_deref()?)
    }
}

fn classify_description(description: &str) -> Option<(CardId, bool)> {
    // The operation description may contain UIDs. Only the complete unlock
    // suffix supplies identity; reserved labels in the prefix are ambiguous.
    let marker = "Please unlock the card\n\n";
    let (prefix, block) = description.rsplit_once(marker)?;
    if (!prefix.is_empty() && !prefix.ends_with("\n\n"))
        || prefix.contains("Please unlock the card")
        || ["Number", "Holder", "Counter", "Remaining attempts"]
            .iter()
            .any(|s| prefix.contains(s))
        || prefix.chars().any(|c| c.is_control() && c != '\n')
    {
        return None;
    }
    let tabbing = block.starts_with('\u{1e}');
    let block = if tabbing {
        block.strip_prefix('\u{1e}')?
    } else {
        block
    };
    let (block, warning) =
        if let Some((body, attempts)) = block.split_once("\n\nRemaining attempts: ") {
            if !matches!(attempts, "0" | "1" | "2") {
                return None;
            }
            (body, true)
        } else {
            (block, false)
        };
    let label = |name: &str| {
        if tabbing {
            format!("{name}\u{1f}: ")
        } else {
            format!("{name}: ")
        }
    };
    let mut lines = block.split('\n');
    let serial = lines.next()?.strip_prefix(&label("Number"))?;
    let holder = lines.next()?.strip_prefix(&label("Holder"))?;
    if holder.chars().any(char::is_control)
        || ["Number:", "Holder:", "Counter:", "Remaining attempts:"]
            .iter()
            .any(|s| holder.contains(s))
    {
        return None;
    }
    if let Some(counter) = lines.next() {
        let count = counter.strip_prefix(&label("Counter"))?;
        if count.is_empty()
            || !count.bytes().all(|b| b.is_ascii_digit())
            || count.parse::<u64>().is_err()
        {
            return None;
        }
    }
    if lines.next().is_some() {
        return None;
    }
    Some((serial.parse().ok()?, warning))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn serial_grammar_and_bounds() {
        for value in [
            "12345678",
            "12 345 678",
            "00012345678",
            "4294967295",
            "0 123 456",
        ] {
            assert!(value.parse::<CardId>().is_ok(), "{value}");
        }
        for value in [
            "",
            "0",
            "-1",
            "1 23 456",
            "0006 12345678",
            "4 294 967 295",
            "4294967296",
            "1\t234\t567",
            " 12345678",
            "01 234 567",
        ] {
            assert!(value.parse::<CardId>().is_err(), "{value}");
        }
    }
    #[test]
    fn supported_layouts_and_warning() {
        for block in [
            "Number: 12 345 678\nHolder: Example",
            "\u{1e}Number\u{1f}: 12 345 678\nHolder\u{1f}: Example\nCounter\u{1f}: 123",
        ] {
            for suffix in ["", "\n\nRemaining attempts: 1"] {
                let text =
                    format!("Operation with UID\n\nPlease unlock the card\n\n{block}{suffix}");
                let (card, warning) = classify_description(&text).unwrap();
                assert_eq!(card.to_string(), "12345678");
                assert_eq!(warning, !suffix.is_empty());
            }
        }
    }
    #[test]
    fn uncertain_forms_never_qualify() {
        for text in [
            "Please enter the PIN\n\nNumber: 12345678\nHolder: Example",
            "Please enter the Admin PIN\n\nNumber: 12345678\nHolder: Example",
            "Bitte Karte entsperren\n\nNumber: 12345678\nHolder: Example",
            "Please unlock the card\n\nNumber: 12345678\nNumber: 87654321\nHolder: Example",
            "Please unlock the card\n\nNumber: 12345678\nHolder: Example\nCounter: nope",
            "Please unlock the card\n\nNumber: 12345678\nHolder: Example\n\nRemaining attempts: 3",
            "Please unlock the card\n\nNumber: 12345678\nHolder: Example\nunknown",
            "Number: 87654321\n\nPlease unlock the card\n\nNumber: 12345678\nHolder: Example",
            "Please unlock the card\n\nNumber: 12345678\nHolder: Example\r",
        ] {
            assert!(classify_description(text).is_none(), "{text:?}");
        }
    }
}
