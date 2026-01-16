import pytest
from src.handler import handle_event


def test_handle_before_transition():
    event = {
        "event_type": "before_transition",
        "organization_id": "org-123",
        "project_id": "proj-456"
    }
    response = handle_event(event)
    assert response["status"] in ["allow", "deny", "pending_approval"]


def test_handle_after_transition():
    event = {
        "event_type": "after_transition",
        "organization_id": "org-123",
        "project_id": "proj-456"
    }
    response = handle_event(event)
    assert response["status"] == "allow"
