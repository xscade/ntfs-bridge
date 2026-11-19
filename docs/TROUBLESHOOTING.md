# Troubleshooting

## The drive doesn't appear in Finder

1. Check that the extension is on: **System Settings › General › Login Items &
   Extensions**, switch to **By Category**, click **ⓘ** next to **File System
   Extensions**. NTFS Bridge must be switched on. The menu bar app shows a banner
   when it's off.
2. NTFS Bridge must be in `/Applications`. macOS only loads file system
   extensions from apps there.
3. Open **Disk Utility** and check whether the drive is listed. If it isn't, the
   problem is the cable, port or drive, not the file system.

## The drive mounts read-only

The menu bar shows why. The usual reasons:

| Note | What to do |
|---|---|
| Windows is hibernated or Fast Startup is on | In Windows, hold **Shift** while choosing **Shut down**, or turn off Fast Startup in Control Panel › Power Options › Choose what the power buttons do. Then reconnect the drive. |
| The volume needs a disk check (dirty) | In Windows, run `chkdsk X: /f` on the drive. If you can't get to a Windows PC, use **First Aid** in Disk Utility, which runs `ntfsfix`. That's a partial repair, so still run `chkdsk` when you can. |
| The drive is write-protected | Check for a physical lock switch on the drive or SD card adapter. |

NTFS Bridge refuses to write to a hibernated drive on purpose. Windows keeps
parts of the file system in its hibernation file, and when it resumes, it
overwrites anything you changed. That can corrupt the volume.

## "Mounted by …" another driver

Another NTFS app, or macOS's built-in read-only driver, mounted the drive first.
Click **Remount with NTFS Bridge**. If you have another NTFS app installed, turn
its file system extension off in System Settings so the two don't compete.

## The extension switch turned itself off

macOS sometimes resets the switch when an app with the same bundle ID is
registered twice, or after an update. Turn it back on in System Settings. If you
build from source, install with `tools/install-app.sh`, which avoids the known
causes.

## Getting logs for a bug report

```bash
log show --last 10m --predicate 'subsystem BEGINSWITH "com.ravi.NTFSBridge"' --info
```

Attach the output to your [issue](https://github.com/xscade/ntfs-bridge/issues/new/choose).
Check it first for file or folder names you'd rather not share.

## Uninstalling

1. Eject all NTFS drives.
2. Quit NTFS Bridge from its menu bar icon.
3. Drag **NTFS Bridge** from Applications to the Trash.
4. Optionally, remove its settings:
   ```bash
   defaults delete com.ravi.NTFSBridge
   ```
