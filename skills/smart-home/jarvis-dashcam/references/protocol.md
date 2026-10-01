# Viidure-family dashcam protocol (Peztio / Affver and friends)

Notes from reading the Peztio Android app (`com.vidure.peztio` v1.0.133.260820, decompiled with
JADX) for interoperability with Jarvis. Written in our own words; class names point at the
decompiled source so a claim can be re-checked. Anything marked **(live)** still needs a check
against the real camera with `scripts/dashcam_camera.py probe`.

## 1. The platform

Viidure builds one app for many dashcam brands. The camera runs its own Wi‑Fi access point and
an HTTP server; the phone joins that network. About ten camera SoC families are supported, and
the app tells them apart by the camera's address and a family-specific "detector" request
(`N4/m.java`):

| Family | Camera address | Detector request | Command prefix | Live view |
|---|---|---|---|---|
| Viidure / Eeasy (`soc` = `eeasytech`, `lombotech`, `sigmastar`, …) | `192.168.169.1` | `GET /app/getdeviceattr` | `/app/` | `rtsp://<ip>:554…` (from `getmediainfo`) |
| Novatek | `192.168.1.254` | `GET /?custom=1&cmd=3029` | `/?custom=1&cmd=` | `rtsp://<ip>/xxxx.mov` |
| MStar / SigmaStar (AIT CGI) | `192.72.1.1` (or `192.168.1.1`) | — | `/cgi-bin/Config.cgi?action=` | `rtsp://<ip>/liveRTSP/av4` |
| HiSilicon | `192.168.0.1` | `GET /cgi-bin/hisnet/getwifi.cgi?` | `/cgi-bin/hisnet/` | — |
| Allwinner | `192.168.10.1:8082` | `GET /api/getdeviceinfo/?custom=1&cmd=2001` | `/api/` | — |
| Huiying | `192.168.201.1` | `GET /?cmd=302&param=network_ap` | `/?cmd=` | `/live/ch00_` |
| JieLi | `192.168.1.1` | TCP control socket 3333, HTTP 8080 | binary | — |
| iCatch, GeneralPlus, GoPlus | various | vendor SDKs | binary | — |

Default Novatek Wi‑Fi password: `1234567890`. The Peztio-branded cameras are handled by the app's
Viidure router (`E5/c.java` has a Peztio-specific firmware-upload path), so the Affver A4 is
expected to be a Viidure/Eeasy camera **(live)**.

Jarvis implements **Viidure** fully, **Novatek** for listing/download/control, and only
*detects* the other families (the probe reports them as "not supported yet").

## 2. One operation table, four dialects

`com/vidure/app/core/custom/api/AbsApi.java` is an enum: each operation carries its command for
Viidure, Novatek, MStar and HiSilicon. The useful ones:

| Operation | Viidure (`/app/` + …) | Novatek (`/?custom=1&cmd=` + …) |
|---|---|---|
| Product info | `getproductinfo` | `9090` |
| Device attributes (fingerprint) | `getdeviceattr` | `3017` (detector `3029`) |
| Capabilities | `capability` | `9143` |
| Live/stream info | `getmediainfo` | `2019` |
| Battery | `getbatteryinfo` | `3019` |
| SD card status | `getsdinfo` | `3024` |
| All setting options | `getparamitems?param=all` | `3031&str=all` |
| All setting values | `getparamvalue?param=all` | `3014` |
| Set a setting | `setparamvalue?param=<name>&value=<v>` | per-setting cmd + `&par=<v>` |
| Set date/time | `setsystime?date=<yyyyMMddHHmmss>` | `3005&str=<yyyy-MM-dd>` + `3006&str=<HH:mm:ss>` |
| Set time zone | `settimezone?timezone=<hours>` | `9146&par=` |
| Recording on/off | `setparamvalue?param=rec&value=1|0` | `2001&par=1|0` |
| Recording status | `getparamvalue?param=rec` | `2016` |
| Lock current clip | `lockvideo` | `9133&par=1` |
| Take photo | `snapshot` | `1001` |
| File list | `getfilelist?folder=<f>&start=<i>&end=<j>` | `3015` |
| Delete file | `deletefile?file=<path>` | `4003&str=<path>` |
| SD format | `sdformat?index=<n>` | `3010&par=1` |
| Wi‑Fi name / password | `setwifi?wifissid=` / `setwifi?wifipwd=` | `3003&str=` / `3004&str=` |
| Reboot Wi‑Fi | `wifireboot` | `3018` |
| Playback mode | `playback?param=enter|exit` | — |
| Settings mode | `setting?param=enter|exit` | — |
| Thumbnail | `getthumbnail?file=<path>` | `<path>?custom=1&cmd=4001` |

