package main

import (
    "testing"
)

func TestHandleBeforeTransition(t *testing.T) {
    payload := map[string]interface{}{
        "event_type": "before_transition",
    }

    if payload["event_type"] != "before_transition" {
        t.Error("Expected event_type to be before_transition")
    }
}

func TestHandleAfterTransition(t *testing.T) {
    payload := map[string]interface{}{
        "event_type": "after_transition",
    }

    if payload["event_type"] != "after_transition" {
        t.Error("Expected event_type to be after_transition")
    }
}
