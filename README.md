<p align="center">
  <img src="assets/icon-256.png" alt="WinDebloat Live" width="128">
</p>

<h1 align="center">WinDebloat Live</h1>

<p align="center">
  Debloat and optimize the Windows 10 / 11 PC you are using, safely and reversibly.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/PowerShell-5.1-5391FE.svg?logo=powershell&logoColor=white" alt="PowerShell 5.1">
  <img src="https://img.shields.io/badge/Windows-10%201809%2B%20%7C%2011-0078D6.svg" alt="Windows 10 1809+ | 11">
</p>

<p align="center">
  English · <a href="README_VI.md">Tiếng Việt</a>
</p>

---

## Overview
WinDebloat Live removes preinstalled apps and turns off ads, suggestions, Copilot and automatic app installs
directly on a running Windows 10 or Windows 11 PC. It is the companion of WinDebloat Tool, which applies the
same rules to installation images, and uses the same app and tweak lists. **Simple** mode cleans the PC with
one click using safe defaults; **Advanced** mode allows every app and setting to be chosen, with a preview of
the exact changes. The interface follows the Windows light or dark theme, scales on high-DPI screens and is available in Vietnamese (default) and English, with partial Chinese and Khmer.

## Highlights
- Removal of preinstalled apps for all users (including new accounts) or only the signed-in user.
- Registry tweaks for the machine, the signed-in user and, optionally, the Default profile for new accounts.
- Only rules that apply to the detected edition and build are shown; setup-only rules are skipped with a reason.
- Preview of every change before it is applied, a detailed log, and a restart prompt at the end.
- Rule lists in [`data/`](data) update automatically in the background, verified by SHA256 (can be turned off).

## Quick start
1. Right-click the zip → **Properties** → tick **Unblock**, then extract it.
2. Double-click **`run.bat`** and accept the administrator prompt.
3. Choose **Simple** and press **Optimize this PC**, or choose **Advanced**, select items and press **Apply**.
4. Restart the PC when asked.

Command line examples (run from an elevated PowerShell):

```powershell
.\WinDebloatLive.ps1 -NoGui -Preview                    # show what would change, change nothing
.\WinDebloatLive.ps1 -NoGui -Preset aggressive          # console run with confirmation
.\WinDebloatLive.ps1 -NoGui -Yes -EnableSystemProtection -Restart
.\WinDebloatLive.ps1 -ListBackups
.\WinDebloatLive.ps1 -Undo latest
```

## Requirements
- Windows 10 version 1809 (build 17763) or newer, or Windows 11; client editions only.
- Windows PowerShell 5.1 (included in Windows). PowerShell 7 is not needed; the tool restarts itself in 5.1.
- Administrator rights (`run.bat` requests them).

## Safety
- A System Restore point is created first. System Protection is turned on only when the user agrees.
- Every changed registry value, service start type and removed app is recorded in a JSON backup in
  `%ProgramData%\WinDebloatLive\backups`; **Undo** restores them. The folder is writable by administrators only.
- Core components are never removed: Microsoft Store, App Installer, frameworks, Windows Security, Edge and
  WebView2, Start and shell packages, Photos, Calculator, Notepad and media codecs. Windows Terminal is removed
  only when chosen explicitly in Advanced mode.
- Each item is applied on its own: an access-denied or failing item is logged and skipped, the run continues.
- Removed apps can be reinstalled from Microsoft Store when their files are no longer on the PC.

Testing on a virtual machine or after a restore point is recommended before use on important PCs.

## Credits
- WinDebloat Tool: shared app and tweak lists, rule format and update mechanism.
- [Raphire/Win11Debloat](https://github.com/Raphire/Win11Debloat) (MIT): app list and safety ratings.
- [ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil) and
  [farag2/Sophia-Script-for-Windows](https://github.com/farag2/Sophia-Script-for-Windows) (MIT): privacy tweaks.

Windows, DISM and System Restore are Microsoft products. Nothing from Microsoft is redistributed here.

## License
[MIT](LICENSE)
