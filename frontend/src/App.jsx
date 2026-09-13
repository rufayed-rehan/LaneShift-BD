import { useCallback, useEffect, useMemo, useState } from "react";

const API_URL = import.meta.env.VITE_API_URL || "http://127.0.0.1:8000";

async function api(path, options = {}) {
  const response = await fetch(`${API_URL}${path}`, {
    headers: { "Content-Type": "application/json", ...options.headers },
    ...options,
  });
  if (!response.ok) {
    const body = await response.json().catch(() => ({}));
    throw new Error(body.detail || `Request failed (${response.status})`);
  }
  return response.json();
}

const number = (value, digits = 1) => Number(value ?? 0).toFixed(digits);
const integer = (value) => Number(value ?? 0).toLocaleString();

function Badge({ children, tone = "neutral" }) {
  return <span className={`badge badge-${tone}`}>{children}</span>;
}

function StatCard({ label, value, note, tone = "green" }) {
  return (
    <article className={`stat-card stat-${tone}`}>
      <span>{label}</span>
      <strong>{value}</strong>
      <small>{note}</small>
    </article>
  );
}

function LaneVisual({ inbound, outbound, compact = false }) {
  const inboundLanes = Array.from({ length: Number(inbound || 0) });
  const outboundLanes = Array.from({ length: Number(outbound || 0) });
  return (
    <div className={`lane-visual ${compact ? "compact" : ""}`} aria-label={`${inbound} inbound and ${outbound} outbound lanes`}>
      <div className="lane-direction inbound">
        {inboundLanes.map((_, index) => <i key={`in-${index}`}>↑</i>)}
      </div>
      <div className="road-divider" />
      <div className="lane-direction outbound">
        {outboundLanes.map((_, index) => <i key={`out-${index}`}>↓</i>)}
      </div>
    </div>
  );
}

function QueueChart({ samples }) {
  const baseline = samples.filter((item) => item.is_baseline);
  const selected = samples.filter((item) => item.is_selected);
  if (!baseline.length || !selected.length) {
    return <div className="empty-chart">Run a simulation to create the queue comparison.</div>;
  }

  const width = 760;
  const height = 250;
  const padX = 44;
  const padTop = 20;
  const padBottom = 34;
  const all = [...baseline, ...selected];
  const maxMinute = Math.max(...all.map((item) => Number(item.simulated_minute)), 1);
  const maxQueue = Math.max(
    ...all.map((item) => Number(item.inbound_queue) + Number(item.outbound_queue)),
    1,
  );
  const x = (minute) => padX + (Number(minute) / maxMinute) * (width - padX - 14);
  const y = (queue) => padTop + (1 - Number(queue) / maxQueue) * (height - padTop - padBottom);
  const points = (items) => items
    .map((item) => `${x(item.simulated_minute)},${y(Number(item.inbound_queue) + Number(item.outbound_queue))}`)
    .join(" ");
  const guideValues = [0, Math.round(maxQueue / 2), maxQueue];

  return (
    <div className="chart-shell">
      <svg viewBox={`0 0 ${width} ${height}`} role="img" aria-label="Baseline and selected total queue over simulated time">
        {guideValues.map((value) => (
          <g key={value}>
            <line className="chart-guide" x1={padX} x2={width - 14} y1={y(value)} y2={y(value)} />
            <text className="chart-label" x={padX - 8} y={y(value) + 4} textAnchor="end">{value}</text>
          </g>
        ))}
        <line className="chart-axis" x1={padX} x2={width - 14} y1={height - padBottom} y2={height - padBottom} />
        <polyline className="chart-line baseline-line" points={points(baseline)} />
        <polyline className="chart-line selected-line" points={points(selected)} />
        {[0, Math.round(maxMinute / 2), maxMinute].map((minute) => (
          <text key={minute} className="chart-label" x={x(minute)} y={height - 10} textAnchor="middle">{minute} min</text>
        ))}
      </svg>
      <div className="chart-legend">
        <span><i className="legend-baseline" /> Fixed baseline queue</span>
        <span><i className="legend-selected" /> Database-selected queue</span>
      </div>
    </div>
  );
}

