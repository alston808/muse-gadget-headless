# Run a Muse Gadget on a host with no Bluetooth

Turn a headless Linux box — a Raspberry Pi 2, a server, a container host — into a Meta
Muse gadget **without buying a Bluetooth adapter**.

Pair once on a machine that has Bluetooth LE, copy three root-only files to the gadget
host, and the daemon runs entirely over the network afterwards.

**Verified on real hardware:** Raspberry Pi 2 Model B rev 1.1 (armv7, no radio),
Raspberry Pi OS 32-bit (Trixie), `muse-gadget-sdk` 0.1.0 — see [RESULTS.md](RESULTS.md).

Upstream discussion: [facebookincubator/muse-gadget-sdk#301](https://github.com/facebookincubator/muse-gadget-sdk/issues/301).

> Unofficial. Not affiliated with, endorsed by, or supported by Meta. The SDK is
> Apache-2.0; everything here is the author's own work, MIT-licensed.

---

## Why this works

Bluetooth is needed **once, for about ten minutes, while pairing**. It is not used to run
the device.

From the SDK's `linux/README.md`:

> Bluetooth problems are warnings because Bluetooth is only needed for pairing.

BLE carries only the provisioning handshake: the phone app connects to a GATT peripheral
advertising `MuseGadgetXXXXXX`, performs the community pairing handshake, and hands over
the device token, `api_url` and `noise_host`. After that, all traffic is
`wss://<noise_host>/v1/noise`, a Noise XX session, then `link.register`.

Consequences:

- `musegadget doctor` reports Bluetooth as `[WARN]`, never `[FAIL]`.
- A host with no radio can install the SDK, hold the pairing, and run the service.
- The pairing is bound to the device identity (`hatch-link:<mac>` in `identity.json`),
  not to the machine that performed the BLE handshake. This is the load-bearing fact, and
  it is confirmed end to end in [RESULTS.md](RESULTS.md).

So: pair elsewhere, move the state, run the gadget anywhere.

---

## Requirements

**Gadget host** — the machine that will be the gadget:

- Linux with systemd, Debian/Ubuntu/Arch/Fedora family, `armhf`, `arm64` or `amd64`.
- Ubuntu 22.04+ or Debian 11+ (Raspberry Pi OS Bullseye or later).
- Python ≥ 3.9 with `python3-dbus`, `python3-gi`, `python3-cryptography` from the distro.
- Wired or wireless network access outbound on 443.
- **No Bluetooth adapter required.**

**Pairing host** — any machine with working Bluetooth LE, used once:

- A BlueZ controller that supports the peripheral role and advertising. Check with
  `bluetoothctl show`: look for `Roles: peripheral` and an `Advertising Features` block.
- On the same network as your phone, and online (the app's pairing flow asks you to "pick
  the network shown"; the pairing host is already connected).

**Accounts and tokens:**

- A Muse account with **Developer mode** enabled: Settings → Devices → Developer mode.
- An SDK token from <https://gadgets.muse.ai/settings/sdk-tokens>. Format:
  `mgst_` + 43 base64url characters, last character in `AEIMQUYcgkosw048`.
- Read the Gadget SDK Terms first. Community pairing has no manufacturer verification and
  cannot prevent an active man-in-the-middle. Pair on a network you trust.

---

## How it works

```
Muse phone app ──BLE, once, ~10 min──> pairing host (hci0)
                                            │
                                            │ writes /var/lib/musegadget/
                                            │   identity.json
                                            │   pairing.json
                                            │   sdk_token
                                            ▼
                              transplant over SSH (this repo's script)
                                            │
                                            ▼
                                  gadget host (no radio)
                                            │  wss://<noise_host>/v1/noise + Noise XX
                                            ▼
                                     Muse cloud ◄── phone app
```

**One identity, one live session.** Do not leave the daemon running on both hosts: they
will fight over the same `link-control` connection.

---

## Step 1 — install on the gadget host, without pairing

The first install creates the device identity. Doing it first is what lets the pairing
host pair *this* device instead of inventing a new one.

```sh
git clone https://github.com/facebookincubator/muse-gadget-sdk
cd muse-gadget-sdk/linux
less install.sh                     # it edits system Bluetooth configuration
bash install.sh --from . --sdk-token mgst_... --no-pair --yes
```

`--no-pair` is required: without it the installer tries to open advertising on a machine
that has no controller.

You will see:

```
warning: no Bluetooth adapter found. You can install, but pairing with the Muse app needs Bluetooth LE.
```

That is expected — it is the reason this repository exists.

Confirm the identity exists:

```sh
sudo musegadget info
# node id:   homelink-abc123
# BLE name:  MuseGadgetABC123
# paired:    no
```

Note that node id and BLE name. Everything downstream uses them.

If the installer stops while building `websockets` (no `armv7` wheel on PyPI):

```sh
sudo apt install -y build-essential python3-dev
```

The venv is created with `--python /usr/bin/python3 --system-site-packages` on purpose, so
`cryptography`, `dbus` and `gi` come from the distro instead of compiling Rust on a slow
board.

---

## Step 2 — seed the pairing host with that identity

On the pairing host:

```sh
sudo install -d -m 0700 /var/lib/musegadget
ssh pi@muse.local 'sudo tar -C /var/lib/musegadget -cf - identity.json sdk_token' \
  | sudo tar -C /var/lib/musegadget -xf -
sudo ls -l /var/lib/musegadget          # identity.json + sdk_token, both -rw------- root
```

Adjust `pi@muse.local` to your gadget host. Then install the SDK on the pairing host; it
will reuse the seeded identity and open the pairing window itself:

```sh
git clone https://github.com/facebookincubator/muse-gadget-sdk
cd muse-gadget-sdk/linux
bash install.sh --from . --yes
```

`--yes` is safe here: the token is already in place, so it is not prompted for.

### Pair

Within the ten-minute window:

1. Muse app → Settings → Devices → **Add Device**.
2. Pick `MuseGadgetABC123` (the name your gadget host reported).
3. Accept the community-device warning.
4. When asked for Wi-Fi, pick the network shown; no password, the pairing host is online.

If the window closes, reopen it with `sudo musegadget pair`.

Confirm, then stand the pairing host down so only one host is ever live:

```sh
sudo musegadget info                    # paired: yes
sudo musegadget doctor
sudo systemctl disable --now musegadget
```

### What the installer changes on the pairing host

| Path | Change | Why |
|---|---|---|
| `/etc/bluetooth/main.conf` | `[GATT] ExchangeMTU = 256` | The Android app writes `MTU - 3` bytes and fails above 512. Original kept as `main.conf.pre-musegadget`. |
| `/etc/systemd/system/bluetooth.service.d/zz-musegadget.conf` | adds `--noplugin=battery` | iPhones answer battery reads only over a bonded link; BlueZ would then ask to bond, which gadgets refuse. |

`bash install.sh --uninstall` removes the drop-in. The `main.conf` edit is left in place,
with the backup alongside.

---

## Step 3 — transplant the pairing to the gadget host

```sh
sudo bash scripts/transplant-muse-state.sh --host pi@muse.local --dry-run   # preview
sudo bash scripts/transplant-muse-state.sh --host pi@muse.local --restart
```

(Run it through `bash` unless you have made the file executable yourself.)

The script:

- needs root locally (the files are `0600 root`) and `sudo` on the target;
- validates the `mgst_` token format and refuses a truncated or edited file;
- hashes `identity.json` and refuses to overwrite a **different** identity on the target
  (exit 3), so it is safe to re-run;
- installs the three files as `0600 root:root` in a `0700` directory;
- streams the archive with `tar --numeric-owner`, so no secret touches local disk and no
  archive is left behind; the remote staging directory is removed on exit;
- never prints the token;
- under `sudo`, re-runs `ssh` as `SUDO_USER`, because a root ssh would look in `/root/.ssh`
  and find none of your keys.

Expected tail:

```
installed:
  600 root:root /var/lib/musegadget/identity.json
  600 root:root /var/lib/musegadget/pairing.json
  600 root:root /var/lib/musegadget/sdk_token
```

If the target already holds a different identity, the script stops and prints the exact
`rm -rf` to use **only** if you mean to replace that device.

Nothing to copy by hand — but if you prefer, the three files are the whole state.

---

## Step 4 — verify

```sh
sudo systemctl status musegadget
sudo journalctl -u musegadget -f
sudo musegadget doctor
```

Success looks like:

- service `active (running)`, `NRestarts=0`;
- in the journal, a Noise session and a registration — with no Bluetooth activity:

```
VM fetch: 1 VMs
link_client: Noise session established
link_client: sent link.register as homelink-abc123
link_client: registered with the Muse
```

- `doctor` reports Pairing, SDK token, Service and TCP 443 as `OK`, Bluetooth as `WARN`.

Then prove it from the app, which is the only test that matters:

> Run `hostname` on my device.

It must return the gadget host's name — not the pairing host's.

---

## Troubleshooting

| Symptom | Meaning | Action |
|---|---|---|
| `no Bluetooth adapter found` during install | Expected on the gadget host | Ignore |
| `Already paired; the service will reconnect` | `pairing.json` present | Expected after transplant |
| Journal: `401`/`403` on `/v1/noise`, or `link.register` rejected | Tokens not accepted | Re-pair, or read the fallbacks below |
| Registered, but Muse never invokes commands | Account-side gating | Check `musegadget info`; retry from a new chat; watch for `invoke` lines in the journal |
| `musegadget pair` fails immediately on the gadget host | No controller present | Expected — pair elsewhere |
| Muse app never lists the device | Advertising window closed, or MTU not raised | `sudo musegadget pair`; check `ExchangeMTU = 256`; phone Bluetooth on |
| Transplant: `Permission denied (publickey)` | ssh ran as root under `sudo` | Fixed in the script; otherwise `MUSE_SSH_OPTS="-i /home/USER/.ssh/id_ed25519 -o UserKnownHostsFile=/home/USER/.ssh/known_hosts"` |
| Muse shows the pairing host's data | Both daemons running | `sudo systemctl disable --now musegadget` on the pairing host |
| `websockets` build fails | No `armv7` wheel | `sudo apt install build-essential python3-dev` |
| Installer stops at `Installing uv` | uv download or arch | uv 0.9.9 ships `armv7-unknown-linux-gnueabihf`; install it into `/opt/musegadget/bin` and rerun |

### If the server rejects a transplanted identity

Not observed — the transplant registered cleanly in testing — but the two real fallbacks
are:

1. **USB BLE dongle** (~$10, RTL8761BU-based), then `sudo musegadget pair --force` on the
   gadget host. Power the adapter outside the SDK first if BlueZ refuses
   (`bluetoothctl power on`, `rfkill unblock bluetooth`).
2. **Leave the daemon on the pairing host** and give Muse an `ssh pi@...` command, so it
   drives the other machine in one hop.

---

## Security notes

- `/var/lib/musegadget` holds live credentials: the device identity, the pairing tokens,
  and your SDK token. `0600` inside `0700`, root-owned. Do not back it up to shared
  storage, do not commit it, do not paste it into a chat.
- Muse gets a shell as the account you installed with (`MUSEGADGET_RUN_AS`). If that
  account has `sudo`, so does Muse. For a narrower blast radius, create a non-sudo user and
  pass `--run-as muse`.
- Community pairing cannot detect an active man-in-the-middle. Pair somewhere you trust.
- Unpairing, revoking the token, or removing the device in the app invalidates the state.
  Recovery requires a Bluetooth host again — the gadget host cannot re-pair itself.
- This recipe deliberately does not include any secret. If you fork it, keep it that way.

---

## Rollback

On the gadget host:

```sh
cd muse-gadget-sdk/linux
sudo bash install.sh --uninstall --purge      # --purge also removes the identity
```

Then remove the device in the Muse app.

On the pairing host:

```sh
sudo bash install.sh --uninstall              # keeps /var/lib/musegadget
```

---

## Why not an ESP32 or a Flipper?

Both come up whenever someone looks at this problem.

- **ESP32-S2 (Flipper Zero WiFi Dev Board):** no Bluetooth radio of any kind, so it cannot
  complete the mandatory BLE pairing. It also has 4 MB of flash against the SDK's
  8 MB/8 MB baseline, and `esp32/devices/` has no S2 overlay.
- **Flipper Zero as a BLE bridge:** possible but a firmware project, not a config change.
  A FAP cannot register a custom GATT service; profiles are compile-time templates for the
  STM32WB radio core. You would add a profile under `targets/f7/ble_glue/services/`,
  rebuild with `./fbt`, and relay GATT payloads over USART1 to the gadget host, replacing
  the BlueZ D-Bus server with a UART transport. Fragile across firmware versions, and it
  occupies the Flipper's radio while bridging.
- **A Wi-Fi-only pairing flow:** the phone app only speaks the BLE provisioning handshake.
  Upstream issues ask for an alternative; none exists.

The transplant approach needs neither.

---

## Files

```
README.md                             this file
QUICKSTART.md                         the commands, condensed
RESULTS.md                            verified environment and evidence
scripts/transplant-muse-state.sh      the state mover (MIT)
LICENSE                               MIT
```

## Credits

Built against <https://github.com/facebookincubator/muse-gadget-sdk> (Apache-2.0). Behaviour
described here was read from `linux/README.md`, `linux/install.sh`,
`src/musegadget/config.py`, `identity.py`, `pair.py`, `ble_server.py` and
`src/musegadget/data/requirements.lock` at `main`, November 2026. Quoted lines remain the
property of Meta Platforms, Inc. and affiliates.

MIT licensed — see [LICENSE](LICENSE).
