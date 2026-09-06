//! HID++ 2.0 Battery Status protocol definitions, packet builders, and reply classifiers.
//!
//! Supports:
//! - Feature 0x1000: BATTERY_LEVEL_STATUS (Function 0: getBatteryLevelStatus)
//! - Feature 0x1004: UNIFIED_BATTERY (Function 1: getBatteryStatus)
//!
//! Verified against Solaar hidpp20.py and Linux kernel hid-logitech-hidpp.c.

use serde::{Deserialize, Serialize};

pub const FEATURE_BATTERY_LEVEL_STATUS: u16 = 0x1000;
pub const FEATURE_UNIFIED_BATTERY: u16 = 0x1004;

pub const BATTERY_FEATURE_1000_HI: u8 = 0x10;
pub const BATTERY_FEATURE_1000_LO: u8 = 0x00;
pub const BATTERY_FEATURE_1004_HI: u8 = 0x10;
pub const BATTERY_FEATURE_1004_LO: u8 = 0x04;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ChargingStatus {
    Discharging,
    Charging,
    Full,
    Unknown,
}

impl std::fmt::Display for ChargingStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Discharging => write!(f, "Discharging"),
            Self::Charging => write!(f, "Charging"),
            Self::Full => write!(f, "Full"),
            Self::Unknown => write!(f, "Unknown"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct BatteryInfo {
    pub percentage: u8,
    pub status: ChargingStatus,
}

impl BatteryInfo {
    pub fn is_discharging(&self) -> bool {
        self.status == ChargingStatus::Discharging
    }

    pub fn is_low(&self) -> bool {
        self.percentage <= 15 && self.is_discharging()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BatteryReply {
    Status(BatteryInfo),
    HidppError(u8),
    NotForUs,
}

/// Build Feature 0x1000 function 0 (getBatteryLevelStatus) request packet.
pub fn build_get_battery_level_status(dev_idx: u8, feat_idx: u8, sw_id: u8) -> [u8; 7] {
    [0x10, dev_idx, feat_idx, sw_id & 0x0F, 0x00, 0x00, 0x00]
}

/// Build Feature 0x1004 function 1 (getBatteryStatus) request packet.
pub fn build_get_unified_battery_status(dev_idx: u8, feat_idx: u8, sw_id: u8) -> [u8; 7] {
    [
        0x10,
        dev_idx,
        feat_idx,
        0x10 | (sw_id & 0x0F),
        0x00,
        0x00,
        0x00,
    ]
}

/// Classify a HID++ report as a response to Feature 0x1000 (func 0).
pub fn classify_battery_1000_reply(
    buf: &[u8],
    dev_idx: u8,
    feat_idx: u8,
    sw_id: u8,
) -> BatteryReply {
    if buf.len() < 7 {
        return BatteryReply::NotForUs;
    }
    if buf[0] != 0x10 && (buf[0] != 0x11 || buf.len() < 20) {
        return BatteryReply::NotForUs;
    }
    if buf[1] != dev_idx {
        return BatteryReply::NotForUs;
    }
    let sw = sw_id & 0x0F;
    if buf[2] == 0xFF || buf[2] == 0x8F {
        if buf[3] == feat_idx && buf[4] == sw {
            return BatteryReply::HidppError(buf[5]);
        }
        return BatteryReply::NotForUs;
    }
    if buf[2] != feat_idx || buf[3] != sw {
        return BatteryReply::NotForUs;
    }

    let percentage = buf[4].min(100);
    let status = match buf[6] {
        0x00 => ChargingStatus::Discharging,
        0x01 | 0x02 | 0x04 => ChargingStatus::Charging,
        0x03 => ChargingStatus::Full,
        _ => ChargingStatus::Unknown,
    };

    BatteryReply::Status(BatteryInfo { percentage, status })
}

/// Classify a HID++ report as a response to Feature 0x1004 (func 1).
pub fn classify_battery_1004_reply(
    buf: &[u8],
    dev_idx: u8,
    feat_idx: u8,
    sw_id: u8,
) -> BatteryReply {
    if buf.len() < 7 {
        return BatteryReply::NotForUs;
    }
    if buf[0] != 0x10 && (buf[0] != 0x11 || buf.len() < 20) {
        return BatteryReply::NotForUs;
    }
    if buf[1] != dev_idx {
        return BatteryReply::NotForUs;
    }
    let sw = 0x10 | (sw_id & 0x0F);
    if buf[2] == 0xFF || buf[2] == 0x8F {
        if buf[3] == feat_idx && buf[4] == sw {
            return BatteryReply::HidppError(buf[5]);
        }
        return BatteryReply::NotForUs;
    }
    if buf[2] != feat_idx || buf[3] != sw {
        return BatteryReply::NotForUs;
    }

    let percentage = buf[4].min(100);
    let status = match buf[5] & 0x0F {
        0x00 => ChargingStatus::Discharging,
        0x01..=0x03 => ChargingStatus::Charging,
        0x04 => ChargingStatus::Full,
        _ => ChargingStatus::Unknown,
    };

    BatteryReply::Status(BatteryInfo { percentage, status })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_get_battery_level_status_layout() {
        let pkt = build_get_battery_level_status(2, 5, 0x0E);
        assert_eq!(pkt, [0x10, 2, 5, 0x0E, 0x00, 0x00, 0x00]);
    }

    #[test]
    fn build_get_unified_battery_status_layout() {
        let pkt = build_get_unified_battery_status(2, 6, 0x0E);
        assert_eq!(pkt, [0x10, 2, 6, 0x1E, 0x00, 0x00, 0x00]);
    }

    #[test]
    fn classify_1000_reply_discharging() {
        let buf = [0x10, 1, 4, 0x0E, 85, 80, 0x00];
        let reply = classify_battery_1000_reply(&buf, 1, 4, 0x0E);
        assert_eq!(
            reply,
            BatteryReply::Status(BatteryInfo {
                percentage: 85,
                status: ChargingStatus::Discharging,
            })
        );
    }

    #[test]
    fn classify_1000_reply_charging() {
        let buf = [0x10, 1, 4, 0x0E, 45, 50, 0x01];
        let reply = classify_battery_1000_reply(&buf, 1, 4, 0x0E);
        assert_eq!(
            reply,
            BatteryReply::Status(BatteryInfo {
                percentage: 45,
                status: ChargingStatus::Charging,
            })
        );
    }

    #[test]
    fn classify_1000_reply_full() {
        let buf = [0x10, 1, 4, 0x0E, 100, 100, 0x03];
        let reply = classify_battery_1000_reply(&buf, 1, 4, 0x0E);
        assert_eq!(
            reply,
            BatteryReply::Status(BatteryInfo {
                percentage: 100,
                status: ChargingStatus::Full,
            })
        );
    }

    #[test]
    fn classify_1004_reply_discharging() {
        let buf = [0x10, 2, 7, 0x1E, 72, 0x00, 0x00];
        let reply = classify_battery_1004_reply(&buf, 2, 7, 0x0E);
        assert_eq!(
            reply,
            BatteryReply::Status(BatteryInfo {
                percentage: 72,
                status: ChargingStatus::Discharging,
            })
        );
    }

    #[test]
    fn classify_1004_reply_charging() {
        let buf = [0x10, 2, 7, 0x1E, 50, 0x01, 0x00];
        let reply = classify_battery_1004_reply(&buf, 2, 7, 0x0E);
        assert_eq!(
            reply,
            BatteryReply::Status(BatteryInfo {
                percentage: 50,
                status: ChargingStatus::Charging,
            })
        );
    }

    #[test]
    fn classify_battery_error_reply() {
        let buf = [0x10, 1, 0xFF, 4, 0x0E, 0x06, 0x00];
        let reply = classify_battery_1000_reply(&buf, 1, 4, 0x0E);
        assert_eq!(reply, BatteryReply::HidppError(0x06));
    }

    #[test]
    fn battery_info_low_threshold() {
        let low = BatteryInfo {
            percentage: 14,
            status: ChargingStatus::Discharging,
        };
        assert!(low.is_low());

        let charging_low = BatteryInfo {
            percentage: 14,
            status: ChargingStatus::Charging,
        };
        assert!(!charging_low.is_low());

        let normal = BatteryInfo {
            percentage: 50,
            status: ChargingStatus::Discharging,
        };
        assert!(!normal.is_low());
    }
}
