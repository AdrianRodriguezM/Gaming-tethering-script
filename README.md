# Gaming Tethering Script for Linux

A Bash script to optimize USB tethering for gaming — improving latency, stability and network responsiveness.

## Features
- TCP Keepalive + UDP Heartbeat
- fq_codel + BBR congestion control
- Watchdog that auto-restarts interface on loss
- CPU performance governor + USB autosuspend fix
- Chrome/Edge realtime priority
- Cloudflare DNS + lightweight tuning

## Usage
```bash
sudo bash gaming.sh on   # Enable gaming mode
sudo bash gaming.sh off  # Restore normal mode
