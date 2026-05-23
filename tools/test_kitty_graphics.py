#!/usr/bin/env python3
import io
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from kitty_graphics import emit_png


class KittyGraphicsEmitTests(unittest.TestCase):
    def test_default_moves_cursor_by_omitting_no_move_flag(self):
        out = io.StringIO()

        emit_png(b"png", cols=4, rows=2, stream=out)

        control = out.getvalue().split(";", 1)[0]
        self.assertIn("a=T", control)
        self.assertIn("c=4", control)
        self.assertIn("r=2", control)
        self.assertNotIn("C=1", control)

    def test_no_move_cursor_sets_kitty_no_move_flag(self):
        out = io.StringIO()

        emit_png(b"png", move_cursor=False, stream=out)

        control = out.getvalue().split(";", 1)[0]
        self.assertIn("C=1", control)


if __name__ == "__main__":
    unittest.main()
