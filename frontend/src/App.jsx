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
const today = () => new Date().toISOString().slice(0, 10);

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

function Empty({ children }) {
  return <div className="empty">{children}</div>;
}

function App() {
  const [tab, setTab] = useState("overview");
  const [summary, setSummary] = useState({});
  const [corridors, setCorridors] = useState([]);
  const [segments, setSegments] = useState([]);
  const [suggestions, setSuggestions] = useState([]);
  const [plan, setPlan] = useState(null);
  const [planDate, setPlanDate] = useState(today());
  const [loading, setLoading] = useState(true);
  const [notice, setNotice] = useState("");
  const [error, setError] = useState("");

  const loadDashboard = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      const [summaryData, corridorData, segmentData, suggestionData] = await Promise.all([
        api("/api/dashboard/summary"),
        api("/api/dashboard/corridors"),
        api("/api/segments"),
        api("/api/suggestions?status=pending"),
      ]);
      setSummary(summaryData);
      setCorridors(corridorData);
      setSegments(segmentData);
      setSuggestions(suggestionData);
    } catch (err) {
      setError(`${err.message}. Confirm PostgreSQL and FastAPI are running.`);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    loadDashboard();
  }, [loadDashboard]);

  const approve = async (suggestionId) => {
    setNotice("");
    setError("");
    try {
      await api(`/api/suggestions/${suggestionId}/approve`, {
        method: "PATCH",
        body: JSON.stringify({ approved_by: "dashboard.operator" }),
      });
      setNotice(`Suggestion #${suggestionId} was approved and converted into a schedule.`);
      await loadDashboard();
    } catch (err) {
      setError(err.message);
    }
  };

  const generatePlan = async () => {
    setNotice("");
    setError("");
    try {
      const result = await api(`/api/plans/${planDate}/generate`, { method: "POST" });
      setPlan(result);
      setNotice(`The complete ${planDate} plan was generated for every active segment.`);
    } catch (err) {
      setError(err.message);
    }
  };

  const criticalSegments = useMemo(
    () => segments.filter((item) => Number(item.unfit_percent) >= 25 || Number(item.imbalance_ratio) >= 1.5),
    [segments],
  );

  return (
    <div className="app-shell">
      <header className="topbar">
        <div className="brand-mark">LS</div>
        <div className="brand-copy">
          <h1>LaneShift BD</h1>
          <p>Dynamic road-space control · Dhaka</p>
        </div>
        <div className="system-status"><span /> PostgreSQL decision engine</div>
      </header>

      <nav className="tabs" aria-label="Dashboard sections">
        {[
          ["overview", "Operations overview"],
          ["suggestions", `Suggestions (${suggestions.length})`],
          ["plan", "Daily plan"],
        ].map(([key, label]) => (
          <button key={key} className={tab === key ? "active" : ""} onClick={() => setTab(key)}>
            {label}
          </button>
        ))}
        <button className="refresh" onClick={loadDashboard}>Refresh data</button>
      </nav>

      <main>
        {notice && <div className="notice success">{notice}</div>}
        {error && <div className="notice error">{error}</div>}
        {loading ? <div className="loading">Reading live PostgreSQL views…</div> : null}

        {!loading && tab === "overview" && (
          <>
            <section className="section-heading">
              <div><p className="eyebrow">CURRENT NETWORK</p><h2>Traffic operations overview</h2></div>
              <p>Database-calculated status from the most recent sensor hour.</p>
            </section>
            <section className="stats-grid">
              <StatCard label="Active segments" value={summary.active_segments ?? 0} note="All included in today’s plan" />
              <StatCard label="Pending decisions" value={summary.pending_suggestions ?? 0} note="Require operator approval" tone="amber" />
              <StatCard label="Active reallocations" value={summary.active_reallocations ?? 0} note="Protected from schedule overlap" tone="blue" />
              <StatCard label="Average unfit share" value={`${number(summary.average_unfit_percent)}%`} note="ANPR × fitness registry" tone="red" />
            </section>

            <section className="panel">
              <div className="panel-title"><div><p className="eyebrow">CORRIDORS</p><h3>Network pressure</h3></div></div>
              <div className="corridor-grid">
                {corridors.map((corridor) => (
                  <article className="corridor-card" key={corridor.corridor_id}>
                    <div className="corridor-title"><h4>{corridor.corridor_name}</h4><Badge tone="green">{corridor.active_segments} segments</Badge></div>
                    <div className="metric-row"><span>Average speed</span><strong>{number(corridor.average_speed_kph)} km/h</strong></div>
                    <div className="metric-row"><span>Worst imbalance</span><strong>{number(corridor.worst_imbalance, 2)}×</strong></div>
                    <div className="meter"><i style={{ width: `${Math.min(Number(corridor.worst_imbalance) * 30, 100)}%` }} /></div>
                    <p>Highest pressure: <b>{corridor.worst_segment}</b></p>
                  </article>
                ))}
              </div>
            </section>

            <section className="panel">
              <div className="panel-title"><div><p className="eyebrow">ATTENTION</p><h3>Segments requiring action</h3></div><Badge tone="amber">{criticalSegments.length} flagged</Badge></div>
              <div className="table-wrap">
                <table>
                  <thead><tr><th>Segment</th><th>Latest volume</th><th>Average speed</th><th>Imbalance</th><th>Unfit share</th><th>Lane split</th></tr></thead>
                  <tbody>
                    {criticalSegments.map((segment) => (
                      <tr key={segment.segment_id}>
                        <td><b>{segment.segment_code}</b><small>{segment.segment_name}</small></td>
                        <td>{segment.inbound_vehicle_count} in / {segment.outbound_vehicle_count} out</td>
                        <td>{number((Number(segment.avg_inbound_speed_kph) + Number(segment.avg_outbound_speed_kph)) / 2)} km/h</td>
                        <td><Badge tone={Number(segment.imbalance_ratio) >= 1.5 ? "amber" : "neutral"}>{number(segment.imbalance_ratio, 2)}×</Badge></td>
                        <td><Badge tone={Number(segment.unfit_percent) >= 25 ? "red" : "neutral"}>{number(segment.unfit_percent)}%</Badge></td>
                        <td>{segment.current_inbound_lanes} in · {segment.current_outbound_lanes} out</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </section>
          </>
        )}

        {!loading && tab === "suggestions" && (
          <section className="panel standalone">
            <div className="panel-title"><div><p className="eyebrow">OPERATOR QUEUE</p><h2>Pending lane suggestions</h2></div><Badge tone="amber">Approval required</Badge></div>
            {suggestions.length === 0 ? <Empty>No pending suggestions.</Empty> : (
              <div className="suggestion-list">
                {suggestions.map((item) => (
                  <article className="suggestion" key={item.suggestion_id}>
                    <div className="suggestion-main">
                      <div className="suggestion-title"><Badge tone="neutral">#{item.suggestion_id}</Badge><h3>{item.segment_name}</h3><span>{item.corridor_name}</span></div>
                      <p>{item.reason}</p>
                      <div className="suggestion-metrics">
                        <span><small>Imbalance</small><b>{number(item.measured_imbalance_ratio, 2)}×</b></span>
                        <span><small>Unfit vehicles</small><b>{number(item.unfit_percent)}%</b></span>
                        <span><small>Recommended split</small><b>{item.recommended_inbound_lanes} inbound / {item.recommended_outbound_lanes} outbound</b></span>
                      </div>
                    </div>
                    <button className="primary" onClick={() => approve(item.suggestion_id)}>Approve & schedule</button>
                  </article>
                ))}
              </div>
            )}
          </section>
        )}

        {!loading && tab === "plan" && (
          <section className="panel standalone">
            <div className="panel-title plan-title">
              <div><p className="eyebrow">NIGHTLY PROCEDURE</p><h2>Daily reallocation plan</h2></div>
              <div className="plan-controls"><input type="date" value={planDate} onChange={(event) => setPlanDate(event.target.value)} /><button className="primary" onClick={generatePlan}>Generate complete plan</button></div>
            </div>
            {!plan ? <Empty>Select a date and run the PostgreSQL cursor procedure.</Empty> : (
              <>
                <div className="plan-summary"><Badge tone="green">{plan.status}</Badge><span>{plan.items.length} active segments covered</span><span>Generated {new Date(plan.generated_at).toLocaleString()}</span></div>
                <div className="table-wrap">
                  <table>
                    <thead><tr><th>Segment</th><th>Action</th><th>Recommended lanes</th><th>Unfit share</th><th>Enforcement team</th></tr></thead>
                    <tbody>{plan.items.map((item) => (
                      <tr key={item.plan_item_id}>
                        <td><b>{item.segment_code}</b><small>{item.segment_name}</small></td>
                        <td><Badge tone={item.action.includes("enforce") ? "red" : item.action === "monitor" ? "neutral" : "blue"}>{item.action.replaceAll("_", " ")}</Badge></td>
                        <td>{item.recommended_inbound_lanes} inbound / {item.recommended_outbound_lanes} outbound</td>
                        <td>{number(item.unfit_percent)}%</td>
                        <td>{item.enforcement_team || "—"}</td>
                      </tr>
                    ))}</tbody>
                  </table>
                </div>
              </>
            )}
          </section>
        )}
      </main>
      <footer>LaneShift BD · PostgreSQL makes the decision; the interface keeps operators in control.</footer>
    </div>
  );
}

export default App;

