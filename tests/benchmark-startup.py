#!/usr/bin/env python3
"""Performance selection must reject tail regressions and timer-only gains."""
import importlib.util
import errno
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('benchmark_startup', root/'tools/scripts/benchmark-startup.py')
benchmark = importlib.util.module_from_spec(spec); spec.loader.exec_module(benchmark)


def fixture():
    return [{'document': 'SAMPLE.md', 'batch': i//10+1,
             'before': {'first_document_ms': 100+i, 'scaffold_ms': 90+i,
                        'first_document_commit_ms': 99+i, 'first_frame_ms': 200+i},
             'after': {'first_document_ms': 70+i, 'scaffold_ms': 60+i,
                       'first_document_commit_ms': 69+i, 'first_frame_ms': 170+i}}
            for i in range(20)]


class Selection(unittest.TestCase):
    @unittest.skipUnless(sys.platform.startswith('linux'),'Linux executable inode locking')
    def test_staging_preserves_a_running_executable_and_replaces_the_next_launch(self):
        with tempfile.TemporaryDirectory(prefix='mdf-stage-') as temporary:
            path=Path(temporary)/'mdf'
            benchmark.stage_executable(path,Path(shutil.which('sleep')).read_bytes())
            running=subprocess.Popen([str(path),'30'])
            try:
                with self.assertRaises(OSError) as failure:
                    path.write_bytes(b'cannot overwrite a running ELF')
                self.assertEqual(failure.exception.errno,errno.ETXTBSY)
                benchmark.stage_executable(path,Path(shutil.which('true')).read_bytes())
                self.assertIsNone(running.poll())
                self.assertEqual(subprocess.run([str(path)],timeout=5).returncode,0)
                self.assertFalse(path.with_name('mdf.next').exists())
            finally:
                running.terminate();running.wait(timeout=5)

    def test_optimized_native_and_reference_profiles_are_accepted(self):
        benchmark.optimized_profile({'mode':'ReleaseFast','ui_mode':'ReleaseFast','gui':'native Zig / Wayland','dropped_events':0})
        benchmark.optimized_profile({'mode':'ReleaseFast','ui_mode':'Release','gui':'FLTK 1.4.5','dropped_events':0})
        for bad in ({'mode':'Debug','ui_mode':'Debug'},{'mode':'ReleaseFast','ui_mode':'Debug'},
                    {'mode':'ReleaseFast','ui_mode':'ReleaseFast','gui':'FLTK 1.4.5'},
                    {'mode':'ReleaseFast','ui_mode':'ReleaseFast','dropped_events':1}):
            with self.assertRaises(RuntimeError):benchmark.optimized_profile(bad)

    def test_estimate_uses_the_shared_student_t_margin(self):
        samples=[1,3,8,9]
        mean,margin=benchmark.estimate(samples)
        expected=benchmark.profile.timing_stats(samples)
        self.assertEqual(mean,expected['mean_ms'])
        self.assertEqual(margin,expected['margin_95_ms'])
    def test_power_preference_and_limits_must_stay_constant(self):
        initial={'cpu_affinity':[0,1], 'cpu_governors':['performance'],
                 'cpu_power':{'energy_preference':'performance','max_freq':5200000},
                 'load_average':[1,1,1]}
        benchmark.check_conditions(initial,{**initial,'load_average':[2,2,2]})
        for changed in ({'energy_preference':'balance_power','max_freq':5200000},
                        {'energy_preference':'performance','max_freq':2000000}):
            with self.assertRaisesRegex(RuntimeError,'power settings changed'):
                benchmark.check_conditions(initial,{**initial,'cpu_power':changed})

    def test_consistent_savings_pass(self):
        self.assertEqual(benchmark.assess(fixture())['status'], 'retained')

    def test_compressed_policy_reports_optional_work_separately(self):
        rows = fixture()
        for row in rows:
            row['after']['first_frame_ms'] = row['before']['first_frame_ms']+50
        self.assertEqual(benchmark.assess(rows, 'compressed')['status'], 'retained')
        self.assertEqual(benchmark.assess(rows)['status'], 'rejected')
        rows[-1]['after']['first_document_ms'] = 1000
        rows[-2]['after']['first_document_ms'] = 900
        self.assertEqual(benchmark.assess(rows, 'compressed')['status'], 'rejected')

    def test_every_batch_must_improve(self):
        rows = fixture()
        for row in rows[10:]: row['after']['first_document_ms'] = row['before']['first_document_ms']+1
        self.assertEqual(benchmark.assess(rows)['status'], 'rejected')

    def test_viewport_and_readiness_tails_are_independent_gates(self):
        for key in ('first_document_ms', 'first_frame_ms'):
            rows = fixture()
            rows[-1]['after'][key] = 1000; rows[-2]['after'][key] = 900
            self.assertEqual(benchmark.assess(rows)['status'], 'rejected')

    def test_changing_only_the_callback_timestamp_is_not_an_improvement(self):
        rows = fixture()
        for row in rows: row['after']['first_document_commit_ms'] = row['before']['first_document_commit_ms']
        self.assertEqual(benchmark.assess(rows)['status'], 'rejected')

    def test_small_paired_effect_requires_more_samples(self):
        rows = fixture()
        for i,row in enumerate(rows):
            row['after']['first_document_ms'] = 100+(i//10)*10+(9-i%10)-1
            row['after']['first_document_commit_ms'] = row['after']['first_document_ms']-1
        self.assertEqual(benchmark.assess(rows)['status'], 'inconclusive')


if __name__ == '__main__': unittest.main()
