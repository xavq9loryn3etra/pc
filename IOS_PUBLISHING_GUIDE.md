# iOS Publishing Guide (TestFlight) via Codemagic

This document outlines how our iOS TestFlight publishing pipeline is configured in Codemagic. It is intended for any developer on the team who needs to trigger builds or understand the release process to our company Apple Developer account.

## Overview

We use **Codemagic** to fully automate the iOS build and code signing process. You do **not** need to manually generate certificates or provisioning profiles on your local machine to publish the app. The entire process is handled in the cloud via the `ios-workflow` defined in `codemagic.yaml`.

## 1. App Store Connect Integration

To communicate with our company's Apple Developer account securely, Codemagic uses an App Store Connect API Key.
*   **Integration Name:** In the Codemagic UI, this integration is named **`popcorn`**.
*   **What it does:** It allows Codemagic to automatically fetch provisioning profiles and upload the final `.ipa` to TestFlight without requiring manual 2FA logins.

## 2. Automated Code Signing

Our `codemagic.yaml` is configured to use Codemagic's automatic code signing CLI. Here is how it works under the hood:

*   **Environment Group:** The pipeline relies on an environment variable group named **`ios_signing`**.
*   **Private Key:** Inside this group, there is a secure environment variable called **`CERTIFICATE_PRIVATE_KEY`**. This is the private key corresponding to our Apple Distribution Certificate.
*   **The Script:** During the build, the `Set up Keychain & Fetch Signing Files` step runs:
    ```bash
    app-store-connect fetch-signing-files "com.popcorn.flutterClient" \
      --type IOS_APP_STORE \
      --create \
      --certificate-key=@env:CERTIFICATE_PRIVATE_KEY
    ```
    This automatically connects to our Apple account, fetches (or creates if necessary) the correct provisioning profile for the App Store/TestFlight, and applies it to the Xcode project.

## 3. Triggering a Release

To trigger a release to TestFlight:
1.  Ensure your code is merged into the branch that Codemagic is monitoring for releases (usually `main` or `release`).
2.  Go to the Codemagic dashboard for this project.
3.  Start a new build and select the **`iOS TestFlight Release`** workflow.

## 4. TestFlight Submission (IMPORTANT)

By default, our `codemagic.yaml` is configured to upload the build but **not** automatically submit it to external testers:

```yaml
publishing:
  app_store_connect:
    auth: integration
    submit_to_testflight: false
```

**What this means for you:**
After the Codemagic build succeeds, the build will appear in App Store Connect under the TestFlight tab.
1.  Log in to [App Store Connect](https://appstoreconnect.apple.com/).
2.  Navigate to the app.
3.  You may need to provide **Export Compliance Information** (e.g., standard encryption questions) before the build is available to internal testers.
4.  If you want to release it to external tester groups, you will need to manually add the build to the group and submit it for Beta App Review.

*If you want Codemagic to automatically distribute the build to testers, change `submit_to_testflight: true` in `codemagic.yaml` before running the build.*

## Troubleshooting

*   **Code Signing Errors:** If the build fails at the code signing step, verify that the `ios_signing` environment group exists in the Codemagic UI for this project and that the `CERTIFICATE_PRIVATE_KEY` is still valid and has not been revoked in the Apple Developer Portal.
*   **App Store Connect Connection Issues:** Ensure the App Store Connect integration named `popcorn` is active and the API key hasn't expired.
