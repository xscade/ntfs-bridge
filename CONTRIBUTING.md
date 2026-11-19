# Contributing to NTFS Bridge

Thanks for helping. NTFS Bridge writes to people's disks, so correctness matters
more than speed here. This guide explains how to get changes in safely.

## Reporting a bug

Open an [issue](https://github.com/xscade/ntfs-bridge/issues/new/choose) using
the bug report form. The most useful reports include:

- your macOS version and Mac model
- the NTFS Bridge version (select the app in Finder and choose File › Get Info)
- how the drive was last used in Windows (shut down, hibernated, Fast Startup)
- what the menu bar shows for the drive (Read & write, Read-only and its note)
- the log around the problem:
  ```bash
  log show --last 10m --predicate 'subsystem BEGINSWITH "com.ravi.NTFSBridge"' --info
  ```

If you think a drive was damaged, stop using it, and don't run repairs before
reporting. Mention it in the issue title.

Security problems go through [SECURITY.md](SECURITY.md), not public issues.

## Proposing a change

For anything larger than a small fix, open an issue first so we can agree on the
approach before you spend time on it.

1. Fork the repository and create a branch from `main`.
2. Follow [docs/BUILDING.md](docs/BUILDING.md) to build and install your copy.
   Don't commit your signing team ID.
3. Make your change. Keep each pull request focused on one thing.
4. Test it (see below) and describe what you tested in the pull request.
5. Open a pull request against `main`.

## Testing

Before any change that touches the guest, the protocol or the extension:

- **Image test.** Build `ntfsb` and run the self-test against a fresh image:
  ```bash
  cd host && swift build -c release
  codesign -s - -f --entitlements ntfsb.entitlements .build/release/ntfsb
  mkfile -n 256m /tmp/test.img
  .build/release/ntfsb --guest ../build/guest /tmp/test.img mkfs TEST
  .build/release/ntfsb --guest ../build/guest /tmp/test.img selftest
  ```
  It exercises every operation read-write, remounts, and checks the volume with
  `ntfsfix -n`. It must end with `SELFTEST PASSED`.
- **Stress test.** On a fresh 1 GB image, `ntfsb ... stress 96` writes, reads
  back and syncs six files in parallel, and fails if I/O stalls for 60 seconds.
  It must end with `STRESS PASSED`. Run it for any change to `BridgeClient`,
  `NBDServer` or the guest's I/O paths.
- **Real drive test.** Install the app and copy, rename and delete files on a
  spare NTFS drive in Finder, then eject it. Use a drive with nothing you need.
  If you can, check it afterwards in Windows with `chkdsk X:`.
- **Guest agent.** `cd guest && go vet ./...` must be clean.

## Code style

- **Swift:** follow the existing code. Use four-space indentation and Swift
  concurrency (`async`/`await`) rather than callbacks where FSKit allows it.
  Keep FSKit glue in `app/Extension` and shared logic in `NTFSBridgeCore`.
- **Go:** run `gofmt`. The agent is PID 1, so it must never panic on bad input.
  Return an errno to the host instead.
- **Protocol:** any change to the wire format updates
  [docs/PROTOCOL.md](docs/PROTOCOL.md), `guest/wire.go` and
  `host/Sources/NTFSBridgeCore/Wire.swift` together, in the same pull request.
- Comments explain *why*, not *what*.

## Commit messages

Write the summary line in the imperative mood ("Fix rename across directories",
not "Fixed …"), keep it under about 70 characters, and explain the reasoning in
the body when it isn't obvious.

## License

NTFS Bridge is licensed under the GPL-3.0. By contributing, you agree that your
contributions are licensed under the same terms.

## Code of conduct

Everyone taking part is expected to follow the
[Code of Conduct](CODE_OF_CONDUCT.md).
