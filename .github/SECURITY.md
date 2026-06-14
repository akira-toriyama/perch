# Security policy

`perch` runs as a global UI-action daemon with **Accessibility**
privileges, so a vulnerability could let an attacker enumerate
sensitive on-screen content (window titles, focused control
labels) or synthesise UI presses against arbitrary apps.

## Reporting

**Please do not open public GitHub issues for security bugs.**

- **Private report (preferred):** open a draft advisory via GitHub's
  [security advisories](https://github.com/akira-toriyama/perch/security/advisories/new).
- **Email:** akira.toriyama.dev@gmail.com — please include "perch"
  in the subject so it's easy to triage.

Include:

- the version you're running (`perch config --doctor` prints it)
- a minimal reproduction (config snippet + the app perch was
  pointed at, or a step-by-step description)
- the impact you observed and any mitigations you've considered

I aim to acknowledge within 7 days and to coordinate disclosure on a
timeline that matches the severity. There is no bug bounty.

## Supported versions

The latest minor release on `main` is supported. Older releases get
fixes only by upgrading.

## Trust boundary in `config.toml`

`config.toml` is treated as a trusted input — it's the user's own
file on their own machine. perch does not curl, share, or sync
this file. The `exclude-apps` list is the only knob that can
*expand* what perch ignores; there is no `include-apps` allow-list
flag that could be used to grant perch access to apps the user
didn't explicitly grant Accessibility to. macOS's TCC is the only
gatekeeper for what AX trees perch can read.
