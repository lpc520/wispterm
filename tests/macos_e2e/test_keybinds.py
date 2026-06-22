import time
import pytest

# Blocked: a test-launched WispTerm instance does not act on synthetic keyboard
# events (they reach -keyDown: but never drive the PTY/keybinding). See issue
# #279. Kept (skipped) so the intended real-input coverage is ready to re-enable
# once the app processes synthetic input under automation.
pytestmark = pytest.mark.skip(
    reason="blocked by #279: app does not process synthetic keyboard actions in a test-launched instance"
)


@pytest.mark.e2e
def test_cmd_c_copies_selection(app, pane):
    marker = "copy-me-e2e"
    app.text(marker)
    app.wait_for(pane, marker, timeout=8)
    app.key("a", "cmd")                   # Select All
    time.sleep(0.2)
    app.key("c", "cmd")                   # Copy
    time.sleep(0.2)
    assert marker in app.read_clipboard()
