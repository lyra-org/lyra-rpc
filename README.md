# Lyra Discord Rich Presence

A Discord Rich Presence client implementation for [Lyra](https://git.lyra.pub/lyra/lyra), a work-in-progress music server. Shows the currently playing track, album, artist, and cover art.

## Usage

Requires Zig 0.16.0.

Run from source:

```sh
zig build run
```

Build an optimized executable:

```sh
zig build -Doptimize=ReleaseSmall
./zig-out/bin/lyra_rpc
```

Optionally create a `config.json` in the working directory:

```json
{
  "base_url": "http://localhost:4746",
  "auth_token": "",
  "poll_interval_sec": 5,
  "images": {
    "uploader": "none",
    "imgur_client_id": ""
  },
  "presence": {
    "title": "{track.title}",
    "subtitle": "{release.title} ({release.year})",
    "image_text": "{artists}",
    "list_separator": ", "
  }
}
```

`images.uploader` may be `none`, `litterbox`, or `imgur`. Set `images.imgur_client_id` when using `imgur`.

### Presence text

`presence` controls the text shown in Discord:

| Key | Discord location | Default |
| --- | --- | --- |
| `title` | First line, bolded | `{track.title}` |
| `subtitle` | Second line | `{release.title} ({release.year})` |
| `image_text` | Third line and large image hover text | `{artists}` |
| `list_separator` | Joins list values | `, ` |

Templates can mix hardcoded text with placeholders. For example, `"{release.title} ({release.year})"` renders as `Album (2024)`.

Supported placeholders:

| Placeholder | Value |
| --- | --- |
| `{track.title}` | Track title |
| `{track.id}` | Track ID |
| `{track.year}` | Track year |
| `{track.disc}` | Disc number |
| `{track.number}` | Track number |
| `{track.duration}` | Track duration, formatted like `3:42` |
| `{artists}` | Track artists, joined with `list_separator` |
| `{release.title}` | Release title |
| `{release.date}` | Full release date from Lyra |
| `{release.year}` | Release year |
| `{release.artists}` | Release artists, joined with `list_separator` |
| `{release.genres}` | Release genres, joined with `list_separator` |

Empty parenthesized groups are removed after rendering. With the default `subtitle`, a release without a year shows as `Album` instead of `Album ()`.

## License

This project is licensed under the [Lyra Public License, Version 1.0](LICENSE) (LPL-1.0). While this license is custom, it is based on the [MPL-2.0](https://opensource.org/license/MPL-2.0).

The main differences between the two are that the `LPL-1.0` includes an additional provision regarding Remote Network Interaction (inspired by the [AGPL-3.0](https://opensource.org/license/agpl-3-0)) and limits your secondary license options to only the `AGPL-3.0-or-later`.

You are free to use this project as you see fit, so long as you comply with the license's terms.
