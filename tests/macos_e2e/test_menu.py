import time
import pytest
from tests.macos_e2e.conftest import macos_only


@pytest.mark.e2e
@macos_only
def test_edit_copy_enabled_tracks_selection(app, pane):
    # With no selection, Edit > Copy is disabled.
    assert app.menu_item_state("Edit", "Copy").enabled is False
    # After typing + Select All, it becomes enabled.
    app.text("xyz")
    app.wait_for(pane, "xyz", timeout=8)
    app.key("a", "cmd")
    time.sleep(0.3)
    assert app.menu_item_state("Edit", "Copy").enabled is True
