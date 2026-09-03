### Fixed
- Automatic update checks now keep their schedule on Macs that sleep. The check timers previously counted only awake time, so on a laptop "daily" could mean every several days; a check whose time passes during sleep now runs at the next wake. A failed check (offline, Wi-Fi still reconnecting) also retries within about 15 minutes instead of waiting for the next scheduled check.

