# RCA 0002: Repeated macOS filesystem permission prompts

Status: investigating; signing limitation confirmed, incident cause unconfirmed
Date: 2026-09-27
Owner: RFC 0011; recovery interaction in RFC 0025
Source baseline: `7e087e00dc79fae5d6c421dda011166cd352b296`

## Report and evidence boundary

The user reports a loop of macOS permission dialogs asking to allow access to
directories/folders. They recall running Mole cleaner or Homebrew, but cannot
confirm which command. The macOS version, dialog wording, repeated resource,
Allow/Deny choice, app version, and whether the app had just been updated are
not known. There is no captured TCC log or reproduced incident yet.

Do not mark this RCA resolved based on a plausible code explanation. The
implemented correction enables stable certificate signing; it does not prove
that every prompt during a cleaner's filesystem traversal is erroneous.

## Findings

| Finding | Evidence | Confidence |
|---|---|---|
| All builds force ad-hoc signing | `build.zig` used `codesign --sign -` for helper, GUI, and bundle. `scripts/package-macos.sh` did the same again after universal merging. | Confirmed in source. |
| No stable-signing override existed | Neither build nor packager accepted a certificate identity. | Confirmed in source; corrected by this change. |
| Helper outlives viewer | `spawnDaemon` launches the bundled helper in its own process group; RFC 0012 explicitly preserves its sessions after viewer exit. | Confirmed. |
| Shell commands perform filesystem access themselves | `Session.create -> Pty.spawn -> fork/login_tty/execve` launches the shell, which launches tools. Boring Terminal does not proxy their file opens. | Confirmed. |
| No demonstrated prompt retry loop in terminal code | Daemon startup retries socket connection, not protected-directory access. The config watcher watches Application Support. Cwd inheritance opens the reported directory only on creation, not every frame. | Inspected paths; not proof that no other trigger exists. |
| Actual TCC responsibility for the reported access | The prompt could be attributed to app, helper, shell, a child tool, or a launcher depending on runtime context. | Unknown; requires runtime evidence. |

