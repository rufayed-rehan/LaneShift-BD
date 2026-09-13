from __future__ import annotations

from fastapi.testclient import TestClient

from backend.app.main import app


client = TestClient(app)


def test_root_describes_the_digital_twin_api() -> None:
    response = client.get("/")

    assert response.status_code == 200
    assert response.json()["version"] == "2.0.0"
    assert "Digital Twin" in response.json()["name"]


def test_invalid_simulation_seed_is_rejected_before_database_access() -> None:
    response = client.post(
        "/api/simulation/runs",
        json={"scenario_code": "morning_peak", "segment_id": 1, "seed": 0},
    )

    assert response.status_code == 422


def test_scenario_endpoint_uses_the_service(monkeypatch) -> None:
    expected = [
        {
            "scenario_id": 2,
            "scenario_code": "morning_peak",
            "name": "Morning inbound surge",
        }
    ]
    monkeypatch.setattr(
        "backend.app.main.simulation_service.list_scenarios",
        lambda: expected,
    )

    response = client.get("/api/simulation/scenarios")

    assert response.status_code == 200
    assert response.json() == expected
