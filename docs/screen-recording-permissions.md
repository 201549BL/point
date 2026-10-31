# Screen Recording after local rebuilds

Use `Scripts/install-local.sh` to rebuild, replace, and reopen the installed Point.
Normal feature rebuilds should preserve its permission identity.

## Recover from the old signing mismatch

If Settings shows Point enabled but captures ask for permission again or fail:

1. Run `Scripts/install-local.sh --repair-permissions` from this repository.
   It builds with the release signing identity, stops the installed app, installs
   the verified build, resets **only Point's Screen Recording grant**, and reopens it.
2. Open **Finish Setup…** from Point’s menu bar, then choose **Allow Screen
   Access…**. Allow Point in System Settings → Privacy & Security →
   Screen & System Audio Recording. macOS controls this approval.
3. Choose **Quit & Reopen** in the macOS dialog. Point explicitly accepts the
   system’s quit request and resumes unfinished setup on launch. If you chose
   **Later**, setup also offers **Already enabled? Quit & Reopen**; this fallback
   waits for Point’s process to exit before reopening the same bundle.
4. Capture, press Return, and paste. Run a normal local install once more and
   confirm a second capture succeeds without granting access again.

This is a one-time migration/recovery command, not a step to run after every build.
It does not reset other apps, Accessibility, or all privacy permissions. A policy
managed by an organization or a future macOS consent renewal may still require
approval; Point cannot bypass those decisions.

## What went wrong (2026-10-31)

The published app used **Developer ID Application**, while `install-local.sh`
built Xcode Release using **Apple Development**. Both used
`com.eirikbjorndal.point` at `/Applications/Point.app`. The standalone SwiftPM
bundle script also used the production identifier and allowed ad-hoc signatures.
Those identities are not interchangeable for privacy authorization.

On the affected machine, the installed executable matched the fresh build's
SHA-256, and only one installed Point process was observed. This ruled out a
stale installed executable in that snapshot. The installed build was signed with
Apple Development. Testing it against the published release's designated
requirement returned `code failed to satisfy specified code requirement(s)`.
The exact stored TCC grant was not inspected, so a stale grant is inferred from
that reproducible signing mismatch and the reported prompt loop.

Apple documents that privacy authorization uses designated code requirements to
recognize an app across updates:
[TN3127: Inside Code Signing: Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).
A new binary hash by itself is expected; changing the requirement that identifies
the app is the failure to guard against.

A second defect amplified restart confusion: merely opening Screen Recording
Settings persisted `screenCapturePermissionRelaunchPending`. Every later quit,
including an installer stopping the app, could then spawn a delayed reopen helper.
A helper could reopen during replacement. The marker was observed set on the
affected machine. The restart race was identified in code; it was not reproduced
as an observed duplicate process in this session.

## Prevention built into the workflow

- Local production installs explicitly use Developer ID Application with Point's
  release team. `check-install-signing.sh` validates the bundle identifier,
  signature class, team, and signature integrity, then checks the new build
  against the installed build's actual designated requirement.
- Identity changes stop installation before the existing app is touched. Only
  the explicit repair option skips that compatibility comparison and resets
  Point's grant. Routine installs do not reset permissions.
- SwiftPM bundles use `com.eirikbjorndal.point.dev`, display **Point Dev**, and
  require a stable Apple Development identity. Xcode Debug uses the same dev
  identity, separate from production.
- Installs serialize replacement across worktrees, drain the legacy relaunch
  helper, verify installed bytes and signing, launch the absolute app path
  without forcing another instance, and verify its process is running.
- Opening Settings no longer schedules a future relaunch. Only an explicit
  **Quit & Reopen** does. Old persistent markers are discarded at startup.

## Verification

First-time installs show guided setup without requesting permission until the
user chooses **Allow Screen Access…**. Setup saves its position before handing
off to macOS or reopening Point. On returning, it checks live permission and
verifies the capture path before showing **You’re ready to Point**. Verification
images are discarded in memory without copying or saving. A failed verification
waits for an explicit retry rather than repeatedly triggering system prompts.

Closing setup leaves **Finish Setup…** in the menu bar. **Done**, or successfully
copying or saving a practice screenshot, completes setup. Cancelling the practice
capture returns to the ready screen. Existing installs with capture access skip
the tour; revoked access leads back to setup. Opening Settings and closing setup
never schedule an automatic relaunch.

For manual first-install validation, use a fresh macOS user or a fresh install
without an existing Point grant. Test declining, granting, switching back from
Settings, both macOS-managed and Point-managed reopening, closing and resuming
setup, and cancelling then completing a practice capture. Do not reset the
permission on a working installation just to replay the tour.

### Native Quit & Reopen validation (2026-10-31)

An earlier permission-dialog attempt quit Point without reopening it. Temporary
diagnostics recorded the native quit Apple event from
`com.apple.settings.PrivacySecurity.extension`. With an explicit
`applicationShouldTerminate` reply of `.terminateNow`, the diagnostic build
reopened and resumed setup. The diagnostics were then removed, retaining only
that reply and restoring the instructions to choose macOS’s **Quit & Reopen**.

The installed clean build was tested again with the user granting access and
clicking the native button. An independent process observer confirmed old PID
64836 exited, new PID 64912 launched, and saved setup reached `ready`. The user
also confirmed reopening and resumed setup. No Point relaunch helper or external
reopening command was used during either native-button test. These checks verify
the current flow; they do not establish whether the explicit delegate reply alone
explains the original failure. Normal quitting still never schedules a relaunch.

```sh
swift test
python3 Tests/InstallSigningTests.py
```

The signing tests create disposable app fixtures, sign them with the local keys,
and run the actual installation gate. They cover changed executables signed with
Developer ID, Apple Development replacing production, ad-hoc signing, a dev
bundle identifier, and a signing migration leaving the previous app untouched.
Certificate-dependent tests report skips on machines without the local keys.

For live validation after a signing change, complete the recovery steps above
and perform a normal rebuild/capture cycle. Automated signature checks cannot
prove that macOS has accepted a user consent dialog.

### Verified on 2026-10-31

- All 57 Swift tests and five real-signature installation tests passed.
- The normal installer rejected the old Apple Development identity before
  replacing the installed app. The explicit repair install migrated it to
  Developer ID and reset only Point's Screen Recording permission.
- The user granted access and confirmed capture worked.
- A subsequent normal install passed the signature compatibility gate, reopened
  Point with a new process, and did not reset permissions. The user confirmed
  capture worked without another permission prompt.

The live reinstall used the same executable content; changed executables are
covered by the real-signature fixture test. These results confirm the repaired
workflow on this machine, rather than guaranteeing all future macOS consent behavior.
