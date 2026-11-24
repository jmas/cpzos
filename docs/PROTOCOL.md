# Protocol

All runtime protocols are line-oriented `key=value`. Values are percent-encoded
when they may contain spaces or protocol characters. There is no JSON parser.

## App manifests

`/usr/share/cpz/apps/<id>.app` and `~/.local/share/cpz/apps/<id>.app`:

```ini
id=terminal
name=Terminal
desc=Shell, tmux, ssh
exec=/bin/bash
exec=-l
type=tui
icon=terminal
category=System
order=100
single=0
hidden=0
provider=0
```

`exec` is repeated; each line is one argv element. `#` starts a comment.
`hidden=1` keeps an entry out of the launcher. `provider=1` means the app also
has a `--provider` mode (shipped as a systemd unit).

## Provider → shell

Socket `/run/cpz/ui.sock`. One line per message. The provider keeps the
connection open; closing it removes all of its widgets.

```text
op=hello&app=battery
op=clear&app=battery
op=widget&app=battery&id=battery&kind=battery&level=87&charging=0&order=100&priority=90
op=widget&app=clock&id=clock&kind=text&text=12%3A30&order=30&priority=40
op=notify&app=battery&level=1&text=Battery%2020%25
op=bye&app=battery
```

Kinds currently rendered by the panel: `battery` and `text`. Unknown kinds are
stored in the state file but not drawn.

## State file

`cpz-shell` writes `/run/cpz/ui.state` atomically after every change:

```text
# cpz ui state
app id=terminal name=Terminal desc=Shell%2C%20tmux%2C%20ssh type=tui icon=terminal category=System order=100 single=0 exec=/bin/bash exec=-l
status app=battery id=battery kind=battery level=87 charging=0 order=100 priority=90
notify level=1 text=Battery%2020%25
end
```

`cpz-launcher` reads until `end`; it does not use a socket and does not query
the shell. `cpz-shell --dump` writes the file and prints it.

## Session control

Socket `/run/cpz/session.sock`, plain commands:

```text
status
output auto|panel|hdmi
restart-term
gui /absolute/command
poweroff
reboot
```

`cpz-ctl` is the client.

## Percent encoding

`%20` space, `%25` `%`, `%26` `&`, `%3D` `=`, `%2F` `/`, `%0A` newline.
`cpz-query.h` provides `kv_get`, `url_encode` and `url_decode`.
