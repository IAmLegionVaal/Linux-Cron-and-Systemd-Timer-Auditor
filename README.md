# Linux Cron and systemd Timer Auditor

A read-only Bash toolkit for auditing scheduled Linux tasks across cron, anacron, at, and systemd timers.

## Purpose

This project helps support and security engineers identify disabled schedules, missed executions, unsafe permissions, duplicate jobs, failed timer units, and persistence risks without changing any scheduled task.

## Checks performed

- User and system crontabs
- `/etc/crontab`, `/etc/cron.d`, and periodic cron directories
- Anacron configuration and spool state
- Pending `at` jobs when available
- Active, inactive, failed, and persistent systemd timers
- Next and previous timer execution times
- Timer and service unit relationships
- Recent cron and timer journal events
- World-writable or unexpectedly owned schedule files
- Duplicate schedule lines and commands
- Text, CSV, and JSON reports

## Usage

```bash
chmod +x src/cron_timer_auditor.sh
sudo ./src/cron_timer_auditor.sh
```

```bash
sudo ./src/cron_timer_auditor.sh --hours 72 --output /tmp/schedule-audit
```

## Safety

The script does not enable, disable, start, stop, edit, delete, or create cron jobs, timers, services, or `at` jobs.

## Privacy

Scheduled commands can contain usernames, paths, internal hostnames, and occasionally embedded secrets. Review reports before sharing them.

## Requirements

- Bash 4+
- `systemctl` and `journalctl` for full timer evidence
- Root privileges for complete system and user crontab visibility

## Author

Dewald Pretorius — L2 IT Support Engineer