function MetricComparison({ label, before, after, unit = "", lowerIsBetter = true }) {
  const beforeNumber = Number(before ?? 0);
  const afterNumber = Number(after ?? 0);
  const improved = lowerIsBetter ? afterNumber < beforeNumber : afterNumber > beforeNumber;
  return (
    <article className="metric-comparison">
      <p>{label}</p>
      <div><span>Fixed</span><b>{number(beforeNumber)}{unit}</b></div>
      <div><span>Selected</span><b>{number(afterNumber)}{unit}</b></div>
      <Badge tone={improved ? "green" : "neutral"}>{improved ? "Improved" : "Stable"}</Badge>
    </article>
  );
}

function Empty({ children }) {
  return <div className="empty">{children}</div>;
}

function App() {
  const [tab, setTab] = useState("simulation");
  const [scenarios, setScenarios] = useState([]);
  const [segments, setSegments] = useState([]);
  const [runs, setRuns] = useState([]);
  const [summary, setSummary] = useState({});
  const [evidence, setEvidence] = useState({ row_counts: {}, database_objects: {}, safeguards: [] });
  const [scenarioCode, setScenarioCode] = useState("morning_peak");
  const [segmentId, setSegmentId] = useState("1");
  const [seed, setSeed] = useState("4410");
  const [activeRun, setActiveRun] = useState(null);
  const [loading, setLoading] = useState(true);
  const [running, setRunning] = useState(false);
  const [notice, setNotice] = useState("");
  const [error, setError] = useState("");

  const loadProject = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      const [scenarioData, segmentData, runData, summaryData, evidenceData] = await Promise.all([
        api("/api/simulation/scenarios"),
        api("/api/segments"),
        api("/api/simulation/runs?limit=25"),
        api("/api/dashboard/summary"),
        api("/api/database/evidence"),
      ]);
      setScenarios(scenarioData);
      setSegments(segmentData);
      setRuns(runData);
      setSummary(summaryData);
      setEvidence(evidenceData);
      if (runData.length && !activeRun) {
        setActiveRun(await api(`/api/simulation/runs/${runData[0].run_id}`));
      }
    } catch (err) {
      setError(`${err.message}. Confirm PostgreSQL and FastAPI are running.`);
    } finally {
      setLoading(false);
    }
  }, [activeRun]);

  useEffect(() => {
    loadProject();
    // The initial load intentionally runs once; later refreshes are explicit.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const selectedScenario = useMemo(
    () => scenarios.find((item) => item.scenario_code === scenarioCode),
    [scenarios, scenarioCode],
  );

  const startSimulation = async () => {
    setRunning(true);
    setNotice("");
    setError("");
    try {
      const result = await api("/api/simulation/runs", {
        method: "POST",
        body: JSON.stringify({
          scenario_code: scenarioCode,
          segment_id: Number(segmentId),
          seed: Number(seed),
        }),
      });
      setActiveRun(result);
      const [runData, summaryData, evidenceData] = await Promise.all([
        api("/api/simulation/runs?limit=25"),
        api("/api/dashboard/summary"),
        api("/api/database/evidence"),
      ]);
      setRuns(runData);
      setSummary(summaryData);
      setEvidence(evidenceData);
      setNotice(
        `Run #${result.run_id} completed. PostgreSQL ${result.decision_type === "retain" ? "retained" : "selected"} ${result.selected_inbound_lanes}/${result.selected_outbound_lanes}.`,
      );
    } catch (err) {
      setError(err.message);
    } finally {
      setRunning(false);
    }
  };

  const openRun = async (runId) => {
    setError("");
    try {
      setActiveRun(await api(`/api/simulation/runs/${runId}`));
      setTab("simulation");
      window.scrollTo({ top: 0, behavior: "smooth" });
    } catch (err) {
      setError(err.message);
    }
  };

  const recordOverride = async () => {
    if (!activeRun || activeRun.decision_status === "overridden") return;
    setError("");
    try {
      const updated = await api(`/api/simulation/runs/${activeRun.run_id}/override`, {
        method: "POST",
        body: JSON.stringify({
          operator: "dashboard.supervisor",
          reason: "Demonstration safety override requested by the supervising operator",
        }),
      });
      setActiveRun(updated);
      setNotice(`Safety override recorded for run #${activeRun.run_id}; the audit history was updated.`);
      setRuns(await api("/api/simulation/runs?limit=25"));
    } catch (err) {
      setError(err.message);
    }
  };

  const objectCounts = evidence.database_objects || {};
  const rowCounts = evidence.row_counts || {};

  return (
    <div className="app-shell">
      <header className="topbar">
        <div className="brand-mark">LS</div>
        <div className="brand-copy">
          <p className="overline">TRAFFIC DIGITAL TWIN</p>
          <h1>LaneShift BD</h1>
          <span>Database-centered reversible-lane optimization</span>
        </div>
        <div className="system-status"><i /> PostgreSQL + SimPy ready</div>
      </header>

      <nav className="tabs" aria-label="Dashboard sections">
        {[
          ["simulation", "Simulation lab"],
          ["history", `Run history (${runs.length})`],
          ["database", "DBMS evidence"],
        ].map(([key, label]) => (
          <button key={key} className={tab === key ? "active" : ""} onClick={() => setTab(key)}>{label}</button>
        ))}
        <button className="refresh" onClick={loadProject}>Refresh database</button>
      </nav>

      <main>
        {notice && <div className="notice success">{notice}</div>}
        {error && <div className="notice error">{error}</div>}
        {loading && <div className="loading"><span className="spinner" />Loading the database workspace…</div>}

        {!loading && tab === "simulation" && (
          <>
            <section className="hero-grid">
              <div className="hero-copy">
                <p className="eyebrow">CONTROLLED EXPERIMENT</p>
                <h2>Can adaptive lanes beat a fixed road?</h2>
                <p>
                  SimPy creates one reproducible stream of vehicles. Every safe lane split receives that exact demand,
                  and PostgreSQL selects a winner only when the improvement is meaningful.
                </p>
                <div className="process-strip">
                  <span><b>1</b> Generate demand</span><i>→</i>
                  <span><b>2</b> Test every split</span><i>→</i>
                  <span><b>3</b> Database decides</span>
                </div>
              </div>
              <div className="hero-stats">
                <StatCard label="Simulation runs" value={summary.simulation_runs ?? 0} note="Persisted experiments" />
                <StatCard label="Latest improvement" value={`${number(summary.latest_simulation_improvement)}%`} note="Against fixed lanes" tone="amber" />
              </div>
            </section>

            <section className="workspace-grid">
              <aside className="control-panel">
                <div className="panel-heading">
                  <div><p className="eyebrow">EXPERIMENT SETUP</p><h3>Choose traffic pressure</h3></div>
                  <Badge tone="blue">60 virtual min</Badge>
                </div>

                <div className="scenario-list">
                  {scenarios.map((scenario) => (
                    <button
                      key={scenario.scenario_code}
                      className={scenarioCode === scenario.scenario_code ? "scenario active" : "scenario"}
                      onClick={() => setScenarioCode(scenario.scenario_code)}
                    >
                      <span>{scenario.name}</span>
                      <small>{scenario.description}</small>
                    </button>
                  ))}
                </div>

                <label className="field">
                  <span>Road segment</span>
                  <select value={segmentId} onChange={(event) => setSegmentId(event.target.value)}>
                    {segments.map((segment) => (
                      <option key={segment.segment_id} value={segment.segment_id}>
                        {segment.segment_code} · {segment.segment_name} · {segment.total_lanes} lanes
                      </option>
                    ))}
                  </select>
                </label>

                <label className="field">
                  <span>Random seed <em>repeatable experiment</em></span>
                  <input type="number" min="1" max="2147483647" value={seed} onChange={(event) => setSeed(event.target.value)} />
                </label>

                {selectedScenario && (
                  <div className="demand-card">
                    <div><span>Inbound demand</span><b>{integer(selectedScenario.inbound_rate_vph)} veh/h</b></div>
                    <div><span>Outbound demand</span><b>{integer(selectedScenario.outbound_rate_vph)} veh/h</b></div>
                    <div><span>Weather capacity</span><b>{number(Number(selectedScenario.weather_speed_factor) * 100, 0)}%</b></div>
                  </div>
                )}

                <button className="primary run-button" onClick={startSimulation} disabled={running || !scenarioCode || !segmentId}>
                  {running ? <><span className="button-spinner" /> Testing every allocation…</> : "Run automated experiment"}
                </button>
                <p className="control-note">No result is hardcoded. The same stochastic arrivals are replayed for every candidate.</p>
              </aside>

              <section className="result-panel">
                {!activeRun ? (
                  <Empty>Select a scenario and run the first experiment.</Empty>
                ) : (
                  <>
                    <div className="result-header">
                      <div>
                        <p className="eyebrow">RUN #{activeRun.run_id} · SEED {activeRun.random_seed}</p>
                        <h3>{activeRun.scenario_name}</h3>
                        <p>{activeRun.segment_code} · {activeRun.segment_name}</p>
                      </div>
                      <Badge tone={activeRun.decision_type === "reallocate" ? "green" : "neutral"}>
                        {activeRun.decision_type === "reallocate" ? "Automatically reallocated" : "Baseline retained"}
                      </Badge>
                    </div>

                    <div className="decision-stage">
                      <div className="allocation-card baseline-allocation">
                        <span>Fixed baseline</span>
                        <LaneVisual inbound={activeRun.baseline_inbound_lanes} outbound={activeRun.baseline_outbound_lanes} />
                        <b>{activeRun.baseline_inbound_lanes} inbound / {activeRun.baseline_outbound_lanes} outbound</b>
                      </div>
                      <div className="decision-arrow">
                        <small>POSTGRESQL DECISION</small>
                        <strong>{number(activeRun.predicted_improvement_percent)}%</strong>
                        <span>objective improvement</span>
                        <i>→</i>
                      </div>
                      <div className="allocation-card selected-allocation">
                        <span>Selected allocation</span>
                        <LaneVisual inbound={activeRun.selected_inbound_lanes} outbound={activeRun.selected_outbound_lanes} />
                        <b>{activeRun.selected_inbound_lanes} inbound / {activeRun.selected_outbound_lanes} outbound</b>
                      </div>
                    </div>

                    <div className="reason-box">
                      <span>Why this decision?</span>
                      <p>{activeRun.decision_reason}</p>
                    </div>

                    <div className="comparison-grid">
                      <MetricComparison label="Average waiting" before={activeRun.baseline_wait_seconds} after={activeRun.selected_wait_seconds} unit=" sec" />
                      <MetricComparison label="Maximum queue" before={activeRun.baseline_max_queue} after={activeRun.selected_max_queue} unit=" vehicles" />
                      <MetricComparison label="Average speed" before={activeRun.baseline_speed_kph} after={activeRun.selected_speed_kph} unit=" km/h" lowerIsBetter={false} />
                      <MetricComparison label="Completed vehicles" before={activeRun.baseline_completed_vehicles} after={activeRun.selected_completed_vehicles} lowerIsBetter={false} />
                    </div>
                  </>
                )}
              </section>
            </section>

            {activeRun && (
              <>
                <section className="panel">
                  <div className="panel-heading">
                    <div><p className="eyebrow">TIME-SERIES EVIDENCE</p><h3>Total queue over the virtual hour</h3></div>
                    <Badge tone="blue">5-minute samples</Badge>
                  </div>
                  <QueueChart samples={activeRun.samples || []} />
                </section>

                <section className="panel">
                  <div className="panel-heading">
                    <div><p className="eyebrow">COUNTERFACTUAL SEARCH</p><h3>Every legal lane allocation</h3></div>
                    <span className="panel-note">Lower objective score is better; switching carries a small stability penalty.</span>
                  </div>
                  <div className="table-wrap">
                    <table>
                      <thead>
                        <tr><th>Allocation</th><th>Role</th><th>Avg wait</th><th>P95 wait</th><th>Max queue</th><th>Completed</th><th>Avg speed</th><th>Score</th><th>vs baseline</th></tr>
                      </thead>
                      <tbody>
                        {(activeRun.candidates || []).map((candidate) => (
                          <tr key={candidate.candidate_id} className={candidate.is_selected ? "selected-row" : ""}>
                            <td><LaneVisual inbound={candidate.inbound_lanes} outbound={candidate.outbound_lanes} compact /><b>{candidate.inbound_lanes}/{candidate.outbound_lanes}</b></td>
                            <td>
                              {candidate.is_selected && <Badge tone="green">Selected</Badge>}
                              {candidate.is_baseline && <Badge tone="neutral">Baseline</Badge>}
                              {!candidate.is_selected && !candidate.is_baseline && <span className="muted">Candidate</span>}
                            </td>
                            <td>{number(candidate.average_wait_seconds)} sec</td>
                            <td>{number(candidate.p95_wait_seconds)} sec</td>
                            <td>{integer(candidate.max_queue_vehicles)}</td>
                            <td>{integer(candidate.completed_vehicles)}</td>
                            <td>{number(candidate.average_speed_kph)} km/h</td>
                            <td><b>{number(candidate.objective_score, 2)}</b></td>
                            <td className={Number(candidate.improvement_percent) > 0 ? "positive" : ""}>{number(candidate.improvement_percent)}%</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                </section>

                <section className="lower-grid">
                  <article className="panel timeline-panel">
                    <div className="panel-heading"><div><p className="eyebrow">AUDIT TRAIL</p><h3>Automated lifecycle</h3></div></div>
                    <div className="timeline">
                      {(activeRun.events || []).map((event) => (
                        <div key={event.event_id}>
                          <i />
                          <span><b>{event.event_type.replaceAll("_", " ")}</b><small>{event.message}</small></span>
                        </div>
                      ))}
                    </div>
                  </article>
                  <article className="panel oversight-panel">
                    <div className="panel-heading"><div><p className="eyebrow">HUMAN OVERSIGHT</p><h3>Automation with a safety boundary</h3></div></div>
                    <p>The system makes the routine decision. A supervisor only intervenes for safety, emergencies, or incorrect sensor data.</p>
                    <div className="status-line"><span>Decision state</span><Badge tone={activeRun.decision_status === "overridden" ? "red" : "green"}>{activeRun.decision_status?.replaceAll("_", " ")}</Badge></div>
                    {activeRun.decision_status !== "overridden" ? (
                      <button className="secondary" onClick={recordOverride}>Demonstrate safety override</button>
                    ) : (
                      <div className="override-record"><b>Override recorded</b><span>{activeRun.override_reason}</span></div>
                    )}
                  </article>
                </section>
              </>
            )}
          </>
        )}

        {!loading && tab === "history" && (
          <section className="panel standalone">
            <div className="panel-heading">
              <div><p className="eyebrow">REPRODUCIBLE EXPERIMENTS</p><h2>Simulation run history</h2></div>
              <Badge tone="blue">Stored in PostgreSQL</Badge>
            </div>
            {!runs.length ? <Empty>No simulations have been run yet.</Empty> : (
              <div className="history-list">
                {runs.map((run) => (
                  <button key={run.run_id} onClick={() => openRun(run.run_id)}>
                    <span className="run-number">#{run.run_id}</span>
                    <span className="history-main"><b>{run.scenario_name}</b><small>{run.segment_code} · seed {run.random_seed} · {run.duration_minutes} virtual minutes</small></span>
                    <LaneVisual inbound={run.selected_inbound_lanes || run.baseline_inbound_lanes} outbound={run.selected_outbound_lanes || run.baseline_outbound_lanes} compact />
                    <span className="history-decision"><b>{run.selected_inbound_lanes || "–"}/{run.selected_outbound_lanes || "–"}</b><small>{number(run.predicted_improvement_percent)}% improvement</small></span>
                    <Badge tone={run.run_status === "completed" ? "green" : run.run_status === "failed" ? "red" : "amber"}>{run.run_status}</Badge>
                  </button>
                ))}
              </div>
            )}
          </section>
        )}

        {!loading && tab === "database" && (
          <>
            <section className="section-heading">
              <div><p className="eyebrow">WHY THIS IS A DBMS PROJECT</p><h2>The database controls the experiment lifecycle</h2></div>
              <p>Python creates the virtual traffic. PostgreSQL preserves, validates, compares, selects, and audits every decision.</p>
            </section>
            <section className="stats-grid five">
              <StatCard label="Normalized tables" value={objectCounts.tables ?? 0} note="Persistent domain model" />
              <StatCard label="Analytical views" value={objectCounts.views ?? 0} note="Live comparisons" tone="blue" />
              <StatCard label="Functions / procedures" value={objectCounts.functions_and_procedures ?? 0} note="Database decisions" tone="amber" />
              <StatCard label="Triggers" value={objectCounts.triggers ?? 0} note="Automatic integrity" tone="red" />
              <StatCard label="Indexes" value={objectCounts.indexes ?? 0} note="Efficient retrieval" />
            </section>

            <section className="database-grid">
              <article className="panel architecture-card">
                <div className="panel-heading"><div><p className="eyebrow">RESPONSIBILITY SPLIT</p><h3>Computation versus data authority</h3></div></div>
                <div className="architecture-flow">
                  <div><span>PYTHON · SIMPY</span><b>Generate random vehicles</b><b>Replay equal demand</b><b>Measure each allocation</b></div>
                  <i>→</i>
                  <div><span>POSTGRESQL</span><b>Validate candidate data</b><b>Select qualified winner</b><b>Enforce state and audit</b></div>
                  <i>→</i>
                  <div><span>REACT</span><b>Start experiments</b><b>Visualize comparisons</b><b>Allow safety override</b></div>
                </div>
              </article>

              <article className="panel count-card">
                <div className="panel-heading"><div><p className="eyebrow">LIVE ROW COUNTS</p><h3>Simulation data now stored</h3></div></div>
                <div className="count-list">
                  {Object.entries(rowCounts).map(([key, value]) => (
                    <div key={key}><span>{key.replaceAll("_", " ")}</span><b>{integer(value)}</b></div>
                  ))}
                </div>
              </article>
            </section>

            <section className="panel safeguards-panel">
              <div className="panel-heading"><div><p className="eyebrow">DATABASE SAFEGUARDS</p><h3>Rules Python cannot bypass</h3></div></div>
              <div className="safeguard-grid">
                {(evidence.safeguards || []).map((item, index) => (
                  <div key={item}><span>{String(index + 1).padStart(2, "0")}</span><p>{item}</p></div>
                ))}
              </div>
            </section>
          </>
        )}
      </main>

      <footer>
        <span>LaneShift BD · CSE 4410 DBMS II Lab</span>
        <span>SimPy generates · PostgreSQL decides · React explains</span>
      </footer>
    </div>
  );
}

export default App;
