# Verified results

Tested **2026-11-02**. Device identifiers, hostnames and network details are redacted;
nothing else is altered.

## Environment

| Role | Hardware | Software |
|---|---|---|
| Gadget host | Raspberry Pi 2 Model B rev 1.1 — BCM2836, 4× Cortex-A7, **armv7 (32-bit)**, 1 GB RAM, **no Bluetooth, no Wi-Fi**, wired Ethernet | Raspberry Pi OS 13 (Trixie) armhf, kernel 6.x, Python 3.13.5 |
| Pairing host | x86_64 laptop, BlueZ 5.87, controller supporting `Roles: peripheral` and 16 advertising instances | Fedora Linux 44, `/usr/bin/python3` 3.14.8 |

## Installed

| Component | Version / location |
|---|---|
| `musegadget` | 0.1.0, `/opt/musegadget/venv` |
| `websockets` | 17.1 (the only PyPI dependency in `requirements.lock`) |
| `uv` | 0.9.9 (`uv-armv7-unknown-linux-gnueabihf`) |
| systemd unit | `musegadget.service`, enabled, `MUSEGADGET_RUN_AS=<user>` |
| state | `/var/lib/musegadget`, `0700`, files `0600 root:root` |

`cryptography` (43.0.0), `dbus` (1.4.0) and `gi` (3.50.0) came from the distribution via
the installer's `--system-site-packages` venv — no Rust build on the Pi.

## What was verified

1. **Install on armv7 succeeds.** The installer's Debian arch gate accepts `armhf`; the
   only PyPI package, `websockets`, builds or resolves for Python 3.13 on armv7.
2. **A host with no radio can hold the service.** `musegadget doctor` on the gadget host:
   Pairing `OK`, SDK token `OK`, Service `OK`, TCP 443 `OK`, Bluetooth `WARN`
   (`bluetoothctl timed out`). `/sys/class/bluetooth` is empty.
3. **The identity is portable.** `identity.json` + `sdk_token` were copied to the pairing
   host *before* pairing, so the BLE handshake registered the gadget host's existing
   `homelink-abc123` rather than creating a second device.
4. **The server accepts the transplanted pairing.** After the state was moved and the
   service restarted, the gadget host connected and registered:

```
VM fetch: 1 VMs
link_client: Noise session established
link_client: sent link.register as homelink-abc123
link_client: registered with the Muse
```

5. **Commands execute on the gadget host.** Asked through the Muse app to run `hostname`;
   the reply was the Pi's hostname, exit code 0, no errors.

## What was not verified

- Long-run stability (the test ran for hours, not weeks).
- Re-pairing without a Bluetooth host: not possible by design — the gadget host has no
  radio, so any re-pair needs the pairing host again.
- Non-Debian gadget hosts. The installer supports Arch and Fedora; only the Debian path
  was exercised here.
- Any Muse feature beyond `hostname` and the initial `device.health` query.

## Notes on method

- Transplants were performed with `scripts/transplant-muse-state.sh` in this repository,
  which installs the files as `0600 root:root` into a `0700` directory, streams the archive
  (nothing written to local disk), and refuses to overwrite a different identity.
- The pairing host's `musegadget` service was disabled before the transplant so that only
  one host held the identity.
- No credential appears in this document. The token is read server-side from
  `/var/lib/musegadget/sdk_token` and is never printed or passed on a command line.
