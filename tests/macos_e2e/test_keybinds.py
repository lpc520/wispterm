import time
import pytest


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
