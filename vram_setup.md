# Increasing Swap RAM on Arch Linux

## Step 1 — Check Current Swap

```bash
swapon --show
free -h
```

Take note of what you already have. If you see `/dev/zram0`, that is RAM-based swap and not a real disk safety net.

---

## Step 2 — Check Your Filesystem Type

```bash
df -T /
```

Look at the **Type** column. This determines which method you use next.

---

## Step 3 — Create the Swap File

### If filesystem is `btrfs`

```bash
sudo btrfs filesystem mkswapfile --size 16g /swapfile
```

### If filesystem is `ext4` or other

```bash
sudo fallocate -l 16G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
```

> **Note:** Do not use `dd` on btrfs — it will fail with an `Invalid argument` error.

---

## Step 4 — Enable the Swap File

```bash
sudo swapon /swapfile
```

---

## Step 5 — Make It Permanent (Survives Reboot)

```bash
echo '/swapfile none swap defaults 0 0' | sudo tee -a /etc/fstab
```

---

## Step 6 — Verify

```bash
free -h
swapon --show
```

You should see your swapfile listed alongside any existing swap (e.g. zram).

---

## Optional — Tune Swappiness

By default swappiness is 60, meaning the system swaps fairly aggressively. Lower it so RAM is prioritized first:

```bash
# Check current value
cat /proc/sys/vm/swappiness

# Set it to 10
sudo sysctl vm.swappiness=10

# Make it permanent
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf
```

---

## Removing the Swap File Later (Optional)

If you ever want to remove it:

```bash
sudo swapoff /swapfile
sudo rm /swapfile
```

Then remove the `/swapfile` line from `/etc/fstab`:

```bash
sudo nano /etc/fstab
```
