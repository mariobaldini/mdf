#!/usr/bin/env python3
"""Check syscall clocks, descriptor lifetimes, waits and native correlation."""
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('mdf_trace',ROOT/'tools/scripts/profile-trace.py')
trace=importlib.util.module_from_spec(spec)
spec.loader.exec_module(trace)


def call(name,args,result='0',at=100,duration=1,tid=10):
    return {'call':name,'arguments':args,'result':result,'epoch_ns':at,'duration_ns':duration,'tid':tid,'stack':[]}


class TraceTests(unittest.TestCase):
    def test_per_thread_timestamps_durations_and_stacks(self):
        with tempfile.TemporaryDirectory() as directory:
            p=Path(directory)/'syscalls.42'
            p.write_text('1792378804.822124 pselect6(12, [11<UNIX-STREAM:[11->12]>], NULL, NULL, NULL, NULL) = 1 (in [11]) <0.014483>\n'
                         ' > /usr/lib64/libc.so.6(pselect+0x23) [0x123]\n')
            records,details=trace.parse_files([p])
        self.assertEqual(records[0]['tid'],42)
        self.assertEqual(records[0]['epoch_ns'],1792378804822124000)
        self.assertEqual(records[0]['duration_ns'],14483000)
        self.assertEqual(len(records[0]['stack']),1)
        self.assertEqual(details['parsed_calls'],1)

    def test_unfinished_resumed_and_incomplete_shutdown(self):
        with tempfile.TemporaryDirectory() as directory:
            p=Path(directory)/'syscalls.9'
            p.write_text('100.000000 futex(0x1234, FUTEX_WAIT_PRIVATE, 2, NULL <unfinished ...>\n'
                         '100.003000 <... futex resumed>) = 0 <0.003000>\n'
                         '100.004000 futex(0x1234, FUTEX_WAIT_PRIVATE, 2, NULL) = ?\n')
            records,details=trace.parse_files([p])
        self.assertEqual(len(records),1)
        self.assertEqual(records[0]['duration_ns'],3000000)
        self.assertEqual(details['incomplete_calls'],1)

    def test_changed_futex_value_did_not_block(self):
        records=[call('futex','0xabcd, FUTEX_WAIT_PRIVATE, 2, NULL','-1 EAGAIN (Resource temporarily unavailable)')]
        trace.annotate(records,None)
        self.assertEqual(records[0]['kind'],'work')
        self.assertIn('did not sleep',records[0]['description'])

    def test_successful_futex_wake_is_only_candidate_evidence(self):
        records=[call('futex','0xabcd, FUTEX_WAIT_PRIVATE, 2, NULL',duration=50),
                 call('futex','0xabcd, FUTEX_WAKE_PRIVATE, 1','1',at=120,tid=11),
                 call('futex','0xeeee, FUTEX_WAKE_PRIVATE, 1','1',at=125,tid=12)]
        trace.annotate(records,None)
        self.assertEqual(records[0]['kind'],'wait')
        self.assertEqual(len(records[0]['related']),1)
        self.assertIn('candidate waker',records[0]['description'])

    def test_poll_zero_timeout_is_work(self):
        records=[call('poll','[{fd=11, events=POLLIN}], 1, 0','0 (Timeout)')]
        trace.annotate(records,None)
        self.assertEqual(records[0]['kind'],'work')

    def test_select_reports_ready_wayland_not_every_watched_fd(self):
        records=[call('socket','AF_UNIX, SOCK_STREAM, 0','11',at=1),
                 call('connect','11, {sa_family=AF_UNIX, sun_path="/run/user/1000/wayland-0"}, 42',at=3),
                 call('pselect6','12, [3<pipe:[123]> 11<UNIX-STREAM:[456->789]>], [], [], {tv_sec=30, tv_nsec=0}, NULL',
                      '1 (in [11])',at=10,duration=50)]
        trace.annotate(records,11)
        self.assertEqual(records[-1]['kind'],'wait')
        self.assertIn('Wait for Wayland compositor socket',records[-1]['label'])
        self.assertNotIn('pipe',records[-1]['label'])
        self.assertIn('456->789',records[-1]['fd_labels'][11])

    def test_descriptor_reuse_and_raw_hex_read(self):
        records=[call('openat','AT_FDCWD, "/tmp/first", O_RDONLY','3',at=1),
                 call('read','0x3, 0xabcd, 0x1000','0x1000',at=3),
                 call('close','3','0',at=5),
                 call('openat','AT_FDCWD, "/tmp/second", O_RDONLY','3',at=7),
                 call('read','0x3, 0xabcd, 0x1000','0x1000',at=9)]
        trace.annotate(records,None)
        self.assertEqual(records[1]['descriptor'],'/tmp/first')
        self.assertEqual(records[-1]['descriptor'],'/tmp/second')

    def test_pipe_ends_share_identity(self):
        records=[call('pipe2','[3<pipe:[99]>, 4<pipe:[99]>], O_CLOEXEC','0',at=1),
                 call('read','0x3, 0x123, 0x8','0x8',at=3),
                 call('write','0x4, 0xabc, 0x8','0x8',at=5)]
        trace.annotate(records,None)
        self.assertEqual(records[1]['descriptor'],records[2]['descriptor'])

    def test_file_mapping_is_not_claimed_as_complete_disk_latency(self):
        records=[call('mmap','NULL, 4096, PROT_READ, MAP_PRIVATE, 3</tmp/document>, 0','0x1234')]
        trace.annotate(records,None)
        self.assertEqual(records[0]['descriptor'],'/tmp/document')
        self.assertIn('page-fault delays can occur later',records[0]['description'])

    def test_native_and_syscall_times_share_one_launch_and_split_at_scope(self):
        native={'profile_version':1,'main_started_ns':1_005_000_000,'process_id':10,
                'metrics':{'first_frame_ms':20},'events':[{'name':'GUI','track':'gui','kind':'work','thread_id':10,
                  'start_ns':5_000_000,'duration_ns':10_000_000,'depth':0,'source':'main.cpp','line':1}]}
        records=[call('read','0x3, 0x123, 0x8','0x8',at=2_008_000_000,duration=8_000_000)]
        trace.annotate(records,None)
        run,_,_=trace.correlate(native,records,1_000_000_000,1_000_000_000,1_030_000_000)
        observed=[e for e in run['events'] if e.get('syscall')]
        self.assertEqual([(e['start_ns'],e['duration_ns']) for e in observed],[(8_000_000,2_000_000),(10_000_000,6_000_000)])
        self.assertEqual(sum(e['duration_ns'] for e in observed),8_000_000)
        self.assertIsNotNone(observed[1]['parent'])
        self.assertEqual(run['metrics']['first_frame_ms'],25)
        self.assertTrue(all('syscall' not in e for e in run['self_spans']))

    def test_no_environment_or_payload_capture_in_default_command(self):
        self.assertNotIn('execve',trace.SYSCALLS.split(','))
        self.assertTrue(set(trace.PAYLOAD.split(',')) <= set(trace.SYSCALLS.split(',')))


if __name__=='__main__':unittest.main()
