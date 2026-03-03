# Knobert Arm Bootstrap

One curl to join the octopus.

```bash
BRIDGE_KEY=your-key bash <(curl -fsSL https://knobesq.github.io/knobert-arm/bootstrap.sh)
```

## What it does

1. Discovers the GAS bridge URL from this repo (no hardcoding)
2. Pulls the latest `knobesq/knobert-harness` Docker image
3. Builds a live worker image
4. Runs as a worker that polls for tasks, executes them, and reports results
5. Auto-restarts on exit, re-pulls latest image, re-checks bridge URL

## Options

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `BRIDGE_KEY` | Yes | — | Bridge authentication key |
| `INSTANCE_ID` | No | auto | Name for this arm instance |
| `MODEL` | No | auto | Preferred model (haiku, sonnet) |
| `DOCKER_IMAGE` | No | knobesq/knobert-harness:latest | Custom harness image |
| `RESTART_DELAY` | No | 30 | Seconds between restart attempts |

## Architecture

```
Neil's Mac / Cloud VM / Raspberry Pi / etc.
    └── bootstrap.sh
        └── Docker: knobert-harness (worker mode)
            ├── Polls GAS bridge for tasks
            ├── Executes via Claude Code (claude -p)
            ├── Reports results via bridge
            └── Heartbeat to Instance Registry
```

The only secret is `BRIDGE_KEY`. Everything else is discovered.
