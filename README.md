# Linux Cron and systemd Timer Auditor

A Linux support toolkit for auditing and repairing selected cron services, systemd timers and schedule-file permission problems.

## Diagnostic script

```bash
chmod +x src/cron_timer_auditor.sh
sudo ./src/cron_timer_auditor.sh
```

The audit reports user and system cron jobs, anacron, pending `at` jobs, systemd timers, missed or failed schedules, unsafe permissions and recent execution events.

## Repair script

Preview a timer repair:

```bash
chmod +x src/cron_timer_repair.sh
sudo ./src/cron_timer_repair.sh \
  --timer backup.timer \
  --action restart \
  --dry-run
```

Start, restart, enable, disable or clear failure state for one timer:

```bash
sudo ./src/cron_timer_repair.sh --timer backup.timer --action start
sudo ./src/cron_timer_repair.sh --timer backup.timer --action enable
sudo ./src/cron_timer_repair.sh --timer backup.timer --action reset-failed
```

Restart the installed cron service:

```bash
sudo ./src/cron_timer_repair.sh --restart-cron
```

Correct ownership and mode on one standard cron file:

```bash
sudo ./src/cron_timer_repair.sh --fix-file /etc/cron.d/example-job
```

## What the repair does

- Restarts the installed cron or crond service.
- Performs one explicit lifecycle action on one selected systemd timer.
- Corrects root ownership and standard modes on one selected system cron file.
- Backs up the selected schedule file before changing it.
- Captures timer, cron-service and schedule-file state before and after repair.
- Supports dry-run, confirmation prompts, logs and clear exit codes.

## Safety and limitations

The tool does not create, edit or delete cron commands or timer definitions. Disabling a timer stops future executions until it is enabled again. Review the scheduled command itself when failures are caused by the application rather than the scheduler.

## Author

Dewald Pretorius — L2 IT Support Engineer
