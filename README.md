# Novacore

<a href="https://github.com/jonbp/novacore"><img alt="Novacore" src="https://jonbp.github.io/project-icons/novacore.svg" align="right" /></a>

[![GitHub Open Issues](https://img.shields.io/github/issues-raw/jonbp/novacore)](https://github.com/jonbp/novacore/issues)
[![GitHub Open Pull Requests](https://img.shields.io/github/issues-pr-raw/jonbp/novacore)](https://github.com/jonbp/novacore/pulls)

## About

A local LEMP stack in Docker for running PHP sites: nginx, PHP-FPM (7.4 to 8.5, with Xdebug), and MariaDB. A small CLI handles the setup for you.

- **No hosts-file edits.** Sites live at `https://<name>.localhost`. Browsers and systemd-resolved already send `*.localhost` to 127.0.0.1.
- **HTTPS that just works.** Novacore runs its own local certificate authority and issues a certificate for each site. You trust it once.
- **PHP version per site.** Each version runs in its own container, and switching is one command.
- **Xdebug everywhere.** It's built into every PHP version, and one command sets the mode for all of them.
- **Hardly any config.** There's one line per site in `sites.conf`, and the CLI writes it for you.

## Requirements

- Docker with the Compose plugin:
  - **Linux:** Docker Engine. Your user needs to be in the `docker` group.
  - **macOS:** Docker Desktop or OrbStack.
  - **Windows:** Docker Desktop with WSL2. Run Novacore from inside your WSL distro, and keep your sites in WSL's filesystem. Sites on the Windows drives are very slow through Docker.
- Ports 80, 443 and 3306 free on 127.0.0.1. You can change them in `.env`.

So far Novacore has only been tested on Fedora with Docker Engine.

## Quick start

```sh
# Put the CLI on your PATH
ln -s "$PWD/bin/novacore" ~/.local/bin/novacore

novacore up            # first run builds images and creates .env and the CA
novacore trust         # one-off: trust the local CA (uses sudo)
novacore site add blog # creates sites/blog, a database, and https://blog.localhost
```

The dashboard at <https://localhost> lists every site.

## Sites

Each site is a folder in `sites/`. You can point `SITES_DIR` in `.env` somewhere else, such as `~/Sites`, but use an absolute path. `sites.conf` has one line per site:

```
# name          php     root
blog            8.4     -
shop            8.2     web
legacy          7.4     public_html
```

- `php`: the site's PHP version, or `-` to use `DEFAULT_PHP`.
- `root`: the document root inside the site folder. `-` auto-detects `public/`, `web/`, `public_html/` or `htdocs/`, and otherwise uses the folder itself.

You can edit the file by hand and run `novacore reload`, or use these commands:

```sh
novacore site add shop --php 8.2 --root web
novacore site add api --no-db       # skip creating a database
novacore site rm shop               # files are kept; --drop-db drops its database too
novacore site list
novacore site info shop             # URL, paths, database settings
```

Each site also answers on its subdomains, so `*.blog.localhost` works for multisite setups. Containers can reach sites by domain as well, which means WordPress loopback requests and calls between sites work over HTTPS.

## PHP

```sh
novacore php list            # versions, default, and what's running
novacore php blog 8.3        # switch a site
novacore php default 8.4     # default for new sites
novacore shell blog          # bash in blog's PHP container, in the site folder
novacore composer blog install
novacore wp blog plugin list
novacore exec blog php -v    # anything else
```

Novacore builds and runs only the PHP versions your sites use, plus `DEFAULT_PHP`. When no site uses a version any more, for example after you switch the last one, its container stops. `novacore build --all` builds every version up front.

Each version's image takes about 1 GB. `novacore prune` removes the images of versions no site uses, and `novacore prune --cache` also clears Docker's unused build cache. If a site needs a version again, Novacore rebuilds its image, which takes a few minutes.

Every image includes Composer, WP-CLI and the `mariadb` client. It also has the extensions most apps need: bcmath, exif, gd, imagick, intl, mysqli, opcache, pcntl, pdo_mysql, redis, soap and zip. To add more, edit `docker/php/Dockerfile` and run `novacore build`.

PHP runs as your host user, so any files it creates belong to you.

## Error logs

Each site writes its PHP errors, warnings and deprecations to its own file, `logs/<site>.log`. The files belong to you, so you can open them in your editor or tail them directly.

```sh
novacore errors blog           # follow blog's log
novacore errors                # follow every site's log at once
novacore errors blog --clear   # empty it
```

Errors still show in the page as well, because `display_errors` is on. An app that sets its own log file wins over Novacore's. For example, WordPress's `WP_DEBUG_LOG` writes to `wp-content/debug.log`. Errors from commands you run through `novacore exec` print to your terminal.

## Xdebug

```sh
novacore xdebug              # show the current mode
novacore xdebug off          # fastest
novacore xdebug on           # same as "develop,debug" (the default)
novacore xdebug debug,profile
```

`develop` mode shows errors and `var_dump()` output as Xdebug's formatted (orange) tables in the page. It's always on, with no trigger needed.

Debugging only starts for requests that carry the trigger, which is an `XDEBUG_SESSION` cookie or query parameter. A browser extension like "Xdebug helper" sets it for you. Xdebug connects back to your IDE on port **9003**.

Path mapping: `/var/www/sites/<name>` in the container is `sites/<name>` on your machine.

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

**PhpStorm**: go to Settings → PHP → Servers and add `blog.localhost`, port 443. Turn on path mappings and map the project root to `/var/www/sites/blog`.

## SSH and remote servers

Commands run inside the PHP containers can use your SSH keys. That covers things like WP-CLI packages that sync from a live server, private Composer packages, and `git` over SSH. The containers include `ssh` and `rsync`.

Your private keys never enter the containers. Instead, Novacore shares your **SSH agent**, along with read-only copies of `~/.ssh/known_hosts` and `~/.ssh/config`. Your keys need to be loaded into the agent. `novacore up` tells you if they aren't.

```sh
ssh-add                     # load your key for this login, or…
# …add this to ~/.ssh/config to load it the first time you use it:
#   AddKeysToAgent yes
```

How the agent reaches the containers depends on your platform:

| Platform | Where the agent comes from |
|---|---|
| Linux with Docker Engine | `$SSH_AUTH_SOCK` is mounted directly |
| macOS or Linux with Docker Desktop, and OrbStack | Docker's forwarded agent at `/run/host-services/ssh-auth.sock`, which uses your macOS agent and Keychain |
| Windows (WSL2) | `$SSH_AUTH_SOCK` inside WSL. To use the Windows OpenSSH agent or a password manager's agent, bridge it into WSL with a tool like `npiperelay`. |

Some details:

- Your SSH config is included, but two things are overridden. The agent is always Novacore's, so an `IdentityAgent` pointing at a path that only exists on your machine (such as 1Password's) doesn't break it. The macOS-only `UseKeychain` option is ignored.
- If a host entry uses `IdentitiesOnly yes`, ssh only offers keys whose files it can find, and they aren't in the container. Remove that line for hosts you reach from Novacore.
- Sharing the agent turns off SELinux labelling for the PHP containers only. The usual `:z` relabelling would change the labels on your `~/.ssh` files.
- Novacore picks up the agent when the containers start. If your agent's socket path changes, for example after you log in again, run `novacore up` to update it.

## Databases

MariaDB is at `mariadb:3306` from PHP and `127.0.0.1:3306` from your machine, for GUI clients. User `novacore` (password `novacore`) can access every database. Root's password is `root`.

```sh
novacore db list
novacore db create shop
novacore db import shop dump.sql.gz
novacore db export shop               # writes shop-<timestamp>.sql.gz
novacore db shell shop
novacore db drop shop
```

`novacore site info <name>` shows a site's database name, login and host.

### Connecting from Novacore and your machine

The database is `mariadb` inside Novacore, but `127.0.0.1` on your machine. To make a site work in both places, Novacore sets `NOVACORE_DB_HOST=mariadb` in the PHP containers and for every web request. Write your config so it falls back to `127.0.0.1` when that variable isn't set. Then the site and `novacore wp` use the container's database host, and tools on your machine (`wp`, scripts, test runners) connect through the published port.

```php
// wp-config.php
define( 'DB_HOST', getenv( 'NOVACORE_DB_HOST' ) ?: '127.0.0.1' );

// Bedrock: config/application.php
Config::define( 'DB_HOST', env( 'NOVACORE_DB_HOST' ) ?: env( 'DB_HOST' ) ?: '127.0.0.1' );

// Laravel: config/database.php, in the mysql/mariadb connection
'host' => env( 'NOVACORE_DB_HOST', env( 'DB_HOST', '127.0.0.1' ) ),
```

If you've changed `DB_PORT`, use `127.0.0.1:<port>` as the fallback. `novacore site info` prints these lines with your port filled in. Anywhere `NOVACORE_DB_HOST` isn't set, such as a live server, the code just uses the fallback.

To run `wp` on your machine, you need PHP with the `mysqli` extension. Commands like `wp db export` also need the `mysql` or `mariadb` client. Your machine's PHP version may differ from the site's. If a command behaves differently, `novacore wp` runs it with the site's own PHP version.

## Everything else

```sh
novacore status        # containers and sites
novacore logs nginx    # or mariadb, php84, ...
novacore down
novacore help
```

`novacore status --json` prints whether Novacore is running and lists its sites, for use in scripts.

## KDE Plasma widget

In KDE Plasma, Novacore's tray icon is a Plasma 6 widget, `tray/plasmoid/`, in the system tray. Clicking it opens the same panel as the [tray icons](#tray-icons) on macOS and Windows: Novacore's status, your sites, which expand to show what you can do with each, the server's controls, Xdebug and Tools. Dialogs such as **Add Site…** and **Info…**, and the output of the last command, open in the panel. A middle click opens the dashboard.

`novacore tray install` installs the widget and puts it in the system tray, and adds Novacore's icon to your icon theme for it. You can also add **Novacore** to a panel or the desktop from Add Widgets, or install it by hand:

```sh
kpackagetool6 -t Plasma/Applet -i tray/plasmoid   # use -u instead of -i to update it
```

The widget runs `novacore`, and it also looks in `~/.local/bin`. If the CLI is somewhere else, set the full path in the widget's settings. Plasma loads a widget's code when it starts, so after an update, restart it with `systemctl --user restart plasma-plasmashell` or log in again.

## Tray icons

On Linux, macOS and Windows, Novacore can add an icon to the system tray or the menu bar (in KDE Plasma, that's the [Plasma widget](#kde-plasma-widget)). It shows whether Novacore is running, and it starts, stops or restarts it. The colour of the small pill on the globe shows the status: green while running, grey when stopped, yellow while busy and red when something's wrong. The icon also covers most of the CLI:

- **Add Site…** asks for a name, PHP version and document root, and whether to create a database.
- Each site's menu opens the site, its repository on GitHub, GitLab and the like (if it has a git remote), its folder, a terminal there, a shell in its PHP container, or its error log. It also switches the site's PHP version, and removes the site, optionally with its database.
- **Info…** shows a site's paths and database settings, like `novacore site info`, with a button to copy each one.
- **Xdebug** sets the Xdebug mode, and **Tools** opens a database shell, the container logs or the sites folder.

VS Code and Zed appear in a site's menu if you have them. Run this to install the icon (for Windows, inside WSL):

```sh
novacore tray install
novacore tray uninstall
```

It works out which system you're on. Once installed, the icon keeps itself up to date: when its source in the repo changes, for example after a `git pull`, it rebuilds itself and restarts.

Commands you start from the icon, like a PHP switch that builds a new image, run on their own, so they finish even if you quit or reinstall the icon. A notification tells you when one is done, and clicking a failure's notification shows its output.

### Linux

The icon is a Python script, `tray/linux/novacore-tray.py`, using Qt for Python. Install PySide6 (or PyQt6) from your distro first, e.g. `sudo dnf install python3-pyside6`, `sudo apt install python3-pyside6.qtwidgets` or `sudo pacman -S pyside6`. `novacore tray install` adds **Novacore Tray** to your app launcher and to `~/.config/autostart`, so it starts when you log in, and starts it now. It runs straight from the repo, and restarts itself when the script changes. If you quit it, open **Novacore Tray** from your app launcher to start it again.

In KDE Plasma, `tray install` puts the [Plasma widget](#kde-plasma-widget) in the system tray instead, and sets up the Python icon only for other desktops you log in to. If Plasma has no system tray, it falls back to the Python icon. `tray uninstall` removes both.

The icon shows up in XFCE, Cinnamon, LXQt and other desktops with a system tray. GNOME needs the AppIndicator extension, which Ubuntu includes. The menu opens with a left or right click. Terminals open in your desktop's own terminal, or the one in `$TERMINAL`. Notifications use `notify-send`, and clicking one opens the site or a failed command's output. Problems are logged to `~/.local/state/novacore/tray.log`.

### macOS

The icon is a small app, `~/Applications/Novacore Tray.app`. `novacore tray install` compiles it from `tray/macos/NovacoreTray.swift`, which needs the Xcode Command Line Tools (`xcode-select --install`). A LaunchAgent starts it when you log in. If you quit it, open **Novacore Tray** from Spotlight to start it again.

The icon runs the CLI with the `PATH` you had when you installed it, so `docker` needs to be on that `PATH`. If you move Docker, run `novacore tray install` again. Terminals open in Terminal.app. The first time it sends a notification, macOS asks whether to allow them. If you don't allow them, a failed command opens its output instead. Problems are logged to `~/Library/Logs/Novacore/tray.log`.

Click the icon for a panel in the style of Control Center: Novacore's status, your sites (expand one for links to its actions, and its PHP version), Start, Stop and Restart, and Xdebug. Right-click or Control-click it for the same things as a menu.

### Windows

With Novacore in WSL, the icon goes in the taskbar's notification area. `novacore tray install` copies `tray/windows/novacore-tray.ps1`, and `novacore-ui.cs`, the C# for its panel, to `%LOCALAPPDATA%\Novacore` and adds a shortcut to your Startup folder, so the icon starts when you sign in to Windows. The script uses only Windows PowerShell, which comes with Windows, and runs the CLI in your distro through `wsl.exe`. On its first run it builds `NovacoreTray.exe`, a small program that runs the script, so Task Manager and notifications show it as Novacore Tray rather than Windows PowerShell. Windows treats that as a new app, so if the icon disappears into the overflow (^), drag it back onto the taskbar.

Click the icon for a panel in the style of Windows 11's own: Novacore's status, your sites (expand one for links to its actions, and its PHP version), Start, Stop and Restart, and Xdebug. Right-click it for the same things as a menu.

Terminals open in Windows Terminal if you have it. VS Code and Zed appear if they're installed on Windows, and open the site through WSL.

The icon checks the status every 30 seconds, but only while your WSL distro is running, so it doesn't stop WSL from shutting down when it's idle. Opening the menu always checks, and that starts WSL if it isn't running. If the icon itself runs into a problem, it logs it to `%LOCALAPPDATA%\Novacore\tray.log`.

### Adding to the tray icons

All three icons draw the menu that `novacore tray menu` describes in JSON: each item, what it does, and the dialogs to show. To add a menu item or a dialog, you change `tray_menu` in `bin/novacore`, and every icon picks it up. [`tray/PROTOCOL.md`](tray/PROTOCOL.md) describes the JSON. They also share their status icon: `tray/status.svg`, which `tray/build-icons.sh` renders into `tray/status-icons.png` for all three. It also renders the Windows app icon from `tray/novacore.svg`, which the Linux icon uses as it is. Run it after changing either SVG. The macOS app's icons are finished files: `tray/macos/Assets.car`, a Liquid Glass icon that follows your choice of light, dark, clear or tinted icons on macOS 26 and later, and `tray/macos/novacore.icns`, the same globe on a dark tile, for earlier versions.

## How it works

```
bin/novacore                 the CLI
docker-compose.yml         nginx, mariadb, php74 … php85
docker/nginx/              nginx image, main config, certificate script
docker/php/                PHP-FPM image (one Dockerfile, built per version)
docker/mariadb/init/       first-run database setup
sites.conf                 your sites (created on first `site add`)
data/                      generated: vhosts, certificates, dashboard, compose overrides
logs/                      PHP error log per site
tray/                      the tray icons: their protocol, icons and build script
tray/linux/                Linux tray icon
tray/macos/                macOS menu bar icon
tray/windows/              Windows tray icon (for WSL)
tray/plasmoid/             KDE Plasma widget (the tray icon in Plasma)
```

The CLI reads `sites.conf` and generates three things in `data/`: an nginx vhost for each site, a certificate for each site, and a Compose override (`compose.generated.yml`). The override gives nginx a network alias for each domain, and shares your SSH agent with PHP. nginx reaches PHP through Docker's DNS when a request comes in, so a vhost that points at a PHP version that isn't running gives a 502 instead of stopping nginx from starting.

libcurl, and so PHP's curl extension, always resolves `*.localhost` to 127.0.0.1 without asking DNS. To make that work, each PHP container relays its own loopback ports 80 and 443 to nginx. Other lookups reach nginx through the network aliases.

Never edit anything in `data/` by hand. Deleting it is safe, and the next `novacore up` regenerates it, but you'll get a new CA and need to run `novacore trust` again.

## Troubleshooting

- **Browser still warns about the certificate.** Run `novacore trust` and restart the browser. Firefox on some distros has its own certificate store. If it still complains, import `data/certs/ca.crt` under Settings → Certificates → Authorities.
- **Browser on Windows warns about the certificate (WSL2).** `novacore trust` adds the CA to your Windows user's certificate store too, and Windows asks you to confirm. Click **Yes**, then fully restart Chrome or Edge. Firefox on Windows uses that store when `security.enterprise_roots.enabled` is on in `about:config`. If you regenerate `data/`, remove the old "Novacore Local CA" in `certmgr.msc` under Trusted Root Certification Authorities.
- **Xdebug doesn't connect.** Check that your IDE is listening on 9003. Then check that your firewall allows connections from the Docker bridge network. On Fedora with firewalld, Docker's interfaces are normally in the `docker` zone, which accepts them.
- **SSH from PHP says "Permission denied (publickey)".** Your agent probably has no keys. Run `ssh-add -l` on your machine. If it lists nothing, run `ssh-add`. To see exactly what's happening, run `novacore exec <site> ssh -v user@host` from the site.
- **SSH from PHP says "Host key verification failed".** The container trusts the hosts in your `~/.ssh/known_hosts`. Connect to the server once from your own terminal to add it there.
- **A port is already in use.** Change `HTTP_PORT`, `HTTPS_PORT` or `DB_PORT` in `.env`, then run `novacore up`.
- **A different TLD.** `NOVACORE_TLD=test` works, but you need to resolve `*.test` yourself, through dnsmasq or your hosts file. `localhost` needs nothing.