Apple explains that Files and Folders decisions depend on stable code identity;
ad-hoc signing can cause excessive prompts across changed builds. Apple also
describes helper attribution as a separate failure mode. This directly supports
fixing the signing limitation, but not assigning it as the proven cause of
this particular event. [Apple DTS: On File System Permissions](https://developer.apple.com/forums/thread/678819)

The bundle identifier already exists and is stable. That is insufficient:
an ad-hoc designated requirement is tied to the specific code version. A
certificate-derived requirement allows the system to recognize subsequent
versions from the same signer. Merely signing an identical binary again does
not necessarily change its hash; the concern is changed code/builds, not each
invocation of `codesign`. [Apple TN3127: Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)

## Competing explanations and how to distinguish them

1. **Identity churn across builds or installation changes.** Supported by the
   forced ad-hoc build policy. Compare code requirements and app/helper versions
   before and after a rebuild/update, with the same protected resource. This
   can explain renewed prompts across versions; it does not by itself establish
   an endless loop during one unchanged running command.
2. **Lost or changed responsibility through the persistent helper.** Compare
   the same harmless access with the viewer open, closed, and reopened. Inspect
   the actual responsible identity in TCC diagnostics. Separate process-group
   creation is not sufficient evidence that attribution is broken. Do not
   replace the daemon design or call a private responsibility API on that guess.
3. **Several legitimate privacy domains.** A cleaner can access many protected
   locations. Distinct folder/app-data prompts may look like a loop. Record the
   exact resource and service for each dialog before declaring repetition.
4. **Command behavior or OS policy.** A child command may retry denied access,
   spawn many workers, or request resources with process-scoped authorization.
   Compare the exact same harmless operation in another terminal on the same
   macOS version. Ordinary POSIX permissions, TCC, and endpoint-security denials
   are not interchangeable; capture the actual error and responsible process.

No available evidence establishes a Mole or Homebrew defect. Do not run a
cleaner, change permissions broadly, or remove files merely to reproduce this.

## Mechanism addressed by the fix

Before:

```text
changed app/helper build
  -> build/packager always applies ad-hoc signature
  -> code-version-specific designated requirement
  -> previous authorization may no longer identify this code
  -> new protected access can request consent again
```

After, when configured with a stable certificate:

```text
build/packager receives explicit identity
  -> helper, GUI, bundle signed serially with that certificate
  -> certificate-derived requirements and stable identifiers
  -> macOS can recognize that signing identity across builds
```

This does not grant access in advance or suppress a legitimate macOS prompt.
Apple recommends development signing for development and Developer ID for
distribution when diagnosing these identity problems.
[Apple DTS: Unsandboxed app can't access files](https://developer.apple.com/forums/thread/663889)

## Corrective changes

- `build.zig` accepts `-Dcodesign-identity`, retaining `-` as the existing
  credential-free default.
- `scripts/package-macos.sh` accepts `BORINGTERMINAL_SIGNING_IDENTITY` for the
  final universal artifact. It no longer unconditionally strips a requested
  certificate identity back to ad-hoc at the final packaging stage.
- `scripts/sign-macos.sh` is shared by both paths. It signs helper, GUI, then
  bundle, verifies the result, and sets stable explicit code identifiers.
- Empty/missing-certificate requests fail. There is no silent downgrade to
  ad-hoc signing, custom weak designated requirement, privacy-database edit,
  new entitlement, or permission-request retry.
- RFC 0011 and the release guide document stable signing and the remaining
  credential/GUI-test requirements. Current CI remains accurately labelled
  ad-hoc; credential provisioning and notarization are not fabricated here.

No valid signing identities were available on the investigation machine
(`security find-identity -v -p codesigning` returned zero). The configured
certificate path can therefore be checked for fail-closed behavior, but a
real certificate-signed artifact and its remembered consent need a credentialed
Mac. This is an external dependency for validating the proposed incident fix.

The user confirmed they do not yet have an Apple Developer account or signing
certificate. Keep credential-free builds available and leave certificate-backed
consent-retention validation pending; do not describe the reported loop as fixed.

Installing new bits does not change the running helper's signature. Do not
kill it or its agents automatically: let it drain under RFC 0019, or use the
existing user-confirmed destructive restart after work is saved. Test updates
with a surviving old helper as well as a newly started helper.

## Reproduction and closure checklist

Use a fresh macOS VM snapshot or test account. Launch the app through Finder
or LaunchServices; direct execution under another terminal may change who
macOS considers responsible. Keep the existing native Mach-O main executable.

1. Build/install a fixed-path app, record macOS version, product version,
   bundle path, and signing identity. Read signatures with:

   ```sh
   codesign --display --verbose=4 -r - '/Applications/Boring Terminal.app'
   codesign --display --verbose=4 -r - \
     '/Applications/Boring Terminal.app/Contents/MacOS/boringterminald'
   ```

2. In the test account, create a disposable `Desktop/boring-tcc-fixture.txt`
   through Finder. In Boring Terminal, read only that fixture using `cat`.
   Record the requesting application, exact folder, and choice for each dialog.
3. Repeat the same read after Allow; separately restore the VM and test Deny.
   A remembered denial should report failure, not cause a terminal-owned retry.
4. Repeat with a second shell, after viewer close/reopen, and with the helper
   continuing while the viewer is closed. Do not infer process responsibility
   from process names alone.
5. Change/build the app once, preserving the same certificate identity and
   installation path. Test with the old helper alive, then after an orderly
   session drain and new helper launch. Compare to the ad-hoc build baseline.
6. If repetition remains, capture a short, local `com.apple.TCC` log around the
   harmless read and compare with Terminal.app. Keep raw logs private; they can
   include user paths. Establish whether the same service/resource/identity is
   repeating or the tool is visiting different privacy domains.
7. Only after that minimal case, test the user's exact Mole/brew invocation
   in an expendable environment if it can be recovered. A cleanup operation is
   not part of automated validation on the user's real machine.

Close the incident only when repeated same-resource Allow/Deny behavior is
verified on the affected macOS version, fresh shells and detached-helper cases
pass, and an update preserves consent as expected. If stable signing does not
resolve the same-process case, continue the attribution investigation rather
than marking this signing patch a complete fix.

## Verification of this patch

Verified locally on 2026-09-27 with Zig 0.16.0:

- `/bin/bash scripts/test-macos-signing.sh` passed against disposable native
  app fixtures: valid ad-hoc leaf-first signing, expected code identifiers,
  bundle paths with spaces, and rejection of empty/unavailable identities
  without modifying the fixture binaries.
- `zig build app --summary all`: 32/32 steps passed, including strict bundle
  signature verification.
- `zig build test -Dportable-system-goldens=true --summary all`: 322/322 tests
  passed; the included keyboard-conformance ratchet passed 606 checks.
- Package version check for v0.6.0, shell syntax checks, Zig formatting, and
  `git diff --check` passed.
- The complete local universal DMG build passed for arm64 and x86_64. The DMG
  checksum/integrity, mounted payload, both executable slices, and strict nested
  bundle signatures were verified. This is an unpublished worktree artifact
  using the existing version label, not a new public v0.6.0 release.

The new signing regression runs in both CI and release workflows. These are
packaging/code checks, not simulated TCC grants. Certificate signing and the
TCC GUI acceptance matrix were not exercised. A final identity check still
reported zero valid signing identities.

## Recovery feature interaction

RFC 0025 must not open saved folders just to inspect recovery metadata.
Activate shells lazily and stop on a denied cwd until an explicit user retry.
Do not replay Mole/brew or any previous command during recovery. This prevents
the proposed recovery feature from multiplying a privacy failure, but it does
not retroactively explain this incident.

## Rejected fixes

- **Recommend Full Disk Access to everyone:** broader than the reported need;
  hides identity/attribution faults and does not diagnose the loop.
- **Reset TCC or chmod recursively:** destroys unrelated choices or changes
  ordinary permissions without fixing the privacy identity.
- **Add a usage-description string as the fix:** improves wording, not the
  remembered identity or process attribution.
- **Change `isDirectory` on speculation:** the inspected call runs when a
  session is created, not continuously while Mole/brew executes. It is not an
  established explanation for the report.
- **Remove daemon isolation or use private responsibility SPI:** risks session
  survival without proving the failure mechanism.
- **Claim stable bundle IDs solve ad-hoc signing:** the signer is part of code
  identity; the normal certificate-derived requirement must remain intact.
