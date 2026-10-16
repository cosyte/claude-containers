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
`CLAUDE_AUTH_FOLLOW=0` turns the whole behaviour off (a new login then needs a container
restart, as before). The health line shows `moving to a new account (N sessions to go)` while a
switch is in progress.

This is for changing the account a volume holds. `--accounts a,b` (rotation between several
logged-in accounts on a usage-limit hit) is separate and unchanged.

