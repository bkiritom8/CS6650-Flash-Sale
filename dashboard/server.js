import express from 'express';
import cors from 'cors';
import { spawn } from 'child_process';
import path from 'path';
import { fileURLToPath } from 'url';
import fs from 'fs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const app = express();
app.use(cors());
app.use(express.json());

// Path to the scripts directory at the root of the repo
const scriptsDir = path.resolve(__dirname, '../scripts');

app.get('/api/stream-experiment/:id', (req, res) => {
  const { id } = req.params;
  
  // Validate experiment ID to prevent command injection
  const validExperiments = ['exp1', 'exp2', 'exp3', 'exp4', 'exp5'];
  if (!validExperiments.includes(id)) {
    return res.status(400).json({ error: 'Invalid experiment ID' });
  }

  // Setup SSE
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.flushHeaders();

  const scriptName = `${id}-locust-test.sh`;
  const scriptPath = path.join(scriptsDir, scriptName);

  console.log(`Running experiment script: ${scriptPath}`);

  // Spawn the shell script
  const child = spawn('bash', [scriptPath], {
    cwd: path.resolve(__dirname, '..'), // Run from repo root
  });

  child.stdout.on('data', (data) => {
    res.write(`data: ${JSON.stringify({ type: 'stdout', data: data.toString() })}\n\n`);
  });

  child.stderr.on('data', (data) => {
    res.write(`data: ${JSON.stringify({ type: 'stderr', data: data.toString() })}\n\n`);
  });

  child.on('close', (code) => {
    console.log(`Process exited with code ${code}`);
    res.write(`data: ${JSON.stringify({ type: 'close', code })}\n\n`);
    res.end();
  });

  child.on('error', (err) => {
    console.error(`Failed to start subprocess: ${err}`);
    res.write(`data: ${JSON.stringify({ type: 'error', data: err.message })}\n\n`);
    res.end();
  });

  // If client disconnects, we might want to kill the subprocess, but since it's an experiment, 
  // letting it finish or killing it depends on preference. We'll kill it to prevent runaway tests.
  req.on('close', () => {
    if (!child.killed) {
      child.kill();
    }
  });
});

app.get('/api/latest-result/:id', (req, res) => {
  const { id } = req.params;
  const validExperiments = ['exp1', 'exp2', 'exp3', 'exp4', 'exp5'];
  
  if (!validExperiments.includes(id)) {
    return res.status(400).json({ error: 'Invalid experiment ID' });
  }

  const resultsDir = path.resolve(__dirname, '../results');
  
  if (!fs.existsSync(resultsDir)) {
    return res.json({ data: [] });
  }

  const files = fs.readdirSync(resultsDir);
  // Find all csv files that start with the id prefix (e.g. exp1_2026...)
  let targetFiles = files.filter(f => f.startsWith(`${id}_`) && f.endsWith('.csv'));
  
  if (targetFiles.length === 0) {
    return res.json({ data: [] });
  }

  // Sort files by timestamp (alphanumerical since they are named with YYYYMMDD_HHMMSS)
  targetFiles.sort();
  const latestFile = targetFiles[targetFiles.length - 1];
  
  const content = fs.readFileSync(path.join(resultsDir, latestFile), 'utf-8');
  
  // Simple CSV parser
  const lines = content.trim().split('\n');
  if (lines.length <= 1) return res.json({ data: [] });

  const headers = lines[0].split(',').map(h => h.trim());
  const jsonArray = lines.slice(1).map(line => {
    const values = line.split(',').map(v => v.trim());
    let obj = {};
    headers.forEach((h, i) => {
      obj[h] = values[i] !== undefined ? values[i] : null;
    });
    return obj;
  });

  res.json({ data: jsonArray });
});

const PORT = 3001;
app.listen(PORT, () => {
  console.log(`Dashboard backend running on http://localhost:${PORT}`);
});
