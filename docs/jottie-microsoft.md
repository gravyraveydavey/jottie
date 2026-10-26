# Microsoft pilot onboarding

Microsoft tenant registration and sign-in are external prerequisites. Jottie never copies another project's tokens, credentials or connected-app sessions.

1. In the approved Entra tenant, register a public native application for Jottie.
2. Configure the iOS/macOS platform with bundle identifier com.gravyraveydavey.jottie and redirect URI msauth.com.gravyraveydavey.jottie://auth.
3. Enable delegated Microsoft Graph User.Read and Files.ReadWrite, obtaining tenant approval where required. Do not configure a client secret in this native app.
4. Build/sign and open Jottie. Under Settings → Microsoft, enter the application/client and tenant UUIDs, then choose Save and sign in.
5. Review Microsoft's consent screen. MSAL stores its cache in Jottie's private Keychain group.
6. Select an existing test folder in SharePoint/OneDrive. Copy its folder sharing link; Jottie resolves it using the signed-in account's granted access.
7. Edit a local folder, paste the remote folder link and connect it. This explicitly enables publishing for that subtree. A child with its own destination overrides inheritance.

Some SharePoint link-resolution or library configurations require permissions beyond this pilot's delegated scopes. Those requests fail visibly; Jottie does not escalate permissions or grant sharing links. Resolve the intended application permissions with the tenant administrator before using that destination.

Publication verifies the pinned destination's drive ID, item ID and URL before writing. AI tags only affect local filing; they cannot choose remote roots or grant access. Sensitive or uncertain analysis is held. Aggregate context is publishable only when every referenced source is within the same configured destination and is eligible for publication.

## Remote layout

Under the chosen remote parent:

- Meetings/<meeting UUID>/<content hash>/ contains transcript.md, transcript.txt, meeting.md, meeting.txt and metadata.json.
- Meetings/<meeting UUID>/current.json identifies the current published revision.
- Folders/<folder UUID>/<input hash>/ contains context.md, context.txt, context.json and folder.json.
- Folders/<folder UUID>/Current Context.txt and current.json provide the current folder knowledge.

Immutable revisions use fail-on-conflict upload sessions. Retries verify stored receipts or recover them by checking exact remote bytes. Current projections use ETags and If-Match, preserving remote edits as conflicts. No Graph bearer token is forwarded to an upload/download URL.

Local deletion, moves and disabling publishing do not revoke access to existing remote copies. Remove those copies separately if required. This is one-way publication; remote content is not an editable source of truth for Jottie.
