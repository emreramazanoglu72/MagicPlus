# Security Policy

## Supported versions

The latest release is the only supported version. Fixes ship in a new release rather than as
patches to older ones.

## Reporting a vulnerability

Please **do not open a public issue** for a security problem.

Report it privately through GitHub's
[private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
(the "Report a vulnerability" button on the Security tab).

Please include what an attacker can actually do, the steps to reproduce it, and your macOS
version. You can expect a first response within a week.

## What this app can reach

Worth knowing when judging severity:

- It runs **unsandboxed** and holds **Accessibility** permission, so it can read and move
  the windows of any application.
- It stores **clipboard history** — including anything you copy — in
  `~/Library/Application Support/MagicPlus`, unencrypted. Card numbers, API keys, private
  key blocks and JWTs are detected and deliberately never written, and apps that mark their
  content as concealed (password managers) are ignored.
- Optional permissions extend that reach: **Screen Recording** (window thumbnails and OCR),
  **Camera** (Mirror), **Calendar** (agenda), **Audio capture** (per-app volume mixing).
- It makes **no network connections** other than Sparkle's update check against the
  configured `SUFeedURL`. There is no telemetry and no analytics.

Reports about the clipboard file being readable by other processes running as your own user
are known and out of scope: any process running as you can read it, exactly as it can read
the rest of your home directory.
