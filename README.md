# Gaming Tethering Script for Linux

A Bash script to optimize USB tethering for gaming — improving latency, stability and network responsiveness.

## Features
- TCP Keepalive + UDP Heartbeat
- fq_codel + BBR congestion control
- Watchdog that auto-restarts interface on loss
- CPU performance governor + USB autosuspend fix
- Chrome/Edge realtime priority
- Cloudflare DNS + lightweight tuning
## Performance Results

Tested on Linux (Debian/Ubuntu-based systems) using USB tethering over 4G.

-  Average ping reduced by up to **50 %** (from ~120 ms to ~60 ms on Cloudflare 1.1.1.1)
-  **Micro-cuts and jitter practically eliminated**
-  Stable connectivity for gaming


## Usage
```bash
sudo bash gaming.sh on   # Enable gaming mode
sudo bash gaming.sh off  # Restore normal mode
