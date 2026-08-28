# Release setup

The release workflow starts when you push a version tag. It archives and signs
`Tecolot.app`, notarizes and staples the app, builds a ZIP for Sparkle and a
signed, notarized, stapled DMG for people who download by hand, adds both to a
GitHub release, and appends the release to the Sparkle appcast.

The app is notarized before the DMG is built so that the ticket is stapled to
`Tecolot.app` itself. Sparkle installs the app out of the ZIP, and an app with
no stapled ticket makes every user wait for an online Gatekeeper check the first
time they open it.

## One-time Apple setup

You need an active Apple Developer Program membership.

1. Create a **Developer ID Application** certificate for team `PJQC57N853`.
2. Install the certificate and its private key in Keychain Access.
3. Export the identity as a password-protected `.p12` file.
4. Create an App Store Connect API key that can use the notarization service.
   Download its `.p8` file. Apple permits this download only once.

A Developer ID Installer certificate is not necessary. That certificate signs
installer packages, not applications or DMG files.

## One-time Sparkle setup

Sparkle signs each update with an EdDSA key that has nothing to do with Apple
code signing. Nothing about it needs a change in the Apple Developer portal.

1. Get Sparkle's tools, either from
   `https://github.com/sparkle-project/Sparkle/releases` or from the resolved
   package in DerivedData at
   `SourcePackages/artifacts/sparkle/Sparkle/bin/`.
2. `./bin/generate_keys` makes a key pair, keeps the private key in your login
   Keychain, and prints the public key. `./bin/generate_keys -p` prints the
   public key of a key you already have.
3. The public key belongs in `Tecolot/Info.plist` under `SUPublicEDKey`. It is
   already there.
4. `./bin/generate_keys -x sparkle-private-key.txt` exports the private key for
   CI. Add it as the `SPARKLE_ED_PRIVATE_KEY` secret, then delete the file.

**Back up the private key.** If you lose it, no copy of Tecolot that people have
already installed can ever update again. Every user has to find the new version
and install it by hand. The key is in your login Keychain as "Private key for
signing Sparkle updates".

The public key in `Info.plist` and the private key in the secret are a pair. If
you ever replace one, you must replace the other in the same release, and any
release signed with the old key becomes uninstallable.

## GitHub environment and secrets

In the repository settings, create an environment named `release`. You can add
a required reviewer to prevent an accidental release. Add these environment
secrets:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_APPLICATION_P12_BASE64` | Base64 text of the `.p12` file |
| `DEVELOPER_ID_APPLICATION_P12_PASSWORD` | Password used to export the `.p12` file |
| `APP_STORE_CONNECT_API_KEY_ID` | API key ID |
| `APP_STORE_CONNECT_API_ISSUER_ID` | API issuer ID |
| `APP_STORE_CONNECT_API_KEY_P8_BASE64` | Base64 text of the `.p8` file |
| `SPARKLE_ED_PRIVATE_KEY` | Text of the exported Sparkle private key |

Create the Base64 values without line breaks:

```sh
base64 -i DeveloperIDApplication.p12 | tr -d '\n' | pbcopy
base64 -i AuthKey_KEYID.p8 | tr -d '\n' | pbcopy
```

Base64 is an encoding, not encryption. Do not commit these values. Store them
only as GitHub secrets. Delete local export files when you no longer need them.

You can add a secret with the GitHub CLI. This example reads the value from a
file and does not put it in shell history:

```sh
gh secret set DEVELOPER_ID_APPLICATION_P12_BASE64 \
  --env release < <(base64 -i DeveloperIDApplication.p12 | tr -d '\n')
gh secret set SPARKLE_ED_PRIVATE_KEY --env release < sparkle-private-key.txt
```

## Update hosting

Sparkle reads `https://tecolot.com/appcast.xml`. GitHub Pages serves it from
`website/public/`, published by `.github/workflows/pages.yml`. Pages for this
repository uses a workflow build type, not a branch, so no `CNAME` file takes
part: the custom domain is a repository setting, and it is already set to
`tecolot.com`.

What is left to do once:

1. In the Squarespace DNS panel, point the apex at GitHub Pages with A records
   `185.199.108.153`, `185.199.109.153`, `185.199.110.153` and
   `185.199.111.153`, plus the matching AAAA records, and make `www` a CNAME to
   `migueldeicaza.github.io`.
2. Run the Publish website workflow once, from the Actions tab or with
   `gh workflow run pages.yml --ref main`.
3. Turn on Enforce HTTPS in the Pages settings after GitHub issues the
   certificate. It cannot be turned on before the first deploy succeeds.

Sparkle refuses an insecure feed, so HTTPS is necessary, not optional. Confirm
`curl -I https://tecolot.com/appcast.xml` returns 200 before you ship a build
that points at it.

The release workflow commits the new appcast entry and then asks the website
workflow to publish it. It has to ask by name: a push made with the automatic
`GITHUB_TOKEN` starts no other workflow, so nothing would deploy on its own and
the release would reach no one.

Because the feed ships with the website, a website deploy that fails also stops
update delivery. `pages.yml` reads `SUFeedURL` out of `Tecolot/Info.plist` and
refuses to deploy a site that does not carry the feed at that path.

## Make a release

The tag must contain two or three numeric parts. A leading `v` is optional.
The recommended form is:

```sh
git tag -a v1.0.0 -m "Tecolot 1.0.0"
git push origin v1.0.0
```

The workflow uses the tag as `MARKETING_VERSION`. It uses the GitHub run number
as `CURRENT_PROJECT_VERSION`. If notarization succeeds, the workflow publishes
`Tecolot-1.0.0.dmg` and `Tecolot-1.0.0.zip` on the GitHub release for that tag,
then commits the new appcast entry to `main`.

Sparkle compares `CURRENT_PROJECT_VERSION`, that is `CFBundleVersion`, and not
the tag. The GitHub run number always increases, which is what Sparkle needs. Do
not change `CURRENT_PROJECT_VERSION` to the marketing version: builds that
people already have carry run numbers such as 20, and Sparkle reads `0.0.15` as
lower than `20`, so it would offer no more updates.

## References

- [Create Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)
- [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [GitHub Actions secrets](https://docs.github.com/en/actions/concepts/security/secrets)
- [Sparkle documentation](https://sparkle-project.org/documentation/)
- [Sparkle publishing guide](https://sparkle-project.org/documentation/publishing/)
