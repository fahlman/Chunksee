# Releasing Chunksee

Ryan approved GitHub releases in [#568](https://github.com/fahlman/Chunksee/issues/568).
The first release follows the completed foundation and Ryan's test list, before Metal work.
This repository stays private, so downloads require repository access. Updates are manual.
TestFlight and App Store distribution are separate, deferred work.

Use Apple's archive/export and notarization tools below. The export options are checked in at
`Support/DeveloperIDExportOptions.plist`. The commands were checked against Xcode 27.2's help and
[Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).
This document describes the procedure; a merged procedure is not evidence that a release passed it.

## Prepare the release candidate

The first version is **0.1.0**, build **1**, tag **v0.1.0**. Set `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION` in the project in the final release-candidate PR before checks.
Later releases increase the build number and choose the version in their release record.
Version settings belong in committed source, not command-line overrides.

Before any build/test, read the shared reservation registry
[fahlman/Tetris#41](https://github.com/fahlman/Tetris/issues/41), its comments and the queued/running
jobs. Respect the existing runtime handoff. Release preparation does not bypass a reservation.

Use a clean, committed `main` checkout with the Kit pin already released. In #568 record:

- The full source commit, tree, version/build, intended tag, Kit version and resolved commit.
- Each included source PR's Claude approval and matching merge tree; Claude's release approval
  must name the final candidate commit and the checks. Ryan's standing publishing approval is
  recorded in #568; it does not replace those reviews.
- Required Release build/test results for that commit, toolchain and dependencies. Reuse valid
  results; otherwise run the documented commands below. Record the first release's completed
  foundation and Ryan's test list too. An archive alone is not the required test run.
- The Developer ID certificate identity, team, validity and the saved notarization profile name.
  Ryan supplies credentials through `xcrun notarytool store-credentials chunksee-notary` in his
  Terminal. Never put passwords, private keys or tokens in commands, source, logs or GitHub.

Run each stage deliberately in the same Bash shell from the repository root; later stages use
the variables established earlier. Each block enables error handling again, so a fresh shell
fails on missing values instead of using empty paths or hiding a failed pipeline. To resume in
a new shell, restore the exact values from the retained release evidence before continuing.
Stop on failure and keep its evidence; do not repeat a submission or overwrite a release to
hide a failed attempt.
Replace `APPROVED_MAIN_COMMIT` with the approved full commit before starting:

```sh
set -euo pipefail
release_commit='APPROVED_MAIN_COMMIT'
release_version='0.1.0'
release_build='1'
release_tag="v$release_version"
git fetch origin main --tags
test -z "$(git status --porcelain)"
test "$(git rev-parse HEAD)" = "$release_commit"
test "$(git rev-parse origin/main)" = "$release_commit"
release_dir=$(mktemp -d "/Users/ryan/Developer/Chunksee-runs/release-$release_version-$release_build.XXXXXX")
printf '%s\n' "$release_commit" > "$release_dir/source-commit.txt"
git rev-parse 'HEAD^{tree}' > "$release_dir/source-tree.txt"
cp Chunksee.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved "$release_dir/Package.resolved"
xcodebuild -version > "$release_dir/xcode.txt"
xcrun swift --version > "$release_dir/swift.txt"
xcrun --sdk macosx --show-sdk-version > "$release_dir/sdk.txt"
sw_vers > "$release_dir/macos.txt"
if xcodebuild -checkFirstLaunchStatus > "$release_dir/setup-status.txt" 2>&1; then
    printf '0\n' > "$release_dir/setup-exit.txt"
else
    printf '%s\n' "$?" > "$release_dir/setup-exit.txt"
fi
security find-identity -v -p codesigning > "$release_dir/signing-identities.txt"
```

Record the selected Developer ID Application identity for team `PUT2KYMV2W` and its expiration.
If several valid identities exist, confirm which one Xcode selected in the exported signature.
Never proceed with an expired certificate or a different team. A nonzero Xcode setup status is
recorded; the actual required build and test still decide whether the source passes.

When valid exact-candidate results do not already exist, run the required commands owned by
REPO_AGENTS.md's "Build and test" section, with `-derivedDataPath`, `-resultBundlePath` and
`-onlyUsePackageVersionsFromResolvedFile` added to isolate and retain release evidence. The
test command uses `ChunkseeTestHost`, never the real app container. Keep test products separate:

```sh
set -euo pipefail
xcodebuild -project Chunksee.xcodeproj -scheme Chunksee -destination 'platform=macOS' \
    -configuration Release -derivedDataPath "$release_dir/check-build" \
    -onlyUsePackageVersionsFromResolvedFile build 2>&1 | tee "$release_dir/build.log"
xcodebuild -project Chunksee.xcodeproj -scheme Chunksee -destination 'platform=macOS' \
    -configuration Release -derivedDataPath "$release_dir/check-test" \
    -resultBundlePath "$release_dir/tests.xcresult" \
    -onlyUsePackageVersionsFromResolvedFile test ENABLE_TESTABILITY=YES \
    2>&1 | tee "$release_dir/test.log"
```

## Archive and export

Recheck the reservation and runtime ownership before the archive. Use a fresh DerivedData
directory, with no `ENABLE_TESTABILITY` override or test-host condition. Never run tests in it.
Inspect the build log/request to confirm the ordinary app target and shipping Release settings.
Do not use `script/build_and_run.sh`: agents must not launch `com.fahlsing.Chunksee`.
The first use of the Developer ID private key may display a macOS permission prompt. Ryan
must answer it himself; if it appears, stop and tell him what is waiting. Agents do not approve
system prompts.

```sh
set -euo pipefail
xcodebuild -project Chunksee.xcodeproj -scheme Chunksee -destination 'generic/platform=macOS' \
    -configuration Release -derivedDataPath "$release_dir/archive-build" \
    -archivePath "$release_dir/Chunksee.xcarchive" \
    -onlyUsePackageVersionsFromResolvedFile archive 2>&1 | tee "$release_dir/archive.log"
xcodebuild -exportArchive -archivePath "$release_dir/Chunksee.xcarchive" \
    -exportOptionsPlist Support/DeveloperIDExportOptions.plist \
    -exportPath "$release_dir/export" 2>&1 | tee "$release_dir/export.log"
release_app="$release_dir/export/Chunksee.app"
test "$(plutil -extract CFBundleIdentifier raw -o - "$release_app/Contents/Info.plist")" = com.fahlsing.Chunksee
test "$(plutil -extract CFBundleShortVersionString raw -o - "$release_app/Contents/Info.plist")" = "$release_version"
test "$(plutil -extract CFBundleVersion raw -o - "$release_app/Contents/Info.plist")" = "$release_build"
codesign --verify --deep --strict --verbose=2 "$release_app" 2>&1 | tee "$release_dir/signature-before-notary.txt"
codesign --display --verbose=4 "$release_app" 2> "$release_dir/signature-details.txt"
codesign --display --entitlements - --xml "$release_app" > "$release_dir/exported-entitlements.plist" 2> "$release_dir/entitlements.log"
plutil -lint "$release_dir/exported-entitlements.plist"
for entitlement in \
    'com\.apple\.security\.app-sandbox' \
    'com\.apple\.security\.files\.user-selected\.read-only' \
    'com\.apple\.security\.files\.bookmarks\.app-scope' \
    'com\.apple\.security\.network\.client'; do
    test "$(plutil -extract "$entitlement" raw -o - "$release_dir/exported-entitlements.plist")" = true
done
if plutil -extract 'com\.apple\.security\.get-task-allow' raw -o - \
    "$release_dir/exported-entitlements.plist"; then
    printf '%s\n' 'Unexpected debugging entitlement in the exported app.' >&2
    exit 1
fi
test -z "$(git status --porcelain)"
test "$(git rev-parse HEAD)" = "$release_commit"
```

Before uploading, inspect the retained signature: Developer ID Application, team `PUT2KYMV2W`,
hardened runtime and a secure timestamp are required. Compare the exported entitlements with
`Chunksee/Chunksee.entitlements`: sandbox, selected files read-only, app-scoped bookmarks and
outgoing network access remain enabled. Signing identity entitlements may be added by Xcode;
debugging (`get-task-allow`), broader file access or other capability changes are not permitted.
Keep the XML entitlement file and record each entitlement check's exit with the release evidence;
the final extraction must fail because `get-task-allow` is absent, even if its value would be false.
Check any nested executable code as part of signature verification; never repair a failed export
by applying an ad hoc signature. Keep the archive, dSYMs and export records.

## Notarize, staple and verify

This stage uploads the exported app to Apple. Use only the keychain profile name. Upload once,
save the submission ID and query that same submission until its status is terminal:

```sh
set -euo pipefail
ditto -c -k --keepParent "$release_app" "$release_dir/notarization.zip"
xcrun notarytool submit "$release_dir/notarization.zip" --keychain-profile chunksee-notary \
    --output-format plist > "$release_dir/notary-submit.plist"
notary_id=$(plutil -extract id raw -o - "$release_dir/notary-submit.plist")
printf '%s\n' "$notary_id" > "$release_dir/notary-id.txt"
```

Run the following status command again if processing is still in progress, saving each response
under a new name. A timeout or observation error is not a rejected submission and does not justify
another upload. If submission output was lost, recover its ID from notarization history before
deciding whether another upload is needed.

```sh
set -euo pipefail
notary_status_file=$(mktemp "$release_dir/notary-status.XXXXXX")
xcrun notarytool info "$notary_id" --keychain-profile chunksee-notary \
    --output-format plist > "$notary_status_file"
plutil -p "$notary_status_file"
```

Only an **Accepted** status permits the next stage. Retrieve and inspect Apple's log even for
an accepted submission. Keep rejected submissions and their logs with the issue that owns the fix.

```sh
set -euo pipefail
test "$(plutil -extract status raw -o - "$notary_status_file")" = Accepted
xcrun notarytool log "$notary_id" --keychain-profile chunksee-notary "$release_dir/notary-log.json"
xcrun stapler staple "$release_app" 2>&1 | tee "$release_dir/staple.txt"
xcrun stapler validate "$release_app" 2>&1 | tee "$release_dir/stapler-validate.txt"
codesign --verify --deep --strict --verbose=2 "$release_app" 2>&1 | tee "$release_dir/signature-final.txt"
spctl --assess --type execute --verbose=4 "$release_app" 2>&1 | tee "$release_dir/gatekeeper.txt"
release_zip="Chunksee-$release_version-$release_build.zip"
ditto -c -k --keepParent "$release_app" "$release_dir/$release_zip"
(cd "$release_dir" && shasum -a 256 "$release_zip" > "$release_zip.sha256")
```

The distributed zip is created **after** stapling. Never attach `notarization.zip`. These checks
do not launch the app. Record their actual exits and output; do not describe the artifact as
signed, notarized or accepted by Gatekeeper without the corresponding evidence.

## Tag and publish

Give Claude the release record with the exact commit, reviewed source PRs, checks, exported
version/build, signing and notarization evidence, final zip hash and proposed release notes.
Resolve any findings before tagging or publishing. Check that the remote commit, dependencies
and artifact still match that approval. Existing tags/releases are immutable; stop on a collision.

Prepare `tag-message.txt` and `release-notes.md` in `release_dir`, beginning each GitHub-facing
record with `[Codex]` or `[Claude]`. The notes include the version/build, macOS 27 requirement,
Apple silicon requirement, source/tag, Kit pin, meaningful changes, known limits and SHA-256.
For the first release, explain installation and the first-launch point in the section below.
Use file arguments so newlines and literal text survive the CLI.

```sh
set -euo pipefail
git fetch origin main --tags
test -z "$(git status --porcelain)"
test "$(git rev-parse HEAD)" = "$release_commit"
test "$(git rev-parse origin/main)" = "$release_commit"
git tag -a "$release_tag" "$release_commit" -F "$release_dir/tag-message.txt"
git push origin "refs/tags/$release_tag"
gh release create "$release_tag" --repo fahlman/Chunksee --verify-tag --draft \
    --title "Chunksee $release_version" --notes-file "$release_dir/release-notes.md" \
    "$release_dir/$release_zip" "$release_dir/$release_zip.sha256"
```

Inspect the draft's tag, notes and attachments against the approved record, then publish it:

```sh
set -euo pipefail
gh release edit "$release_tag" --repo fahlman/Chunksee --draft=false
gh release view "$release_tag" --repo fahlman/Chunksee --json url,tagName,isDraft,assets \
    > "$release_dir/published-release.json"
mkdir "$release_dir/download-check"
gh release download "$release_tag" --repo fahlman/Chunksee --dir "$release_dir/download-check" \
    --pattern "$release_zip" --pattern "$release_zip.sha256"
cmp "$release_dir/$release_zip.sha256" "$release_dir/download-check/$release_zip.sha256"
(cd "$release_dir/download-check" && shasum -a 256 -c "$release_zip.sha256")
```

Confirm `isDraft` is false, the tag resolves to the approved commit, and the downloaded hash
matches before reporting availability. Link the published release and evidence from #568 and
#469. If publication partially fails, inspect the existing draft/tag/assets and preserve the
failure; never retag, overwrite assets or claim publication from an upload command alone.

## Installation and first launch

Release notes tell Ryan to download the zip from GitHub, expand it, quit the old app and move
`Chunksee.app` into Applications. He opens it himself. The release keeps the real bundle ID and
uses his existing Chunksee container; agents must never launch it or reset that container.
If macOS asks whether the newly signed app may access data from a previous version, explain
that this concerns access to existing app data. Do not claim that such a prompt occurred unless
Ryan sees it, and do not remove signatures, quarantine information or app data to bypass it.
