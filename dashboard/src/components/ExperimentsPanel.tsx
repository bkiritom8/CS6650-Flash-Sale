import { useState } from 'react';
import { ExperimentChartResult } from './ExperimentChartResult';

type ExperimentState = 'idle' | 'running' | 'success' | 'error';

interface ExperimentDefinition {
  id: string;
  name: string;
  description: string;
}

const EXPERIMENTS: ExperimentDefinition[] = [
  { id: 'exp1', name: 'Experiment 1', description: 'Baseline Load Test' },
  { id: 'exp2', name: 'Experiment 2', description: 'High Concurrency Scenario' },
  { id: 'exp3', name: 'Experiment 3', description: 'Autoscaling Policy Comparison' },
  { id: 'exp4', name: 'Experiment 4', description: 'Fault Tolerance Test' },
  { id: 'exp5', name: 'Experiment 5', description: 'Full System Verification' },
];

export function ExperimentsPanel() {
  const [runningExp, setRunningExp] = useState<string | null>(null);
  const [expStatus, setExpStatus] = useState<ExperimentState>('idle');
  const [logs, setLogs] = useState<string>('');
  const [chartDataMap, setChartDataMap] = useState<Record<string, any[]>>({});

  const fetchChartData = async (id: string) => {
    try {
       const res = await fetch(`http://localhost:3001/api/latest-result/${id}`);
       const json = await res.json();
       if (json.data && json.data.length > 0) {
          setChartDataMap(prev => ({ ...prev, [id]: json.data }));
       }
    } catch (e) {
       console.error("Failed to fetch chart data", e);
    }
  };

  const runExperiment = (id: string, append = false): Promise<void> => {
    return new Promise((resolve) => {
      if (runningExp) return resolve();

      setRunningExp(id);
      setExpStatus('running');
      setLogs(prev => append ? prev + `\n--- Starting ${id} ---\n` : `Starting ${id}...\n`);
      setChartDataMap(prev => { const next = { ...prev }; delete next[id]; return next; });

      const eventSource = new EventSource(`http://localhost:3001/api/stream-experiment/${id}`);

      eventSource.onmessage = (event) => {
        try {
          const msg = JSON.parse(event.data);
          if (msg.type === 'stdout' || msg.type === 'stderr') {
            setLogs(prev => prev + msg.data);
          } else if (msg.type === 'close') {
            setLogs(prev => prev + `\nProcess exited with code ${msg.code}\n`);
            if (msg.code === 0) {
              setExpStatus('success');
            } else {
              setExpStatus('error');
            }
            fetchChartData(id);
            setRunningExp(null);
            eventSource.close();
            resolve();
          } else if (msg.type === 'error') {
            setLogs(prev => prev + `\nProcess Error: ${msg.data}\n`);
            setExpStatus('error');
            setRunningExp(null);
            eventSource.close();
            resolve();
          }
        } catch (err) {
          setLogs(prev => prev + `\nParse Error: ${event.data}\n`);
        }
      };

      eventSource.onerror = () => {
        setLogs(prev => prev + `\n[Stream disconnected or network error]\n`);
        setExpStatus('error');
        setRunningExp(null);
        eventSource.close();
        resolve();
      };
    });
  };

  const runAllExperiments = async () => {
    if (runningExp) return;
    setLogs('=== Running all experiments sequentially ===\n');
    setChartDataMap({});
    for (const exp of EXPERIMENTS) {
      await runExperiment(exp.id, true);
    }
    setLogs(prev => prev + '\n=== All experiments complete ===\n');
  };

  return (
    <div className="glass-panel p-6 flex-col gap-4 animate-fade-in" style={{ padding: '24px' }}>
      <div className="flex-between">
        <div>
          <h2 className="text-xl font-bold text-gradient mb-1">Experiment Runner</h2>
          <p className="text-sm text-secondary">Execute predefined backend Locust shell scripts from the dashboard.</p>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
          {expStatus === 'running' && (
            <div className="status-badge mock animate-pulse">Running {runningExp}</div>
          )}
          <button
            onClick={runAllExperiments}
            disabled={!!runningExp}
            className="btn-outline"
            style={{ padding: '8px 16px', opacity: runningExp ? 0.5 : 1, cursor: runningExp ? 'not-allowed' : 'pointer', whiteSpace: 'nowrap' }}
          >
            Run All Experiments
          </button>
        </div>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4 mt-4" style={{ display: 'grid', gridTemplateColumns: 'repeat(5, 1fr)', gap: '16px'}}>
        {EXPERIMENTS.map(exp => (
          <div key={exp.id} className="stat-box flex-col gap-2" style={{ display: 'flex', border: '1px solid var(--color-panel-border)', padding: '16px', borderRadius: '8px' }}>
            <h3 className="font-semibold">{exp.name}</h3>
            <p className="text-xs text-secondary mb-2 flex-grow">{exp.description}</p>
            <button 
              onClick={() => runExperiment(exp.id)}
              disabled={!!runningExp}
              className="btn-outline"
              style={{ padding: '8px', opacity: runningExp ? 0.5 : 1, cursor: runningExp ? 'not-allowed' : 'pointer' }}
            >
              {runningExp === exp.id ? 'Running...' : 'Run Experiment'}
            </button>
          </div>
        ))}
      </div>

      {Object.keys(chartDataMap).length > 0 && (
        <div className="mt-6">
          <h3 className="font-semibold text-sm mb-3 text-secondary">Results</h3>
          <div style={{ display: 'flex', flexDirection: 'column', gap: '16px' }}>
            {EXPERIMENTS.filter(exp => chartDataMap[exp.id]).map(exp => (
              <div key={exp.id}>
                <p className="text-xs text-secondary mb-1">{exp.name} — {exp.description}</p>
                <ExperimentChartResult id={exp.id} data={chartDataMap[exp.id]} />
              </div>
            ))}
          </div>
        </div>
      )}

      {logs && (
        <div className="mt-6">
          <h3 className="font-semibold text-sm mb-2 text-secondary">Execution Logs</h3>
          <pre className="glass-panel p-4 text-xs" style={{
            height: '400px',
            overflow: 'auto',
            backgroundColor: 'rgba(0,0,0,0.3)',
            padding: '16px',
            whiteSpace: 'pre-wrap',
            wordWrap: 'break-word',
            fontFamily: 'monospace'
          }}>
            {logs}
          </pre>
        </div>
      )}
    </div>
  );
}
