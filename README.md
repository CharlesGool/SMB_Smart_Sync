# 📸 Magisk SMB Auto Sync

A powerful, privacy-focused, and highly customizable Magisk/KernelSU module that automatically synchronizes your local photos to an SMB server using Rclone. Designed specifically for automated Google Photos backup workflows.

## ✨ Features

* **🔒 Privacy First (External Configuration):** No need to hardcode your sensitive data (IP, username, password) into the script. The module generates an external config file in your internal storage, keeping your credentials safe if you ever share or fork the code.
* **🤖 Smart UI Detection:** Automatically monitors the Google Photos app. Once the "Backup complete" (configurable for any language) text appears on the screen, it safely kills the app and locks the screen to save battery.
* **⚡ Hardware Optimized:** Applies hardware-level restrictions (locks minimum screen brightness and limits CPU max frequency to 2.0GHz) during background sync to prevent overheating and save power.
* **🛡️ Bulletproof Background Execution:** Utilizes CPU Wake Locks to ensure the sync process completes even when the screen is off. Includes a trap mechanism to safely release wake locks if the process is terminated.
* **🧹 Auto-Cleanup:** Automatically deletes outdated photo directories locally to free up storage space.
* **🌍 Multi-Language Ready:** The UI text detection can be easily customized in the config file to match your system language (e.g., "Backup complete", "備份完成", "备份完成").

## 🚀 Installation & Usage

1. Download the latest `.zip` release.
2. Flash the module via **Magisk** or **KernelSU**.
3. **Reboot** your device.
4. After rebooting, wait a few seconds. The module will automatically generate a configuration file at:
   `/storage/emulated/0/SMB_Sync/config.conf`
5. Open `config.conf` with any text editor on your phone (or via PC).
6. Fill in your SMB credentials and preferences:
   * `SMB_HOST`: Your SMB server IP.
   * `SMB_USER`: Your SMB username.
   * `SMB_PASS`: Your SMB password.
   * `SMB_REMOTE_DIR`: The remote directory on your NAS/Server.
   * `SCAN_INTERVAL`: How often to poll for sync (in seconds).
   * `BACKUP_SUCCESS_TEXT`: The exact text Google Photos displays when a backup is finished in your language.
7. Save the file. The script will automatically detect your changes, encrypt your password using Rclone, and start the sync loop. **No further reboot is required!**

## 📂 Configuration Guide

Here is an example of what the generated `config.conf` looks like:

```bash
# SMB Server IP Address
SMB_HOST="192.168.0.2"

# SMB Username (Change this to trigger the script)
SMB_USER="your_username"

# SMB Password
SMB_PASS="your_password"

# Base remote directory (No leading slash)
SMB_REMOTE_DIR="Data/Photos/Camera"

# Polling interval (Seconds)
SCAN_INTERVAL=3

# Google Photos success UI text
# EN: Backup complete | ZH-TW: 備份完成 | ZH-CN: 备份完成
BACKUP_SUCCESS_TEXT="備份完成"
```

## 📝 Logging

If you want to check the sync status or troubleshoot, the module maintains a detailed log file at:
`/storage/emulated/0/,A Files/sync.log`

The log file size is strictly managed (keeps the latest 10,000 lines) to prevent it from eating up your storage.

## 🛠️ Under the Hood

* Powered by a standalone **Rclone** binary for robust multi-threaded transferring.
* Uses Android's native `uiautomator dump` for non-intrusive UI text detection.
* Shell-based variable loading with CRLF auto-sanitization to prevent errors caused by Windows MTP text editing.
