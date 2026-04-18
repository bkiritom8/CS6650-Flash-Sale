# Dashboard

React + TypeScript frontend with an Express backend that streams experiment output to the browser.

## Architecture

The dashboard has two processes that must both be running:

| Process | Command | Port | Purpose |
|---|---|---|---|
| Vite dev server | `npm run dev` | 5173 | React frontend |
| Express backend | `npm run start:server` | 3001 | Experiment runner + results API |

**Always start both together:**

```bash
cd dashboard
npm install       # first time only
npm run dev:all   # starts both Vite (5173) and Express (3001)
```

Open `http://localhost:5173`. The Experiment Runner panel makes SSE requests to `http://localhost:3001/api/stream-experiment/:id` — if the Express server isn't running, clicking "Run Experiment" will silently fail with a stream disconnect error.

## Experiment Runner

The backend spawns shell scripts from `../scripts/expN-locust-test.sh` and streams stdout/stderr back to the browser via Server-Sent Events. Results are read from `../results/expN_<timestamp>.csv` after each run completes.

Each experiment's chart is displayed separately (not combined). When running multiple experiments, charts accumulate — one per completed experiment — and appear **above** the execution log so results are visible without scrolling past terminal output. Re-running a single experiment replaces only that experiment's chart.

**Requirements before running experiments:**
- AWS infrastructure must be deployed (`../scripts/deploy.sh`)
- Python 3 + Locust installed (`pip install locust`)

## Available Scripts

```bash
npm run dev          # frontend only (experiments won't work)
npm run start:server # backend only
npm run dev:all      # both (use this)
npm run build        # production build
npm test             # run Vitest tests
```
