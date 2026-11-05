# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 1.0.0 — 2026-11-05

### Added
- First release: debloats a running Windows 10 (1809 or newer) or Windows 11 PC.
- Simple mode (one click, safe defaults) and Advanced mode (choose every app and setting, presets).
- App removal for all users or only the signed-in user; user settings can also go to new accounts.
- Preview of the exact changes, System Restore point before applying, log file and restart prompt.
- JSON backup of every change and Undo from any backup.
- Shared app and tweak lists with WinDebloat Tool, with verified automatic updates.
- Console mode with preview, unattended run, backup list and undo.
- Vietnamese default interface, plus English; partial Chinese and Khmer.
- Modern interface that follows the Windows light or dark theme and scales sharply on high-DPI screens.

### Fixed
- Elevation from folders whose name has brackets or an ampersand; only one instance at a time.
- Cancel keeps the summary, backup and restart prompt; cancel during the restore point stops before any change.
- Undo no longer marks signed-out user values as restored; REG_NONE and same-second backups handled correctly.
- No automatic rescan while a dialog is open (Apply after preview no longer fails).
- Downloaded rules cannot delete or rewrite protected services, Winlogon/LSA, execution locations, UAC or tasks.
- Clearer Vietnamese wording, localized opt-in warnings, readable undo dates, and long reinstall lists stay on screen.
