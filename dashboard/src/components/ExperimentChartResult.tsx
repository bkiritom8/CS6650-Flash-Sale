import { useEffect, useRef } from 'react';
import {
  Chart,
  BarController,
  BarElement,
  LinearScale,
  CategoryScale,
  Tooltip,
  Legend
} from 'chart.js';

Chart.register(BarController, BarElement, LinearScale, CategoryScale, Tooltip, Legend);

export function ExperimentChartResult({ id, data }: { id: string, data: any[] }) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const chartRef = useRef<Chart | null>(null);

  useEffect(() => {
    if (!canvasRef.current || !data || data.length === 0) return;

    let chartConfig: any = null;

    const gc = 'rgba(255, 255, 255, 0.05)';
    const textColor = '#9ca3af';

    const commonOptions = {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { 
            display: true, 
             labels: { color: textColor, font: { family: 'Inter' } } 
          },
          tooltip: {
            backgroundColor: 'rgba(15, 17, 21, 0.9)',
            titleColor: '#ffffff',
            bodyColor: '#ffffff',
            borderColor: 'rgba(255,255,255,0.1)',
            borderWidth: 1
          },
        },
        scales: {
          x: { grid: { color: gc }, ticks: { color: textColor } },
          y: { grid: { color: gc }, ticks: { color: textColor }, beginAtZero: true },
        },
    };

    if (id === 'exp1') {
      // Compare latencies across lock modes
      const labels = data.map(d => `${d.backend}\n${d.lock_mode}`);
      const avg = data.map(d => parseInt(d.avg_ms) || 0);
      const p50 = data.map(d => parseInt(d.p50_ms) || 0);
      const p95 = data.map(d => parseInt(d.p95_ms) || 0);
      const p99 = data.map(d => parseInt(d.p99_ms) || 0);

      chartConfig = {
        type: 'bar',
        data: {
          labels,
          datasets: [
            { label: 'Avg ms', data: avg, backgroundColor: '#ec4899' },
            { label: 'p50 ms', data: p50, backgroundColor: '#3b82f6' },
            { label: 'p95 ms', data: p95, backgroundColor: '#8b5cf6' },
            { label: 'p99 ms', data: p99, backgroundColor: '#f59e0b' }
          ]
        },
        options: { ...commonOptions, plugins: { ...commonOptions.plugins, title: { display: true, text: 'Latencies (Exp 1)', color: 'white' } } }
      };
    } else if (id === 'exp5') {
       // Fairness Mode
      const avg = data.map(d => parseInt(d.avg_ms) || 0);
      const p50 = data.map(d => parseInt(d.p50_ms) || 0);
      const p95 = data.map(d => parseInt(d.p95_ms) || 0);
      const p99 = data.map(d => parseInt(d.p99_ms) || 0);
      
      chartConfig = {
        type: 'bar',
        data: {
          labels: data.map(d => `${d.backend} (${d.endpoint}) - ${d.fairness_mode}`),
          datasets: [
            { label: 'Avg ms', data: avg, backgroundColor: '#ec4899' },
            { label: 'p50 ms', data: p50, backgroundColor: '#3b82f6' },
            { label: 'p95 ms', data: p95, backgroundColor: '#8b5cf6' },
            { label: 'p99 ms', data: p99, backgroundColor: '#f59e0b' }
          ]
        },
        options: { ...commonOptions, plugins: { ...commonOptions.plugins, title: { display: true, text: 'Fairness Mode Latencies (Exp 5)', color: 'white' } } }
      };
    } else if (id === 'exp3') {
      // Autoscaling policy comparison — rows keyed by config name
      const labels = data.map(d => d.config || d.name || d.Name || 'run');
      const avg = data.map(d => parseInt(d.avg_ms ?? d['Average Response Time']) || 0);
      const p95 = data.map(d => parseInt(d.p95_ms ?? d['95%']) || 0);
      const p99 = data.map(d => parseInt(d.p99_ms ?? d['99%']) || 0);

      chartConfig = {
        type: 'bar',
        data: {
          labels,
          datasets: [
            { label: 'Avg ms',  data: avg, backgroundColor: '#ec4899' },
            { label: 'p95 ms',  data: p95, backgroundColor: '#8b5cf6' },
            { label: 'p99 ms',  data: p99, backgroundColor: '#f59e0b' },
          ]
        },
        options: { ...commonOptions, plugins: { ...commonOptions.plugins, title: { display: true, text: 'Autoscaling Policy Latencies (Exp 3)', color: 'white' } } }
      };
    } else {
       // generic fallback (Exp 2, Exp 4)
       const headers = Object.keys(data[0]).filter(k => k.includes('ms') || k.includes('throughput'));
       
       chartConfig = {
        type: 'bar',
        data: {
          labels: data.map(d => d.backend || d.endpoint || 'run'),
          datasets: headers.map((h, i) => ({
             label: h,
             data: data.map(d => parseInt(d[h]) || 0),
             backgroundColor: i === 0 ? '#10b981' : '#f59e0b'
          }))
        },
        options: { ...commonOptions, plugins: { ...commonOptions.plugins, title: { display: true, text: 'Results', color: 'white' } } }
      };
    }

    if (chartConfig) {
      if (chartRef.current) chartRef.current.destroy();
      chartRef.current = new Chart(canvasRef.current, chartConfig);
    }

    return () => {
      chartRef.current?.destroy();
    };
  }, [id, data]);

  if (!data || data.length === 0) return null;

  return (
    <div className="glass-panel p-4 mt-6 animate-fade-in" style={{ backgroundColor: 'rgba(0,0,0,0.4)' }}>
       <div style={{ height: '300px' }}>
          <canvas ref={canvasRef} />
       </div>
    </div>
  );
}
