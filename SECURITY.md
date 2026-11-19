# Security policy

## Supported versions

Only the latest release receives fixes.

| Version | Supported |
|---|---|
| 0.1.x | Yes |

## Reporting a vulnerability

Please **don't** open a public issue for a security problem.

Report it privately through GitHub instead: open the repository's
[Security tab](https://github.com/xscade/ntfs-bridge/security) and click
**Report a vulnerability**. Include what you found, how to reproduce it, and
what an attacker could do with it.

You can expect:

- an acknowledgement within 7 days
- an assessment and, if it's confirmed, a plan for a fix
- credit in the release notes when the fix ships, unless you'd rather not be named

## Scope

These are especially relevant:

- A crafted NTFS volume that crashes the extension, escapes the virtual machine,
  or corrupts other data
- Anything that lets the guest read or write outside the disk it was given
- The administrator prompt used for repairs being reachable by other apps
- Problems in the bundled Linux kernel or ntfs-3g that affect NTFS Bridge. We
  track Alpine Linux's security fixes and update the pinned packages.
