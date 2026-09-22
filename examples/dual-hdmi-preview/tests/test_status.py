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


class GmslTests(unittest.TestCase):
    def setUp(self):
        self.stats = [preview.CameraStats('Link B'), preview.CameraStats('Link A')]
        self.monitor = preview.GmslMonitor(self.stats)
        self.registers = {0x160: 3, 0x161: 0x20, 0x474: 9, 0x4b4: 15,
                          0x442: 0, 0x482: 0, 0x22: 0, 0x23: 0}
        self.monitor.read = lambda reg: self.registers[reg]

    def test_baseline_and_independent_totals(self):
        self.registers[0x442] = 0x3c  # Historical flags must not count.
        self.monitor.sample()
        self.assertEqual(self.monitor.totals['Link A']['crc'], 0)
        self.registers[0x442] = 0x20
        self.registers[0x482] = 0x1c
        self.registers[0x22] = 3
        self.monitor.sample()
        self.assertEqual(self.monitor.totals['Link A'],
                         dict(crc=1, corr=0, uncorr=0, sync=0, dec=3))
        self.assertEqual(self.monitor.totals['Link B'],
                         dict(crc=0, corr=1, uncorr=1, sync=1, dec=0))
        self.registers.update({0x442: 0, 0x482: 0, 0x22: 0})
        self.monitor.sample()
        self.assertEqual(self.monitor.totals['Link A']['crc'], 1)

    def test_unsupported_mapping_does_not_consume_status(self):
        self.registers[0x161] = 0x32
        reads = []
        def read(reg):
            reads.append(reg)
            return self.registers[reg]
        self.monitor.read = read
        with self.assertRaisesRegex(RuntimeError, 'routing'):
            self.monitor.sample()
        self.assertNotIn(0x442, reads)
        self.assertNotIn(0x482, reads)

    def test_partial_failure_preserves_consumed_flag(self):
        self.monitor.sample()
        def read(reg):
            if reg == 0x482:
                return 0x20
            if reg == 0x23:
                raise OSError('I2C failed')
            return self.registers[reg]
        self.monitor.read = read
        with self.assertRaises(OSError):
            self.monitor.sample()
        self.assertEqual(self.monitor.totals['Link B']['crc'], 1)

    def test_i2c_transfer_uses_register_pointer_only(self):
        with patch.object(preview.subprocess, 'run', return_value=Mock(stdout='0x20\n')) as run:
            self.assertEqual(preview.read_des_u8(11, 0x28, 0x442), 0x20)
            self.assertEqual(run.call_args.args[0],
                             ['i2ctransfer', '-f', '-y', '11', 'w2@0x28', '0x04', '0x42', 'r1'])

    def test_failed_read_displays_unavailable(self):
        self.monitor.read = Mock(side_effect=OSError('bus unavailable'))
        stop = Mock()
        stop.is_set.side_effect = [False, True]
        with patch.object(preview.sys, 'stderr', io.StringIO()):
            self.monitor.poll(stop)
        for observer in self.stats:
            self.assertIn('unavailable/stale', observer.hardware)


if __name__ == '__main__':
    unittest.main()
