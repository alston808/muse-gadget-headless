# Quickstart

The whole procedure, without the explanations. Replace `pi@muse.local` with your gadget
host and `mgst_...` with your token. See [README.md](README.md) for why each step exists.

### On the gadget host (no Bluetooth needed)

```sh
sudo apt update && sudo apt install -y git build-essential python3-dev

git clone https://github.com/facebookincubator/muse-gadget-sdk
cd muse-gadget-sdk/linux
bash install.sh --from . --sdk-token mgst_... --no-pair --yes

sudo musegadget info
```

Write down the `node id` / `BLE name`. `paired: no` is correct at this point.

### On the pairing host (Bluetooth LE)

```sh
# 1. take the gadget host's identity so you pair that device, not a new one
sudo install -d -m 0700 /var/lib/musegadget
ssh pi@muse.local 'sudo tar -C /var/lib/musegadget -cf - identity.json sdk_token' \
  | sudo tar -C /var/lib/musegadget -xf -

# 2. install; this opens the pairing window
git clone https://github.com/facebookincubator/muse-gadget-sdk
cd muse-gadget-sdk/linux
bash install.sh --from . --yes

# 3. in the Muse app, within 10 minutes:
#    Settings > Devices > Add Device > MuseGadgetXXXXXX
#    accept the community-device warning, pick the network it shows

sudo musegadget info                     # paired: yes
sudo systemctl disable --now musegadget  # only one host may be live
```

### Back on the pairing host, from this repo

```sh
sudo bash scripts/transplant-muse-state.sh --host pi@muse.local --dry-run
sudo bash scripts/transplant-muse-state.sh --host pi@muse.local --restart
```

### Verify

```sh
ssh pi@muse.local 'sudo musegadget doctor'
ssh pi@muse.local 'sudo journalctl -u musegadget -n 20'
```

Expect `[OK] Pairing`, `[OK] Service`, `[WARN] Bluetooth`, and a
`registered with the Muse` line. Then, from the Muse app:

> Run `hostname` on my device.

It must answer with the gadget host's name.

### If something fails

| Symptom | Fix |
|---|---|
| `Permission denied (publickey)` during the transplant | `sudo MUSE_SSH_OPTS="-i /home/USER/.ssh/id_ed25519 -o UserKnownHostsFile=/home/USER/.ssh/known_hosts" bash scripts/transplant-muse-state.sh --host ...` |
| `websockets` fails to build | `sudo apt install -y build-essential python3-dev`, rerun the installer |
| App never lists the device | The 10-minute window closed: `sudo musegadget pair` |
| `already holds a different gadget identity` | The pairing host invented its own identity; redo the identity copy before pairing |
| `401`/`403` in the journal | Tokens rejected: re-pair, or use a USB BLE dongle on the gadget host |
