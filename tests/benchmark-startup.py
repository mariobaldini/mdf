#!/usr/bin/env python3
"""Performance selection must reject tail regressions and timer-only gains."""
import importlib.util
from pathlib import Path
import unittest

root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('benchmark_startup', root/'scripts/benchmark-startup.py')
benchmark = importlib.util.module_from_spec(spec); spec.loader.exec_module(benchmark)


def fixture():
    return [{'document': 'SAMPLE.md', 'batch': i//10+1,
             'before': {'first_document_ms': 100+i, 'scaffold_ms': 90+i,
                        'first_document_commit_ms': 99+i, 'first_frame_ms': 200+i},
             'after': {'first_document_ms': 70+i, 'scaffold_ms': 60+i,
                       'first_document_commit_ms': 69+i, 'first_frame_ms': 170+i}}
            for i in range(20)]


class Selection(unittest.TestCase):
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
