//! D-Bus StatusNotifierItem (SNI) and Desktop Notification integration.
//!
//! Exposes org.kde.StatusNotifierItem on the session bus for KDE Plasma
//! and sends low-battery notifications via org.freedesktop.Notifications.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use zbus::blocking::connection::Connection;
use zbus::interface;
use zbus::zvariant::{OwnedObjectPath, Value};

use crate::battery::{BatteryInfo, ChargingStatus};

/// ToolTip tuple: (icon_name, icon_data_array, title, description)
pub type ToolTip = (String, Vec<(i32, i32, Vec<u8>)>, String, String);

#[derive(Debug, Clone)]
pub struct SniState {
    pub device_name: String,
    pub connected: bool,
    pub battery: Option<BatteryInfo>,
}

impl Default for SniState {
    fn default() -> Self {
        Self {
            device_name: "Logitech MX Master 4".to_string(),
            connected: false,
            battery: None,
        }
    }
}

pub struct StatusNotifierItem {
    state: Arc<Mutex<SniState>>,
}

impl StatusNotifierItem {
    pub fn new(state: Arc<Mutex<SniState>>) -> Self {
        Self { state }
    }
}

#[interface(name = "org.kde.StatusNotifierItem")]
impl StatusNotifierItem {
    #[zbus(property)]
    fn category(&self) -> &str {
        "Hardware"
    }

    #[zbus(property)]
    fn id(&self) -> &str {
        "logid"
    }

    #[zbus(property)]
    fn title(&self) -> String {
        let st = self.state.lock().unwrap();
        st.device_name.clone()
    }

    #[zbus(property)]
    fn status(&self) -> &str {
        let st = self.state.lock().unwrap();
        if st.connected {
            "Active"
        } else {
            "Passive"
        }
    }

    #[zbus(property)]
    fn window_id(&self) -> i32 {
        0
    }

    #[zbus(property)]
    fn icon_name(&self) -> String {
        let st = self.state.lock().unwrap();
        battery_icon_name(st.battery)
    }

    #[zbus(property)]
    fn icon_theme_path(&self) -> &str {
        ""
    }

    #[zbus(property)]
    fn menu(&self) -> OwnedObjectPath {
        OwnedObjectPath::try_from("/NO_DBUSMENU").unwrap()
    }

    #[zbus(property)]
    fn item_is_menu(&self) -> bool {
        false
    }

    #[zbus(property)]
    fn tool_tip(&self) -> ToolTip {
        let st = self.state.lock().unwrap();
        let icon = battery_icon_name(st.battery);
        let title = st.device_name.clone();
        let desc = match st.battery {
            Some(b) => format!("Battery: {}% ({})", b.percentage, b.status),
            None => {
                if st.connected {
                    "Connected".to_string()
                } else {
                    "Disconnected".to_string()
                }
            }
        };
        (icon, Vec::new(), title, desc)
    }

    fn context_menu(&self, _x: i32, _y: i32) {}

    fn activate(&self, _x: i32, _y: i32) {}

    fn secondary_activate(&self, _x: i32, _y: i32) {}

    fn scroll(&self, _delta: i32, _orientation: &str) {}
}

pub fn battery_icon_name(battery: Option<BatteryInfo>) -> String {
    let Some(b) = battery else {
        return "input-mouse-symbolic".to_string();
    };

    let charging_prefix = if b.status == ChargingStatus::Charging {
        "battery-charging-"
    } else {
        "battery-"
    };

    let level_str = if b.percentage >= 90 {
        "100"
    } else if b.percentage >= 70 {
        "080"
    } else if b.percentage >= 50 {
        "060"
    } else if b.percentage >= 30 {
        "040"
    } else if b.percentage >= 15 {
        "020"
    } else {
        "000"
    };

    format!("{charging_prefix}{level_str}-symbolic")
}

pub struct NotificationManager {
    last_notify: Option<Instant>,
    cooldown: Duration,
}

impl NotificationManager {
    pub fn new(cooldown_mins: u64) -> Self {
        Self {
            last_notify: None,
            cooldown: Duration::from_secs(cooldown_mins * 60),
        }
    }

    pub fn should_notify(&self, battery: BatteryInfo) -> bool {
        if !battery.is_low() {
            return false;
        }
        if let Some(last) = self.last_notify {
            if last.elapsed() < self.cooldown {
                return false;
            }
        }
        true
    }

