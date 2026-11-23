# Changing the Claude account

Log the new account into the credential volume the containers mount, and they follow by
themselves. No restart, no recreate:

```
claude-account-login personal      # logs into claude-auth-personal (the stack's AUTH_VOLUME)
make login                         # the same for the default claude-auth volume
claude-account-list                # each volume's account, and the containers on it: in sync / moving
claude-sessions -C maker account   # that container: the account in use and who is still moving
```

Every running container on that volume then:

1. **takes the new credential** within one sync tick (~30 s) and updates its cached identity
   (the boot log and `claude-logs` say `Auth account : the shared credential is now <email>`);
2. **moves each session at its next idle moment**: the session restarts and resumes its
   conversation, so no turn is cut off (`claude-sessions account --now` moves the busy ones
   too; `CLAUDE_SESSIONS_SWITCH_FORCE_AFTER=<seconds>` does that automatically after a wait);
3. **tells a session that a usage limit had stopped to continue**, since getting past a limit is
   the usual reason to switch (`CLAUDE_SESSIONS_SWITCH_NUDGE=0` turns that off);
4. gets **fresh Remote Control links** under the new account, named as before: Claude will not
   reattach a link another account owns, so the sessions appear in the Claude app of the new
   account, and the old ones go offline in the old account's.

The old account cannot come back by accident. A session still running on it refreshes the OLD
account's token into the container's own credential file; until every session has moved, the
sync never copies that file up to the shared volume. And a container that was stopped across the
change (a dormant service) replaces its own stale credential at boot, before any session starts.
`CLAUDE_AUTH_FOLLOW=0` turns the whole behavior off (a new login then needs a container
restart, as before). The health line shows `moving to a new account (N sessions to go)` while a
switch is in progress.

This is for changing the account a volume holds. A container with several accounts
(`--accounts a,b`, `CLAUDE_ACCOUNTS`) rotates between them by itself on a usage-limit hit, and
switches when you ask, below.

## Switching between the accounts of multi-account mode

```
claude-sessions account --use personal                # inside the container
claude-sessions -C maker account --use personal --now # from the host; --now moves busy sessions at once
```

The agent cannot read another account's credential, so `--use NAME` asks the entrypoint's root
listener (§6a). It refuses a name that is not in `CLAUDE_ACCOUNTS`, an account without a valid
token (`claude-account-login NAME` on the host fixes that), an account with no `.claude.json`
beside its credential (logged in by some other route), and any switch in a container with
`CLAUDE_AUTH_FOLLOW=0`; nothing changes then. Otherwise it records NAME as the active account,
which a restart keeps, and the credential sync takes it over within one tick (~30 s) as it does
a new login: the credential and the cached identity at once, then each session at its next idle
moment, with a fresh Remote Control link under that account (`--now` moves the busy ones too).
The command waits for that takeover (up to 45 s) and then prints what `claude-sessions account`
prints: the email in use, the active name, and the sessions still on the previous account. A
container without `CLAUDE_ACCOUNTS` refuses `--use` with a message. The usage-limit rotation is
unchanged and carries on from the account chosen.

