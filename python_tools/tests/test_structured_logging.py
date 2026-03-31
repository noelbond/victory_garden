import json
from datetime import datetime, timezone

from watering.structured_logging import log_event


def test_log_event_writes_json_line(capsys):
    log_event(
        "controller",
        "decision_evaluated",
        zone_id="zone1",
        when=datetime(2026, 3, 31, 18, 0, tzinfo=timezone.utc),
        values={"runtime_seconds": 45},
    )

    captured = capsys.readouterr()
    payload = json.loads(captured.out.strip())

    assert payload["component"] == "controller"
    assert payload["event"] == "decision_evaluated"
    assert payload["zone_id"] == "zone1"
    assert payload["when"] == "2026-03-31T18:00:00+00:00"
    assert payload["values"]["runtime_seconds"] == 45
    assert payload["level"] == "info"
    assert "timestamp" in payload
