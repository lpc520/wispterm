# Design: Load OpenSSH Config Into SSH Profiles

## Goal

Make the first SSH setup faster by letting users import existing OpenSSH config
entries into WispTerm's saved SSH profiles. The feature is available from the
Command Center and from the New Session -> SSH flow when no WispTerm SSH
profiles exist yet.

## User Flow

1. Open Command Center and run `Load OpenSSH Config`, or open New Session -> SSH
   with an empty WispTerm SSH profile list and choose `Load OpenSSH config`.
2. WispTerm reads the default OpenSSH config file for the current user:
   `~/.ssh/config`.
3. WispTerm imports compatible host blocks and returns to the SSH profile list.
4. The user can select an imported profile to open a new SSH session, or edit it
   before connecting.

If no compatible entries are found, the SSH list stays open so the user can add
a server manually.

## Import Semantics

WispTerm imports one profile per compatible `Host` alias.

Imported fields:

- `name`: the OpenSSH `Host` alias.
- `host`: `HostName` when present, otherwise the alias.
- `user`: `User`.
- `port`: `Port`, defaulting to `22` when omitted.
- `proxy_jump`: `ProxyJump` when present.

Skipped entries:

- `Host *`.
- Any alias containing OpenSSH pattern characters (`*`, `?`, `[`, `]`).
- Entries missing both a usable alias and host.
- Entries missing `User`, because WispTerm's SSH profile form requires a user.
- Entries whose host/user/port/proxy jump do not pass the existing WispTerm SSH
  safety validators.

Existing profile merge:

- Match existing WispTerm profiles by profile name first, then by host.
- Update name, host, user, port, and proxy jump.
- Preserve the existing password unless the profile is newly created.
- Do not import passwords; OpenSSH config does not store password auth.

The profile cap remains the current `SSH_PROFILE_MAX` of 16. Import stops when
the cap is reached.

## UI Integration

Command Center adds a searchable command:

- Title: `Load OpenSSH Config`
- Detail: `Import ~/.ssh/config into SSH profiles`

New Session -> SSH changes:

- In normal SSH manage mode, show `Load OpenSSH config` as an action row.
- When the SSH profile list is empty, this row is still visible along with
  `New SSH Server` and `Cancel`, giving first-time users a direct import path.
- Activating the row imports and then reopens the SSH profile list.

No new global keyboard shortcut is added.

## Architecture

OpenSSH parsing belongs in a small pure module, not in the renderer:

- New module: `src/openssh_config_import.zig`
- Responsibilities:
  - Parse OpenSSH config text into import candidates.
  - Apply only the supported keys: `Host`, `HostName`, `User`, `Port`,
    `ProxyJump`.
  - Ignore comments and blank lines.
  - Handle multiple aliases on one `Host` line by producing one candidate per
    compatible alias with the same block settings.

The overlay remains responsible for persistence because it already owns
`g_ssh_profiles`, `saveSshProfiles`, and the existing profile merge behavior.
It will call the pure parser, merge candidates into `g_ssh_profiles`, save
`ssh_hosts`, and return to the list UI.

## Ghostty Reference

Ghostty has `ghostty +ssh` and `ssh-cache`, but those are CLI conveniences for
wrapping `ssh`, forwarding environment, installing terminfo, and caching
terminfo installation state. Ghostty does not save GUI SSH profiles or import
OpenSSH config into a launcher. WispTerm should therefore keep this feature in
its Command Center / New Session profile layer, while preserving the existing
Windows SSH/SCP rule: do not introduce OpenSSH connection sharing options.

## Error Handling

The import should be non-destructive:

- Missing `~/.ssh/config`: keep the SSH list open.
- Malformed or unsupported blocks: skip those entries.
- Profile cap reached: import up to the cap and stop.
- Save failure: keep in-memory imported rows for the current UI session if they
  were added, but do not claim persistence.

The UI should avoid printing or exposing secrets. This path does not read
passwords.

## Tests

Add fast unit tests for the pure parser:

- Parses a basic host with `HostName`, `User`, and `Port`.
- Defaults `host` from alias and `port` to `22`.
- Parses `ProxyJump`.
- Splits multiple aliases and skips wildcard aliases.
- Ignores comments and blank lines.
- Skips candidates without `User`.

Add overlay-level tests where practical:

- Empty SSH list row count includes `Load OpenSSH config`.
- SSH manage row mapping activates the import action row.
- Merge preserves an existing password when updating an existing profile.

Full verification before finishing:

- `git diff --check`
- `zig build test`
- `zig build test-full`
