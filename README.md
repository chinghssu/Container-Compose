# Container-Compose (fork)

This is a fork of [mcrich23/container-compose](https://github.com/mcrich23/container-compose), which brings Docker Compose files to [Apple Container](https://github.com/apple/container).

The goal of this fork is that an existing `docker-compose.yml` runs on Apple Container **without changes**. It adds the pieces that were missing for a typical web stack (Postgres + Python backend + Node frontend with bind mounts), and each one is being proposed upstream as a separate pull request.

For everything else, including installation via Homebrew, the full Compose support tables and the general documentation, see the **[upstream README](https://github.com/mcrich23/container-compose)**.

## What this fork adds

### 1. String-form `command` and `entrypoint` are split into arguments

```yaml
command: npm run dev
command: >
  sh -c "alembic upgrade head && uvicorn app.main:app --reload"
```

Upstream passes the whole string as a single argument, so the runtime looks for an executable literally named `npm run dev`. This fork splits it with shell quoting rules (single and double quotes, backslash escapes, no variable expansion), as Docker Compose does. An unterminated quote fails with an error naming the field.

### 2. Anonymous volumes (`- /app/node_modules`)

```yaml
volumes:
  - ./frontend:/app
  - /app/node_modules   # keep the packages installed in the image
```

Upstream skips destination-only volumes, so the bind mount hides what the image installed. This fork backs each one with a volume named after the project, service and path, so `up` reattaches the same data when it recreates the container.

Apple Container mounts new volumes empty, while Docker copies the image's files into an empty volume. This fork does that copy itself when the volume is first created, keeping the owner and permissions of the image's directory, so it also works for images that run as a non-root `USER`. The `nocopy` option leaves the volume empty, as in Docker.

### 3. `exec`, `logs`, `start`, `stop` and `restart`

```sh
container-compose exec backend python -m pytest -q
container-compose logs --follow -n 50 backend frontend
container-compose stop frontend
container-compose start frontend
container-compose restart --timeout 5 backend
```

| Command | Behavior |
|---|---|
| `exec` | Runs a command in a service's running container and exits with its status. A `--` before the command is accepted. Keeps stdin attached and allocates a TTY when stdin is a terminal (`-T` disables it). Supports `-d`, `-e`, `-u`, `--uid`, `--gid`. |
| `logs` | Prints each container's output prefixed with its service name. Supports `--follow`, `-n`/`--tail`, `--no-log-prefix`. |
| `start` / `stop` / `restart` | Act on existing containers of exactly the named services (all when none are named) without recreating them. Start in dependency order, stop in reverse. `stop` uses `stop_grace_period` unless `--timeout` is given. A container that cannot be stopped makes the command exit with an error. |

### 4. New volumes start empty, so databases can initialize

Apple Container formats each volume as an ext4 disk image whose root contains a `lost+found` directory. Postgres, MySQL and other images refuse to initialize a data directory that holds anything:

```
initdb: error: directory "/var/lib/postgresql/data" exists but is not empty
```

This fork creates each top-level volume when a selected service first mounts it, and removes that directory right then with `rmdir` (run as root), which only removes an empty directory and so never deletes data. Volumes that already exist are left untouched. See also [apple/container#1730](https://github.com/apple/container/issues/1730).

## Installing this fork

Requirements: a Mac with Apple silicon, macOS 26 or later, [Apple Container](https://github.com/apple/container) installed and started (`container system start`), and Swift 6.1 or later (Xcode).

```sh
git clone https://github.com/chinghssu/Container-Compose.git
cd Container-Compose
git checkout integration   # all changes of this fork combined
make build
sudo make install          # installs to /usr/local/bin
```

If you installed the upstream version with Homebrew, remove it first (`brew uninstall container-compose`) so the two do not conflict on your `PATH`.

## Known limitations

These are specific to this fork's additions. For the general limits, see the upstream support tables.

- **Some short flags are taken.** `-f` selects the compose file and `-t` allocates a TTY in every subcommand, so use `logs --follow` and `stop --timeout`. `exec -w` selects the project directory, not the working directory inside the container.
- **`down` stops containers but does not remove them**, as upstream. Remove them with `container delete <name>` when needed.
- **Anonymous volumes are kept** after the container is removed, and there is no `--renew-anon-volumes`. Delete one with `container volume delete <name>` to start again from the image.
- **Preparing a new volume runs the image of the service that first mounts it, as root**, which needs `/bin/sh` (and `cp` and `stat` for anonymous volumes). Without them the volume is used as is, with a warning.
- **Top-level volumes that no selected service mounts are not created.**
- **Of the anonymous volume options, only `ro`/`rw` and `nocopy` take effect**; `z`, `Z`, `cached`, `delegated` and `consistent` are ignored.
- **`start` fails for a service with `extra_hosts` after `down`**, which removes the generated hosts file; use `up` instead.
- **Logs are shown container by container**, not interleaved by time, and there are no timestamps.

## Branches

| Branch | Content |
|---|---|
| `integration` | All of the changes below combined; use this one |
| `feat/shell-words-command` | 1. String-form `command` and `entrypoint` |
| `feat/anonymous-volumes` | 2. Anonymous volumes |
| `feat/exec-logs-lifecycle` | 3. `exec`, `logs`, `start`, `stop`, `restart` |
| `feat/volume-lost-found` | 4. New volumes start empty |

Each `feat/*` branch starts from upstream `main` and is kept independent, so it can be reviewed and merged on its own.

## License

Apache License 2.0, as upstream. See [LICENSE](LICENSE). Original work by Morris Richman and the Container-Compose project authors.
