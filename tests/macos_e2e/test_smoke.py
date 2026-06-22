import pytest


@pytest.mark.e2e
def test_echo_roundtrip(app, pane):
    app.text("echo hello-e2e\n")          # real keyboard events through full input path
    app.wait_for(pane, "hello-e2e", timeout=8)   # assert via control channel
