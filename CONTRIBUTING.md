# Contributing to MacSlowCooker

Thanks for your interest in helping. This document covers the setup,
expectations for changes, and notes about working with the privileged
helper tool.

## Setup

```bash
# 1. Get the source
git clone https://github.com/hakaru/MacSlowCooker.git
cd MacSlowCooker

# 2. Install xcodegen (Homebrew)
brew install xcodegen

# 3. Swap the Apple Developer Team ID. The helper validates incoming XPC
#    connections by Team OU, so a fork signed with a different Team will
#    have its XPC calls rejected until this is run.
bin/set-team-id.sh ABC1234XYZ        # your 10-character Team ID

# 4. Generate the Xcode project
xcodegen generate

# 5. Open in Xcode
open MacSlowCooker.xcodeproj
```

## Build & test

From the command line:

```bash
# Universal Binary release build
xcodebuild build \
  -project MacSlowCooker.xcodeproj -scheme MacSlowCooker -configuration Release \
  -derivedDataPath build CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=YOUR_TEAM \
  ONLY_ACTIVE_ARCH=NO

# Tests (signing not required)
xcodebuild test \
  -project MacSlowCooker.xcodeproj -scheme MacSlowCooker \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

GitHub Actions runs the same build + test pipeline on every PR.

## Working with the privileged helper

The helper is a root LaunchDaemon registered through `SMAppService`. Two
operational quirks worth knowing:

- After re-deploying the app, **the running helper does NOT
  automatically pick up the new binary.** Either bump
  `HelperTool/Info.plist`'s `CFBundleVersion` so the app's
  `HelperInstaller.refreshIfStale` re-registers, or run:

  ```bash
  sudo launchctl kickstart -k system/com.macslowcooker.helper
  ```

- `/Applications/MacSlowCooker.app` ends up root-owned the first time
  it runs. Take ownership once with:

  ```bash
  sudo chown -R $(whoami):staff /Applications/MacSlowCooker.app
  ```

  After that, `ditto`-based redeploys don't need sudo.

See [CLAUDE.md](CLAUDE.md) for a longer architectural tour and a list of
macOS 26 / Tahoe gotchas. (CLAUDE.md doubles as both the dev guide and the
context document for AI coding assistants used during development.)

## Coding standards

- **Public-facing strings (UI labels, log messages, user-visible docs)
  should be English.** Internal Japanese is fine in CLAUDE.md and in
  comments that document author-facing decisions.
- **Tests are required for new business logic.** Pure functions belong in
  `Shared/` so the test target can reach them. The helper-tool readers
  follow this pattern: `SMCFanDecoder`, `IOAcceleratorSelection`,
  `SensorNameMatcher`, `PlistStreamSplitter`, `PowerMetricsParser` are
  all pure and tested; the IOKit-touching wrappers are thin.
- **Don't add new comments that just describe what the code does.** Add
  comments when the *why* is non-obvious — a hidden constraint, a workaround
  for a specific macOS quirk, behavior that would surprise a reader.

## Submitting changes

- Fork, branch, push, open a PR against `main`.
- Keep PRs focused. One issue per PR is ideal; mixed bug/feature PRs make
  bisecting harder.
- Reference the relevant GitHub issue in the PR description (`Closes #N`)
  when applicable.
- Contributions are accepted under the [Apache License 2.0](LICENSE);
  submitting a PR signals agreement (Apache License Section 5).

## Security model

The privileged helper trusts XPC peers that satisfy this designated
requirement:

```
identifier "com.macslowcooker.app" and anchor apple generic and certificate leaf[subject.OU] = "K38MBRNKAT"
```

In plain English: any binary signed by the same Apple Developer Team and
shipping with bundle id `com.macslowcooker.app` can talk to the helper.
That intentionally includes development builds on the maintainer's
machine, which is why the requirement is Team-OU rather than a specific
cdhash.

What this means for forks and contributors:

- Running a fork **requires running `bin/set-team-id.sh <YOUR_TEAM_ID>`**
  so the helper trusts your locally-signed binary. Without that the
  helper will install but every XPC call will be rejected.
- The helper does **not** distinguish certificate types. A Mac App Store
  signature and a Developer ID signature with the same Team OU are
  treated identically. If you ever distribute a notarized release, you
  may want to additionally pin the Developer ID Application certificate
  OID (`1.2.840.113635.100.6.1.13`) — see
  [issue #25](https://github.com/hakaru/MacSlowCooker/issues/25).
- The helper exposes only four no-argument XPC methods (start/stop
  sampling, fetch latest sample, helper version). It accepts no
  caller-supplied paths, SMC keys, or process arguments, so the surface
  a malicious-but-correctly-signed peer could exploit is small.
- The helper never reads or writes user files. Sampling data lives in
  memory and is delivered over XPC.

For potential security issues, please **email the maintainer directly**
rather than filing a public issue, so we can investigate and ship a fix
before disclosure.

## Reporting issues

Open an issue on GitHub. Useful info:

- macOS version (`sw_vers -productVersion`)
- Mac model (`sysctl -n hw.model`)
- Logs from `Console.app` filtered by `subsystem == "com.macslowcooker"`
- Screenshot of the popup if relevant

(See the "Security model" section above for security-issue reporting.)