Parameter formats come from the Viidure sender (`F5/c.java`, `F5/b.java`) and `E5/a.java`.
Setting names seen in the app: `rec_resolution`, `rec_split_duration`, `encodec`, `wdr`, `ev`,
`osd`, `video_mirror`, `video_flip`, `speaker`, `voice_control`, `mic`, `key_tone`,
`boot_sound`, `speed_unit`, `adas`, `gsr_sensitivity`, `auto_poweroff`, `light_fre`,
`low_fps_record`, `parking_monitor`, `parking_mode`, `park_record_time`, `timelapse_rate`,
`park_gsr_sensitivity`, `low_power_protect`, `screen_standby`, `rear_mirror`, `language`.

## 3. Viidure replies

Every `/app/` reply is JSON `{"result": <int>, "info": <payload>}` (`libs/transport/model/j.java`,
key name from `W/k.java`). `result` 0 = success and `info` is the payload (object or array); any
other `result` means `info` is an error string.

- **`getdeviceattr`** (`G5/i.java#f`): `uuid`, `softver`, `hwver`, `otaver`, `sdkver`, `bssid`,
  `camnum` (number of lenses), `curcamid`, `wifireboot`, `tracker`, `imei`, `iccid`.
  Camera id = `uuid`, else `imei`, else `bssid`.
- **`getproductinfo`** (`G5/i.java#k`): `model`, `company`, `sp` (brand, e.g. `PEZTIO`), `soc`
  (e.g. `eeasytech`), `ak`, `time`, `token`.
- **`getmediainfo`** (`G5/i.java#j`): `rtsp` (single URL) or `rtsps` (array, one per lens),
  `transport`, `port` (a TCP "mail" socket the camera pushes status on), `page` (1 = file list is
  paged), `rectime`, `cgiswitch`, `autorecord` (1 = recording resumes on connect).
- **`getsdinfo`** (`G5/i.java#l`): `status` (0 = card OK), `total` and `free` in **MB**.
- **`getbatteryinfo`**: `capacity`, `charge`.
- **`getparamvalue?param=rec`**: `{"value": 1|0}` style; `getparamvalue?param=all` → array of
  `{"name", "value"}` (`G5/k.java#e`).
- **`getparamitems?param=all`** (`G5/k.java#f`): array of
  `{"name", "index": [codes…], "items": [labels…]}` or `{"name", "range": "a-b", "step", "unit"}`.
  To change a setting send `setparamvalue?param=<name>&value=<code>` (a code from `index`).
- **`getfilelist`** (`G5/h.java#m`): `info` is an array of folders:
  `{"folder": "loop|park|event|emr|race", "count": N, "files": [ … ]}`; each file
  `{"name": "<absolute camera path>", "createtimestr": "yyyyMMddHHmmss"` *or*
  `"createtime": <unix seconds>`, `"size": <KB>`, `"type": 2` (video; anything else = photo),
  `"duration": <s>`, optional `"GPSPATH"`, `"GYROPATH"`}.
  - Folder → kind: `loop` normal, `park` parking, `event` event (G‑sensor), `emr` emergency/locked,
    `race` race. `emr` clips are flagged locked.
  - Paging: request `start`/`end` (inclusive) in pages of 100 until a page comes back empty
    (`E5/c.java#a`). Cameras without paging return everything for any range.
  - Time: `createtimestr` is camera-local time. For `eeasytech`/`lombotech` cameras `createtime`
    is local wall-clock seconds, so the app subtracts the phone's UTC offset.
  - Front/rear: decided from the path/name (`G5/h.java#j`); names end `_F`/`_R` or live under
    front/rear folders **(live)**.
- **Download:** `GET http://<ip><name>`, so the file's absolute path goes straight on the host.
  HTTP range requests are supported because the app's GPS reader depends on them.
- **Thumbnail:** `GET http://<ip>/app/getthumbnail?file=<name>` → JPEG (`E5/g.java#b`).

### Session rules

- The app's album screen sends `playback?param=enter` on open and `playback?param=exit` on close
  (`CameraAlbumActivity`). The settings screen does the same with `setting?param=`, and
  explicitly **stops recording** first (`E5/c.java#intoSettingUi`).
- Whether `getfilelist` works without playback mode, and whether playback mode pauses
  recording, varies by firmware **(live)**. Jarvis therefore never enters playback/settings
  mode while the car is moving, always exits afterwards, and re-reads the recording status,
  restarting recording if it was on before.
- Requests are serialised with ~100 ms spacing (`C4/c.java#d`); a `result` of 8198 means
  "session error" (reconnect).

