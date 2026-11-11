# Novacore

<a href="https://github.com/jonbp/novacore"><img alt="Novacore" src="https://jonbp.github.io/project-icons/novacore.svg" align="right" /></a>

[![GitHub Open Issues](https://img.shields.io/github/issues-raw/jonbp/novacore)](https://github.com/jonbp/novacore/issues)
[![GitHub Open Pull Requests](https://img.shields.io/github/issues-pr-raw/jonbp/novacore)](https://github.com/jonbp/novacore/pulls)

A local LEMP stack in Docker for PHP sites: nginx, PHP-FPM 7.4–8.5 with Xdebug, and MariaDB, driven by a small CLI.

- **No hosts-file edits.** Sites live at `https://<name>.localhost`, which already resolves to 127.0.0.1.
- **Trusted HTTPS.** A local certificate authority issues a certificate per site. Trust it once.
- **PHP version per site**, switched with one command. Xdebug is built into every version.
- **One line of config per site**, and the CLI writes it for you.
- **A tray icon** on Linux, KDE Plasma, macOS and Windows.

## Requirements

- Docker with the Compose plugin:
  - **Linux:** Docker Engine, with your user in the `docker` group.
  - **macOS:** Docker Desktop or OrbStack.
  - **Windows:** Docker Desktop with WSL2. Run Novacore inside WSL and keep your sites in WSL's filesystem; sites on Windows drives are very slow.
- Ports 80, 443 and 3306 free on 127.0.0.1 (configurable in `.env`).

So far Novacore has only been tested on Fedora with Docker Engine.

## Quick start

```sh
ln -s "$PWD/bin/novacore" ~/.local/bin/novacore   # put the CLI on your PATH

novacore up            # first run builds images and creates .env and the CA
novacore trust         # once: trust the local CA (uses sudo)
novacore site add blog # creates sites/blog, a database, and https://blog.localhost
novacore tray install  # optional: add the tray icon
```

The dashboard at <https://localhost> lists every site.

## Sites

Each site is a folder in `sites/` (or set an absolute `SITES_DIR` in `.env`, such as `~/Sites`). `sites.conf` has one line per site:

```
# name          php     root
blog            8.4     -
shop            8.2     web
legacy          7.4     public_html
```

- `php`: the PHP version, or `-` for `DEFAULT_PHP`.
- `root`: the document root. `-` auto-detects `public/`, `web/`, `public_html/` or `htdocs/`, else the folder itself.

Edit it by hand and run `novacore reload`, or use the CLI:

```sh
novacore site add shop --php 8.2 --root web
novacore site add api --no-db       # skip the database
novacore site rm shop               # keeps files; --drop-db drops the database
novacore site list
novacore site info shop             # URL, paths, database settings
```

Subdomains work too (`*.blog.localhost`, for multisite). Containers reach sites by domain over HTTPS, so WordPress loopback requests and calls between sites just work.

## PHP

```sh
novacore php list            # versions, default, and what's running
novacore php blog 8.3        # switch a site
novacore php default 8.4     # default for new sites
novacore shell blog          # bash in blog's PHP container
novacore composer blog install
novacore wp blog plugin list
novacore exec blog php -v    # anything else
```

Only the versions your sites use (plus `DEFAULT_PHP`) are built and run. `novacore build --all` builds every version up front. Each image is about 1 GB; `novacore prune` removes unused ones, and `--cache` also clears Docker's build cache.

Every image includes Composer, WP-CLI, the `mariadb` client, `ssh`, `rsync`, and bcmath, exif, gd, imagick, intl, mysqli, opcache, pcntl, pdo_mysql, redis, soap and zip. Add more in `docker/php/Dockerfile`, then run `novacore build`. PHP runs as your user, so files it creates are yours.

## Error logs

Each site logs PHP errors, warnings and deprecations to `logs/<site>.log`. `display_errors` is on as well, and an app's own log setting (such as WordPress's `WP_DEBUG_LOG`) takes precedence.

```sh
novacore errors blog           # follow blog's log
novacore errors                # follow every site's log
novacore errors blog --clear   # empty it
```

## Xdebug

```sh
novacore xdebug              # show the current mode
novacore xdebug off          # fastest
novacore xdebug on           # "develop,debug" (the default)
novacore xdebug debug,profile
```

`develop` mode is always active. Step debugging starts only for requests with an `XDEBUG_SESSION` cookie or query parameter (a browser extension like "Xdebug helper" sets it), and connects to your IDE on port **9003**. Map `/var/www/sites/<name>` in the container to `sites/<name>` on your machine.

**VS Code** (PHP Debug extension), `.vscode/launch.json` in the site folder:

```json
{
  "version": "0.2.0",
  "configurations": [{
    "name": "Novacore",
    "type": "php",
    "request": "launch",
    "port": 9003,
    "pathMappings": { "/var/www/sites/blog": "${workspaceFolder}" }
  }]
}
```

**PhpStorm:** Settings → PHP → Servers, add `blog.localhost` on port 443, and map the project root to `/var/www/sites/blog`.

## Databases

MariaDB is `mariadb:3306` from PHP and `127.0.0.1:3306` from your machine. User `novacore` / `novacore` can access every database; root's password is `root`.

```sh
novacore db list
novacore db create shop
novacore db import shop dump.sql.gz
novacore db export shop               # writes shop-<timestamp>.sql.gz
novacore db shell shop
novacore db drop shop
```

To make a site work both in Novacore and from tools on your machine, read the host from `NOVACORE_DB_HOST` (set to `mariadb` in the containers) and fall back to `127.0.0.1`. `novacore site info` prints these with your port filled in:

```php
// wp-config.php
define( 'DB_HOST', getenv( 'NOVACORE_DB_HOST' ) ?: '127.0.0.1' );

// Bedrock: config/application.php
Config::define( 'DB_HOST', env( 'NOVACORE_DB_HOST' ) ?: env( 'DB_HOST' ) ?: '127.0.0.1' );

// Laravel: config/database.php, in the mysql/mariadb connection
'host' => env( 'NOVACORE_DB_HOST', env( 'DB_HOST', '127.0.0.1' ) ),
```

Running `wp` on your machine needs PHP with `mysqli` (and the `mysql`/`mariadb` client for `wp db export`). If your PHP version behaves differently, use `novacore wp`.

## SSH from PHP

Commands in the PHP containers (WP-CLI sync packages, private Composer packages, `git` over SSH) can use your keys through your **SSH agent**. Private keys never enter the containers; only the agent and read-only copies of `~/.ssh/known_hosts` and `~/.ssh/config` are shared. Load your keys with `ssh-add`, or `AddKeysToAgent yes` in `~/.ssh/config`. `novacore up` warns if the agent is empty.

| Platform | Agent used |
|---|---|
| Linux with Docker Engine | `$SSH_AUTH_SOCK` |
| Docker Desktop and OrbStack | Docker's forwarded agent (your macOS agent and Keychain) |
| Windows (WSL2) | `$SSH_AUTH_SOCK` inside WSL. Bridge the Windows agent in with a tool like `npiperelay`. |

- `IdentityAgent` and `UseKeychain` in your config are overridden.
- Hosts with `IdentitiesOnly yes` won't work, as the key files aren't in the container. Remove that line for them.
- SELinux relabelling is turned off for the PHP containers, so your `~/.ssh` labels aren't changed.
- If your agent's socket path changes, such as after logging in again, run `novacore up`.

## Tray icon

Novacore has one tray icon, the same everywhere: a globe whose pill shows the status.

| Icon | Status | Meaning |
|:---:|---|---|
| <picture><source media="(prefers-color-scheme: dark)" srcset="tray/previews/running-dark.svg"><img alt="Running" src="tray/previews/running-light.svg" width="32"></picture> | **Running** | Novacore is up and serving your sites. |
| <picture><source media="(prefers-color-scheme: dark)" srcset="tray/previews/stopped-dark.svg"><img alt="Stopped" src="tray/previews/stopped-light.svg" width="32"></picture> | **Stopped** | Docker is reachable, but Novacore's containers aren't running. |
| <picture><source media="(prefers-color-scheme: dark)" srcset="tray/previews/busy-dark.svg"><img alt="Busy" src="tray/previews/busy-light.svg" width="32"></picture> | **Busy** | A command started from the icon is running, such as Start or a PHP switch. |
| <picture><source media="(prefers-color-scheme: dark)" srcset="tray/previews/error-dark.svg"><img alt="Error" src="tray/previews/error-light.svg" width="32"></picture> | **Error** | Docker can't be reached. The panel says why. |

Click it for a panel with Novacore's status, your sites, Start/Stop/Restart, Xdebug and Tools. Right-click for the same as a menu (the Linux Qt icon only has the menu). It covers most of the CLI:

- **Add Site…** asks for a name, PHP version, document root, and whether to create a database.
- **Each site** expands to open it, its git remote, its folder, VS Code or Zed, a terminal, a PHP shell or its error log, switch its PHP version, show its **Info…** (with copy buttons), or remove it.
- **Xdebug** sets the mode; **Tools** opens a database shell, container logs or the sites folder.

```sh
novacore tray install     # on Windows, run inside WSL
novacore tray uninstall
```

It detects your platform, and rebuilds and restarts itself when its source changes (after a `git pull`, say). Commands run detached, so they finish even if the icon quits, and a notification tells you when each is done; click a failure to see its output.

| Platform | How it's installed | Log |
|---|---|---|
| **KDE Plasma** | A Plasma 6 widget in the system tray (`tray/plasmoid/`). Middle-click opens the dashboard. | — |
| **Linux** | A Qt script (`tray/linux/`), added to your launcher and autostart. Needs PySide6 or PyQt6, e.g. `python3-pyside6`. GNOME needs the AppIndicator extension. | `~/.local/state/novacore/tray.log` |
| **macOS** | `~/Applications/Novacore Tray.app`, compiled from `tray/macos/` (needs `xcode-select --install`), started by a LaunchAgent. | `~/Library/Logs/Novacore/tray.log` |
| **Windows** | `NovacoreTray.exe` in `%LOCALAPPDATA%\Novacore`, started from your Startup folder, running the CLI through `wsl.exe`. | `%LOCALAPPDATA%\Novacore\tray.log` |

A few platform notes:

- **KDE Plasma:** you can also add **Novacore** from Add Widgets. If the CLI isn't on your `PATH` or in `~/.local/bin`, set its path in the widget's settings. After updating, restart Plasma (`systemctl --user restart plasma-plasmashell`).
- **macOS:** the icon uses the `PATH` from when you installed it, so run `tray install` again if you move Docker.
- **Windows:** if the icon lands in the overflow (^), drag it onto the taskbar. It only polls while WSL is running, so it won't keep WSL awake.
- If you quit the icon, open **Novacore Tray** from your launcher or Spotlight to start it again.

### Changing the tray icon

The CLI decides everything the icon shows: `novacore tray menu` prints the menu and panel as JSON, and each platform only draws it. To add an item or dialog, change `tray_menu` in `bin/novacore` and every platform picks it up. See [`tray/PROTOCOL.md`](tray/PROTOCOL.md).

The status icon comes from `tray/status.svg`. After changing it or `tray/novacore.svg`, run `tray/build-icons.sh` to rebuild `tray/status-icons.png`, the previews above, and the Windows app icon. The macOS app icons (`tray/macos/Assets.car` and `novacore.icns`) are finished files.

## Everything else

```sh
novacore status        # containers and sites (--json for scripts)
novacore logs nginx    # or mariadb, php84, ...
novacore down
novacore help
```

## How it works

```
bin/novacore               the CLI
docker-compose.yml         nginx, mariadb, php74 … php85
docker/                    nginx, PHP-FPM and MariaDB images and config
sites.conf                 your sites
data/                      generated: vhosts, certificates, dashboard, compose overrides
logs/                      PHP error log per site
tray/                      the tray icon: protocol, status icons and one folder per platform
```

The CLI reads `sites.conf` and generates an nginx vhost and certificate per site, plus `data/compose.generated.yml`, which gives nginx a network alias per domain and shares your SSH agent with PHP. nginx resolves PHP containers per request, so a site on a stopped PHP version returns a 502 rather than breaking nginx. Because libcurl always resolves `*.localhost` to 127.0.0.1, each PHP container relays its own ports 80 and 443 to nginx.

Don't edit `data/` by hand. Deleting it is safe, but you'll get a new CA and need to run `novacore trust` again.

## Troubleshooting

- **Certificate warning.** Run `novacore trust` and restart the browser. If Firefox still complains, import `data/certs/ca.crt` under Settings → Certificates → Authorities.
- **Certificate warning on Windows.** `novacore trust` also adds the CA to your Windows store; click **Yes** when asked, then fully restart Chrome or Edge. Firefox needs `security.enterprise_roots.enabled` in `about:config`. After regenerating `data/`, remove the old "Novacore Local CA" in `certmgr.msc`.
- **Xdebug doesn't connect.** Check your IDE listens on 9003 and your firewall allows the Docker bridge network.
- **SSH: "Permission denied (publickey)".** Your agent has no keys: run `ssh-add`. Debug with `novacore exec <site> ssh -v user@host`.
- **SSH: "Host key verification failed".** Connect once from your own terminal to add the host to `~/.ssh/known_hosts`.
- **Port in use.** Change `HTTP_PORT`, `HTTPS_PORT` or `DB_PORT` in `.env`, then run `novacore up`.
- **A different TLD.** `NOVACORE_TLD=test` works, but you must resolve `*.test` yourself (dnsmasq or hosts file).
