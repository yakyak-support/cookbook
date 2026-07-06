# Debug YakYak Docker containers via SSH

Debug Docker containers on the remote server. All commands are executed over SSH.

## SSH Command

All commands MUST be run through this SSH prefix:

```
ssh -i /Users/johan/Projects/121/ssh-keys/1-2-1.pem -o ServerAliveInterval=60 -o ServerAliveCountMax=3 ubuntu@50.112.243.172
```

Example: `ssh -i /Users/johan/Projects/121/ssh-keys/1-2-1.pem -o ServerAliveInterval=60 -o ServerAliveCountMax=3 ubuntu@50.112.243.172 "docker ps"`

## Procedure

1. Run `docker ps` on the remote to list running containers
2. If $ARGUMENTS is provided, match it to a container name (e.g. `/usessh api` targets the API container). Otherwise, ask the user which container to debug.
3. Once the target container is identified, begin debugging using the tools below.

## Debugging Toolkit

Use these Docker commands over SSH to diagnose issues:

| Command | Purpose |
|---|---|
| `docker ps` | List running containers, check status/uptime |
| `docker logs <container> --tail 200` | Recent logs (increase tail as needed) |
| `docker logs <container> --since 10m` | Logs from the last N minutes |
| `docker inspect <container>` | Full container config, env vars, mounts, networking |
| `docker exec <container> <cmd>` | Run a command inside the container (e.g. `ls`, `cat`, `env`, `curl`) |
| `docker stats <container> --no-stream` | CPU/memory/network usage snapshot |
| `docker top <container>` | Running processes inside the container |
| `docker diff <container>` | Filesystem changes since container started |
| `docker restart <container>` | Restart a container (ask user before doing this) |

## Debugging Flow

1. **Check health**: `docker ps` — is the container running? How long has it been up? Any restarts?
2. **Check logs**: `docker logs --tail 200` — look for errors, stack traces, warnings
3. **Check resources**: `docker stats --no-stream` — is it OOM or CPU-starved?
4. **Check config**: `docker inspect` — verify env vars, port bindings, volume mounts
5. **Go deeper**: `docker exec` — run commands inside the container to test connectivity, check files, etc.

## Rules

- Never restart or stop a container without asking the user first
- Always wrap remote commands in quotes when passing through SSH
- For multi-command pipelines, use `bash -c '...'` inside the SSH command
- Report findings clearly: what's healthy, what's broken, and suggested next steps
