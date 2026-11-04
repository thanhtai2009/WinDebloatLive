# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Fixed
- run.bat: elevation works from folders whose name has brackets or an ampersand, such as "WinDebloatLive (1)".
- Only one instance runs at a time.
- Cancel keeps the result: the summary, the backup and the restart prompt still appear; Cancel during the
  restore point stops before any change.
- Undo reports values of a signed-out user as failed instead of marking them restored.
- REG_NONE values can be backed up and restored; two runs in the same second get separate backup files.
- No automatic rescan while a dialog is open, so Apply after a preview no longer fails with "a task is running".
- Downloaded rules may not delete service, Winlogon or LSA entries, write more execution locations or UAC
  values, or disable protected scheduled tasks; more critical services are protected.
- Vietnamese texts use "bộ quy tắc" throughout; opt-in warning shows the app name in the UI language; undo list
  shows readable dates; long manual-reinstall lists stay on screen.

## 1.0.0 — 2026-11-03

### Added
- First release: debloats a running Windows 10 (1809 or newer) or Windows 11 PC.
- Simple mode (one click, safe defaults) and Advanced mode (choose every app and setting, presets).
- App removal for all users or only the signed-in user; user settings can also go to new accounts.
- Preview of the exact changes, System Restore point before applying, log file and restart prompt.
- JSON backup of every change and Undo from any backup.
- Shared app and tweak lists with WinDebloat Tool, with verified automatic updates.
- Console mode with preview, unattended run, backup list and undo.
- English and Vietnamese interface, partial Chinese and Khmer.
- Modern interface that follows the Windows light or dark theme and scales sharply on high-DPI screens.