## 4. Novatek replies

XML. Command replies look like `<Function><Cmd>N</Cmd><Status>0</Status>…</Function>`
(`p335z5/h.java` tag constants `Cmd`, `Status`, `Value`, `String`). The file list (`3015`,
`C5/a.java`) is `<LIST><ALLFile><File>…</File></ALLFile></LIST>` with per-file `NAME`,
`FPATH` (`A:\CARDV\MOVIE\…` → drop the drive letter and swap `\` for `/`), `SIZE` (bytes),
`ATTR` (hex; bit 0 = read-only = locked), `TIME` (`yyyy/MM/dd HH:mm:ss`), optional
`TIME_START`/`TIME_STOP`, `THUMBNAIL`, `GPSPATH`, `GYROPATH`. Paths: videos `/CARDV/MOVIE/`, photos
`/CARDV/PHOTO/`; locked clips usually under `RO`/`EMR` folders. Download = `http://<ip><path>`;
thumbnail = `http://<ip><path>?custom=1&cmd=4001`. Novatek embeds GPS in MP4 `gps ` atoms (see
`NvtSocGpsParser`), which needs the file's `moov` box. Jarvis reads Novatek GPS only from a
separate `GPSPATH` file when one is listed.

## 5. GPS inside Viidure video files

`album/handler/parser/ViiSocGpsParser.java` + `GpsDataPhraseHandler.java#phaserHttpVideoFile`:

1. HEAD/size the file, then range-read the **last 8 bytes**: ASCII marker (`&&&&`, `####` or
   `****`) + a big-endian `uint32` block size (`B6/e.java#h`). A valid size is 1…1 023 999.
2. Range-read the last `size` bytes, the GPS block:
   - bytes 0–3: the same size (big-endian)
   - bytes 4–7: `free`
   - bytes 8–9: `FH` for the FH variant
3. Records:
   - **Normal:** from offset 28, every **132 bytes**: a 4-byte big-endian integer, then an ASCII
     line ending in a zero byte. Read while `offset ≤ len − 132`.
   - **FH:** from offset 92 (28 + 64), every 132 bytes, the line starts at the record (no
     integer). Read while `offset ≤ len − 136`.
   - **`****` (XGC):** like normal, but the coordinates are scrambled and speed is in knots
     (`handleXGCDataAndWriteFile`). Unscrambling, with `lat`/`lon` the numbers after the `N:`/`E:`
     prefixes:
     - `lat10 = floor(lat/10)*10` and `lon10 = floor(lon/10)*10`
     - `real_lat = (lon − lon10)/0.8668 + lat10`
     - `real_lon = lon10 + (lat − lat10)/0.8668`
     - `speed_kmh = knots × 1.852`
4. A line is valid if it starts with `20` and character 20 is `N` or `S` (`ParserUtils`).

Line layout (`p076f6/b.java#n`), whitespace-separated:

```
yyyy/MM/dd HH:mm:ss N:<lat> E:<lon> <speed km/h> …  (10-field form: … X:<gx> Y:<gy> Z:<gz> A:<heading> H:<alt>)
                                                    (19-field form: [6..8] X/Y/Z, [9] heading, [11] altitude, [13] MS:<1/10 s> …)
```

- `-` = unsupported, `NA` = invalid. A `-` sign before the number means S/W.
- Coordinates are NMEA `ddmm.mmmm` / `dddmm.mmmm`, or plain decimal degrees when the integer
  part of the latitude has fewer than 3 digits (`p102h6/f.java#e`).
- Speed is km/h in the normal and FH forms.
- The app treats a line time as wall-clock time. Jarvis aligns fixes to the clip:
  1. Try the line time as UTC, then as camera-local time.
  2. Keep whichever puts the fixes inside the clip's [start − 60 s, end + 60 s].

Other sources: a per-file `GPSPATH` text file, and day logs under `/SD/GPS/` (`DayVTrack`) or
`/GPSdata/` (`N4/m.java`). The same line format is used everywhere.

## 6. Status push socket (not used by Jarvis)

`getmediainfo.port` is a TCP socket on which the camera pushes JSON messages
(`{"msgid": "rec|gps|adas_result|…", "info": {…}}`, `E5/e.java`): recording state, SD card,
live GPS, G-sensor recording, lens changes, Wi‑Fi disconnect. Jarvis polls over HTTP instead.

## 7. Live view (documented, not built)

`getmediainfo.rtsp`/`rtsps` give RTSP URLs (port 554 on Viidure). AVPlayer cannot play RTSP, so
this needs VLCKit or ffmpeg in the app.
