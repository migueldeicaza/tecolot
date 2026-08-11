# Release setup

The release workflow starts when you push a version tag. It archives and signs
`Tecolot.app`, creates and signs a DMG, notarizes and staples the DMG, and adds
the DMG to a GitHub release.

## One-time Apple setup

You need an active Apple Developer Program membership.

1. Create a **Developer ID Application** certificate for team `PJQC57N853`.
2. Install the certificate and its private key in Keychain Access.
3. Export the identity as a password-protected `.p12` file.
4. Create an App Store Connect API key that can use the notarization service.
   Download its `.p8` file. Apple permits this download only once.

A Developer ID Installer certificate is not necessary. That certificate signs
installer packages, not applications or DMG files.

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
```

## Make a release

The tag must contain two or three numeric parts. A leading `v` is optional.
The recommended form is:

```sh
git tag -a v1.0.0 -m "Tecolot 1.0.0"
git push origin v1.0.0
```

The workflow uses the tag as `MARKETING_VERSION`. It uses the GitHub run number
as `CURRENT_PROJECT_VERSION`. If notarization succeeds, the workflow publishes
`Tecolot-1.0.0.dmg` on the GitHub release for that tag.

## References

- [Create Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)
- [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [GitHub Actions secrets](https://docs.github.com/en/actions/concepts/security/secrets)
