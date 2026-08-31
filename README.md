# TriBridge Updater

A single shell script that keeps a [TriBridge](https://github.com/TheHypixelGuardians/TriBridge) install up to
date on a schedule, and manages the bot process while it is at it.

Run weekly from cron, it fetches the bot's repository and compares the local commit against its remote. **If
nothing has changed it stops there and the bot keeps running untouched.** That is the whole point: a restart
drops every Hypixel connection, and they come back one guild per ten seconds, so an unchanged repository must
not cost the guild anything. Only when there are new commits does it pull, reinstall dependencies if the
manifests changed, and restart the bot.

It lives in its own repository so that it never appears in the bot's checkout — nothing to gitignore, nothing
that a `git pull` can conflict with, and the bot's repository stays exactly as it was cloned.

## Requirements

| Requirement | Notes                                                                        |
|-------------|------------------------------------------------------------------------------|
| Linux       | Any distribution with `bash`, `git` and cron. `flock` (util-linux) is used if present |
| Node.js     | v22 or newer — the same one the bot needs                                     |
| TriBridge   | An existing checkout that is already configured and able to start             |

This is an **updater, not a supervisor**. It only runs when cron runs it, so if the bot crashes mid-week
nothing brings it back until the next scheduled run. If you need that, use `systemd` or `pm2` for the process
and have this script restart through the supervisor instead.

## Install

1. **Clone this repository** somewhere outside the bot's checkout — next to it is fine:

   ```bash
   git clone <this-repo-url> ~/TriBridge-Updater
   cd ~/TriBridge-Updater
   chmod +x update.sh
   ```

2. **Tell it where the bot is.** The script cannot infer this, because it no longer lives inside the bot's
   folder. Set `TRIBRIDGE_DIR` to the bot's checkout:

   ```bash
   export TRIBRIDGE_DIR=/home/youruser/TriBridge
   ```

   It refuses to run without it, and checks that the path actually contains `src/index.js` rather than
   discovering the mistake halfway through a restart.

3. **Check it can see everything:**

   ```bash
   ./update.sh status
   ```

   That prints the bot's state, the commit it is on, where the logs go, and the exact cron line to use — with
   your real paths already filled in, so you can paste it rather than reconstruct it.

4. **Hand the bot over to the script.** If the bot is already running, stop it however you started it, then:

   ```bash
   ./update.sh start
   ```

   This matters. The script restarts the bot by the pid in `.bot.pid`, so it can only restart a bot it started
   itself. A bot launched by hand has no pid file, and the update will not be able to bring the new code in.

5. **Schedule it.** `crontab -e`, then add the line `./update.sh status` printed — it looks like this, for
   Sundays at 05:00:

   ```cron
   0 5 * * 0 TRIBRIDGE_DIR=/home/youruser/TriBridge /home/youruser/TriBridge-Updater/update.sh >> /home/youruser/TriBridge-Updater/logs/cron.log 2>&1
   ```

   Pick a quiet hour. The restart is brief, but it is a visible gap in the bridge.

### If node is installed through nvm

cron runs with a minimal `PATH`, so an `nvm`-installed Node is invisible to it even though it works perfectly
in your shell. The script sources `nvm.sh` automatically when `node` is not on the path, which covers most
setups. If that does not find it, set `NODE_BIN` to the absolute path alongside `TRIBRIDGE_DIR`:

```cron
0 5 * * 0 TRIBRIDGE_DIR=/home/youruser/TriBridge NODE_BIN=/home/youruser/.nvm/versions/node/v22.11.0/bin/node /home/youruser/TriBridge-Updater/update.sh >> /home/youruser/TriBridge-Updater/logs/cron.log 2>&1
```

Run `which node` in a normal shell to find the value.

## Commands

| Command              | What it does                                                              |
|----------------------|---------------------------------------------------------------------------|
| `./update.sh`        | The weekly check. Restarts only if the bot's repository has new commits    |
| `./update.sh start`  | Start the bot and record its pid                                           |
| `./update.sh stop`   | Stop the bot, `SIGTERM` first and `SIGKILL` after 15 seconds               |
| `./update.sh restart`| Stop then start, without checking for updates                              |
| `./update.sh status` | Bot state, current commit, log paths, and the cron line for this host      |

## What it writes

Everything stays in this folder, and all of it is gitignored:

| Path            | Contents                                                       |
|-----------------|-----------------------------------------------------------------|
| `logs/bot.log`  | The bot's own stdout and stderr                                  |
| `logs/update.log` | One timestamped line per step, plus the output of any failure  |
| `logs/cron.log` | Whatever cron captures, if you use the redirect in the cron line |
| `.bot.pid`      | The running bot's pid                                            |
| `.update.lock`  | Held for the duration of a run                                   |

`logs/update.log` is trimmed to its most recent half once it passes 2 MB, so it cannot grow without bound.
`logs/bot.log` is not — if the bot is chatty, point `logrotate` at it.

## Safety

A few behaviours exist because the obvious alternative caused a real problem:

- **It verifies the pid before signalling it.** `ps -p <pid> -o args=` has to show the bot's own
  `src/index.js` before anything is killed. Pids are recycled, and a stale pid file would otherwise make the
  script kill whatever inherited the number.
- **`git pull --ff-only`.** If someone edited the server's checkout by hand, the update aborts and says so
  rather than creating a merge commit on a production box. The bot is left running on the old code.
- **A failed `npm install` stops the update.** The bot keeps running on the code that was working, rather than
  being restarted onto a half-installed dependency tree.
- **The lock is held on a file descriptor**, not by wrapping the script in `flock <file> <command>`. The bot
  is started as a background child and would inherit the descriptor from the wrapper form, holding the lock
  for as long as the bot runs — which is to say forever, so every later run would silently skip.
- **The bot's checkout is never written to.** The pid file, lock and logs all live beside this script.

## After an unattended restart

Two things from the bot's own
[Updating](https://github.com/TheHypixelGuardians/TriBridge/wiki/Updating) page still apply, and nobody is
watching when cron does it:

- **New or changed slash commands take up to an hour to appear.** They are registered globally at startup and
  Discord propagates them on its own schedule.
- **Read the release's changelog entry** if a config file's format changed. Automation does not remove the
  need to look, and the bot's changelog is where that is called out.

## Troubleshooting

**`TRIBRIDGE_DIR is not set`** — the cron environment is not your shell environment. The variable has to be in
the cron line itself, as in the examples above, or exported from a file the cron line sources.

**`node was not found`** — see [If node is installed through nvm](#if-node-is-installed-through-nvm).

**`git refuses to read the bot's checkout because it is owned by another user`** — cron is running as someone
other than the checkout's owner. Either fix the cron user, or run the command the error prints:

```bash
git config --global --add safe.directory /home/youruser/TriBridge
```

**Nothing happens and the log says another run is in progress** — a previous run is stuck holding the lock.
Check for it with `ps aux | grep update.sh`; if there is no such process, delete `.update.lock`.

**The update ran but the bot is on old code** — the bot was probably started by hand, so there was no pid file
to restart from. Stop it however you started it and use `./update.sh start` from then on.
