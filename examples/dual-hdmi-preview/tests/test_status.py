"""Hardware-independent monitoring tests; run with unittest discover."""
import importlib.util
import io
from pathlib import Path
import queue
import sys
import types
import unittest
from unittest.mock import Mock, patch

# Monitoring logic can be tested on hosts without GStreamer or Raspberry Pi.
gi = types.ModuleType('gi')
gi.require_version = lambda *args: None
repository = types.ModuleType('gi.repository')
repository.GLib = Mock()
repository.Gst = Mock()
path = Path(__file__).resolve().parents[1] / 'dual_preview.py'
spec = importlib.util.spec_from_file_location('preview_status_test', path)
preview = importlib.util.module_from_spec(spec)
with patch.dict(sys.modules, {'gi': gi, 'gi.repository': repository}):
    spec.loader.exec_module(preview)


class StatusTests(unittest.TestCase):
    def stats(self):
        with patch.object(preview.time, 'monotonic', return_value=0):
            return preview.CameraStats('Link A', 'auto')

    def test_fps_and_stall_recovery(self):
        stats = self.stats()
        process = Mock()
        process.poll.return_value = None
        for frame in range(1, 31):
            stats.frame(frame / 30)
        self.assertIn('RX 30.0/30 fps', stats.label(process, 1))
        self.assertEqual(stats.gaps, 0)
        self.assertIn('STALL', stats.label(process, 3))
        stats.frame(3.1)
        self.assertEqual(stats.gaps, 1)
        self.assertAlmostEqual(stats.last_gap_ms, 2100)
        self.assertIn('RUN', stats.label(process, 3.2))

    def test_wait_eof_and_process_exit(self):
        stats = self.stats()
        process = Mock()
        process.poll.return_value = None
        self.assertIn('WAIT', stats.label(process, 1))
        stats.eof = True
        self.assertIn('EOF', stats.label(process, 2))
        process.poll.return_value = 1
        self.assertIn('EXIT 1', stats.label(process, 3))

    def test_log_monitor_tees_and_counts(self):
        stats = self.stats()
        raw = (b'INFO Selected sensor format: 4608x2592-SBGGR10_1X10/RAW\n'
               b'WARN frame delayed\nERROR capture failed\n')
        process = types.SimpleNamespace(stderr=io.BytesIO(raw))
        output = io.StringIO()
        with patch.object(preview.sys, 'stderr', output):
            preview.read_camera_log(process, stats)
        self.assertEqual((stats.errors, stats.warnings), (1, 1))
        self.assertEqual(stats.sensor, '4608x2592-SBGGR10_1X10/RAW')
        self.assertIn('[Link A] ERROR capture failed', output.getvalue())

    def test_full_queue_eof_does_not_block_and_skip_counts(self):
        stats = self.stats()
        frames = queue.Queue(maxsize=2)
        process = types.SimpleNamespace(stdout=io.BytesIO(b'aaaabbbbcccc'))
        with patch.object(preview, 'FRAME_SIZE', 4):
            preview.feed(process, frames, stats)
        self.assertTrue(stats.eof)
        self.assertEqual(stats.frames, 3)
        self.assertEqual(stats.skipped, 1)
        self.assertEqual(preview.latest_frame(frames, stats), b'cccc')
        self.assertEqual(stats.skipped, 2)
        self.assertEqual(stats.errors, 0)

    def test_truncated_frame_is_not_delivered(self):
        stats = self.stats()
        frames = queue.Queue()
        process = types.SimpleNamespace(stdout=io.BytesIO(b'aaaabb'))
        with patch.object(preview, 'FRAME_SIZE', 4):
            preview.feed(process, frames, stats)
        self.assertEqual(stats.frames, 1)
        self.assertEqual(stats.errors, 1)
        self.assertEqual(frames.get_nowait(), b'aaaa')
        self.assertTrue(frames.empty())

    def test_ina_timeout_becomes_status_text(self):
        with patch.object(preview.subprocess, 'run', side_effect=preview.subprocess.TimeoutExpired('i2ctransfer', .5)):
            self.assertIn('INA226 read error', preview.ina_label('Link A', '0x41'))

    def test_capture_defaults_and_monitored_focus(self):
        with patch.object(preview.subprocess, 'Popen') as popen:
            preview.capture(0)
            self.assertIsNone(popen.call_args.kwargs['stderr'])
            preview.capture(1, 'auto', monitor=True)
            self.assertEqual(popen.call_args.kwargs['stderr'], preview.subprocess.PIPE)
            self.assertEqual(popen.call_args.args[0][-2:], ['--autofocus-mode', 'continuous'])


if __name__ == '__main__':
    unittest.main()