    pub fn send_low_battery_notification(
        &mut self,
        conn: &Connection,
        battery: BatteryInfo,
    ) -> zbus::Result<u32> {
        self.last_notify = Some(Instant::now());

        let mut hints = HashMap::new();
        hints.insert("urgency".to_string(), Value::U8(2)); // Critical

        let body = format!(
            "Logitech MX Master 4 battery is low ({}%). Please connect charger.",
            battery.percentage
        );

        let msg = conn.call_method(
            Some("org.freedesktop.Notifications"),
            "/org/freedesktop/Notifications",
            Some("org.freedesktop.Notifications"),
            "Notify",
            &(
                "logid",
                0u32,
                "battery-caution-symbolic",
                "Mouse Battery Low",
                body,
                Vec::<String>::new(),
                hints,
                10000i32,
            ),
        )?;

        let (id,): (u32,) = msg.body().deserialize()?;
        Ok(id)
    }
}

pub struct SniService {
    conn: Connection,
    state: Arc<Mutex<SniState>>,
    notif_mgr: NotificationManager,
}

impl SniService {
    pub fn start(state: Arc<Mutex<SniState>>) -> zbus::Result<Self> {
        let conn = Connection::session()?;

        let item = StatusNotifierItem::new(Arc::clone(&state));
        conn.object_server().at("/StatusNotifierItem", item)?;

        // Request name on session bus
        let pid = std::process::id();
        let service_name = format!("org.kde.StatusNotifierItem-{pid}-1");
        conn.request_name(service_name.as_str())?;

        // Register with StatusNotifierWatcher if available
        let _ = conn.call_method(
            Some("org.kde.StatusNotifierWatcher"),
            "/StatusNotifierWatcher",
            Some("org.kde.StatusNotifierWatcher"),
            "RegisterStatusNotifierItem",
            &(&service_name),
        );

        Ok(Self {
            conn,
            state,
            notif_mgr: NotificationManager::new(30),
        })
    }

    pub fn update_battery(&mut self, battery: Option<BatteryInfo>) {
        {
            let mut st = self.state.lock().unwrap();
            st.battery = battery;
        }

        // Emit property change signals via object server
        let _ = self.conn.emit_signal(
            None::<()>,
            "/StatusNotifierItem",
            "org.kde.StatusNotifierItem",
            "NewIcon",
            &(),
        );
        let _ = self.conn.emit_signal(
            None::<()>,
            "/StatusNotifierItem",
            "org.kde.StatusNotifierItem",
            "NewToolTip",
            &(),
        );

        if let Some(b) = battery {
            if self.notif_mgr.should_notify(b) {
                let _ = self.notif_mgr.send_low_battery_notification(&self.conn, b);
            }
        }
    }

    pub fn update_connection(&mut self, connected: bool) {
        {
            let mut st = self.state.lock().unwrap();
            st.connected = connected;
            if !connected {
                st.battery = None;
            }
        }
        let _ = self.conn.emit_signal(
            None::<()>,
            "/StatusNotifierItem",
            "org.kde.StatusNotifierItem",
            "NewStatus",
            &(if connected { "Active" } else { "Passive" }),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn battery_icon_name_discharging_tiers() {
        assert_eq!(
            battery_icon_name(Some(BatteryInfo {
                percentage: 95,
                status: ChargingStatus::Discharging
            })),
            "battery-100-symbolic"
        );
        assert_eq!(
            battery_icon_name(Some(BatteryInfo {
                percentage: 75,
                status: ChargingStatus::Discharging
            })),
            "battery-080-symbolic"
        );
        assert_eq!(
            battery_icon_name(Some(BatteryInfo {
                percentage: 55,
                status: ChargingStatus::Discharging
            })),
            "battery-060-symbolic"
        );
        assert_eq!(
            battery_icon_name(Some(BatteryInfo {
                percentage: 35,
                status: ChargingStatus::Discharging
            })),
            "battery-040-symbolic"
        );
        assert_eq!(
            battery_icon_name(Some(BatteryInfo {
                percentage: 18,
                status: ChargingStatus::Discharging
            })),
            "battery-020-symbolic"
        );
        assert_eq!(
            battery_icon_name(Some(BatteryInfo {
                percentage: 5,
                status: ChargingStatus::Discharging
            })),
            "battery-000-symbolic"
        );
    }

    #[test]
    fn battery_icon_name_charging_tiers() {
        assert_eq!(
            battery_icon_name(Some(BatteryInfo {
                percentage: 85,
                status: ChargingStatus::Charging
            })),
            "battery-charging-080-symbolic"
        );
    }

    #[test]
    fn battery_icon_name_none() {
        assert_eq!(battery_icon_name(None), "input-mouse-symbolic");
    }

    #[test]
    fn notification_manager_cooldown() {
        let mut mgr = NotificationManager::new(30);
        let low = BatteryInfo {
            percentage: 10,
            status: ChargingStatus::Discharging,
        };

        assert!(mgr.should_notify(low));
        mgr.last_notify = Some(Instant::now());
        assert!(!mgr.should_notify(low));

        mgr.last_notify = Some(Instant::now() - Duration::from_secs(31 * 60));
        assert!(mgr.should_notify(low));
    }
}
