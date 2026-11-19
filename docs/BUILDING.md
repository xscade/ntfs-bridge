# Building NTFS Bridge

## Requirements

- A Mac with Apple silicon, running macOS 26.4 or later
- Xcode 26.4 or later
- Go 1.27 or later (`brew install go`)
- An Apple Developer account. FSKit extensions must be signed with a real team,
  and a free account works for local builds.

Everything else (`curl`, `cpio`, `python3`, `shasum`) ships with macOS. Docker
is not used.

## 1. Build the guest

```bash
tools/build-guest.sh
```

This downloads six Alpine Linux packages (the kernel, musl, libuuid and ntfs-3g),
checks each against the SHA-256 pinned in the script, cross-compiles the Go agent
for `linux/arm64`, and writes:

- `build/guest/Image`: the raw arm64 kernel (about 36 MB)
- `build/guest/initrd.gz`: the agent, kernel modules and ntfs-3g (about 2 MB)

Downloads are cached in `build/cache`. To update a package, change its version
and checksum in the script.

## 2. Use your own signing team

The project is set up for the maintainer's team ID, `YBR22TF7H3`. Replace it with
yours (find it at [developer.apple.com/account](https://developer.apple.com/account)
under Membership details):

```bash
TEAM=ABCDE12345
grep -rl YBR22TF7H3 app probe | xargs sed -i '' "s/YBR22TF7H3/$TEAM/g"
```

That updates the Xcode projects, both entitlements files (the shared app group
is prefixed with the team ID) and `app/Shared/MountNotes.swift`. If you also
change the bundle identifier `com.ravi.NTFSBridge`, change it in the same places.
Please don't commit these edits in a pull request.

## 3. Build and install the app

Open `app/NTFSBridge.xcodeproj` and build the **NTFSBridge** scheme, or:

```bash
xcodebuild -project app/NTFSBridge.xcodeproj -scheme NTFSBridge \
  -configuration Release -derivedDataPath build/dd build
```

FSKit only loads extensions from apps in `/Applications`. Install with:

```bash
tools/install-app.sh "build/dd/Build/Products/Release/NTFS Bridge.app"
```

The script unmounts NTFS Bridge volumes, replaces the installed app in place, and
re-registers it. It also avoids the things known to reset the extension's switch
in System Settings, such as leaving a second copy with the same bundle ID
registered with Launch Services. It reports the switch's state if you have built
the probe (below).

Then turn on the extension: **System Settings › General › Login Items &
Extensions › By Category › File System Extensions › NTFS Bridge**.

The Xcode projects are generated from `app/project.yml` and `probe/project.yml`
with [XcodeGen](https://github.com/yonaskolb/XcodeGen). The generated projects are
committed, so you only need XcodeGen if you change those files
(`cd app && xcodegen`).

## Developer tools

### `ntfsb`: test against disk images

`ntfsb` boots the same microVM against an image file, without FSKit. It's the
quickest way to test the guest agent and the protocol.

```bash
cd host
swift build -c release
codesign -s - -f --entitlements ntfsb.entitlements .build/release/ntfsb
.build/release/ntfsb --guest ../build/guest test.img mkfs TEST   # create an NTFS image
.build/release/ntfsb --guest ../build/guest test.img selftest   # exercise every operation
```

Create `test.img` first, for example with `mkfile -n 256m test.img`, and sign
the binary as shown, since booting a VM needs the
`com.apple.security.virtualization` entitlement. Run
`ntfsb` with no arguments to list all commands (`ls`, `cat`, `put`, `check`,
`repair`, `mount`, `crash`, `bench`, …).

### `FSKitProbe`: is the extension enabled?

```bash
xcodebuild -project probe/FSKitProbe.xcodeproj -scheme FSKitProbe \
  -configuration Release -derivedDataPath build/probe-dd build
build/probe-dd/Build/Products/Release/FSKitProbe.app/Contents/MacOS/FSKitProbe list
```

### Logs

```bash
log stream --predicate 'subsystem BEGINSWITH "com.ravi.NTFSBridge"' --level debug
```

The extension logs under `com.ravi.NTFSBridge.FS` and the app under
`com.ravi.NTFSBridge`.
