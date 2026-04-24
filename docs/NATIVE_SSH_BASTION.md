# Native SSH via bastion

Status: guest-side support added.

## What exists now
- Sandboxes can boot with `openssh-server` installed.
- On create, backend forwards optional `ssh_public_key` to sandbox-manager.
- sandbox-manager injects it into Firecracker MMDS.
- Guest `/init` creates `dev`, writes `/home/dev/.ssh/authorized_keys`, generates host keys, starts `sshd`.

## Native SSH shape
Use standard OpenSSH via the sandbox host as a jump host:

```bash
ssh -J jump@sandbox.todofor.ai dev@10.0.0.23
```

Equivalent SSH config:

```sshconfig
Host sbx-abc
  HostName 10.0.0.23
  User dev
  ProxyJump jump@sandbox.todofor.ai
```

Then:

```bash
ssh sbx-abc
scp file.txt sbx-abc:/home/dev/
rsync -av . sbx-abc:/home/dev/project/
```

## What is still missing on the host
Guest-side SSH alone is not enough for end users. The jump host still needs a user-facing auth model:

### Option A1 — per-user jump account
- Create one Linux account per todofor.ai user on `sandbox.todofor.ai`
- Install that user's SSH public key into the jump account
- Users connect with `ssh -J <jump-user>@sandbox.todofor.ai dev@10.0.0.x`

Pros: standard OpenSSH, easy to reason about.
Cons: host account lifecycle to manage.

### Option A2 — shared restricted jump account
- One account like `jump`
- User key forced via `authorized_keys` restrictions / forced command
- Server enforces which target IPs each key may reach

Pros: fewer Linux accounts.
Cons: more SSH policy glue on the bastion.

## Current admin/test command
If you already have SSH access to the host:

```bash
ssh -J root@sandbox.todofor.ai dev@10.0.0.23
```

## Recommended next host task
Start with A1 for simplicity:
1. add `AllowTcpForwarding yes` / `PermitOpen any` as needed on host sshd
2. create per-user jump accounts
3. store each user's public key once
4. generate a ready-to-paste SSH config snippet from backend
