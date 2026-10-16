#!/usr/bin/env python3
"""Regression checks for the first-viewport boundary in font syscall audits."""
import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('font_access',Path(__file__).with_name('font_access.py'))
font_access=importlib.util.module_from_spec(spec);spec.loader.exec_module(font_access)
BASE='\n'.join(['1 memfd_create("mdf-font", MFD_CLOEXEC) = '+str(i+4) for i in range(2)]+[
    '1 openat(AT_FDCWD, "/proc/self/fd/4", O_RDONLY) = 8'])+'\n'
DEFERRED='1 prctl(PR_SET_NAME, "mdf-viewport") = 0\n2 prctl(PR_SET_NAME, "mdf-monospace") = 0\n'

class AuditTests(unittest.TestCase):
    def test_no_code_reads_only_embedded_fonts(self):
        font_access.audit(BASE,False)
    def test_system_reads_allowed_only_after_viewport_on_worker(self):
        font_access.audit(BASE+DEFERRED+'2 openat(AT_FDCWD, "/etc/fonts/fonts.conf", O_RDONLY) = 9\n')
    def test_system_reads_before_viewport_are_rejected(self):
        with self.assertRaises(AssertionError):
            font_access.audit(BASE+'2 openat(AT_FDCWD, "/etc/fonts/fonts.conf", O_RDONLY) = 9\n'+DEFERRED)
    def test_gui_cannot_read_system_fonts_after_viewport(self):
        with self.assertRaises(AssertionError):
            font_access.audit(BASE+DEFERRED+'1 openat(AT_FDCWD, "/usr/share/fonts/mono.ttf", O_RDONLY) = 9\n')
    def test_worker_cannot_write_persistent_font_caches(self):
        with self.assertRaises(AssertionError):
            font_access.audit(BASE+DEFERRED+'2 openat(AT_FDCWD, "/home/u/.cache/fontconfig/a.cache", O_WRONLY|O_CREAT) = 9\n')
    def test_independent_sans_and_mono_workers_are_allowed(self):
        font_access.audit(BASE+DEFERRED+'3 prctl(PR_SET_NAME, "mdf-fallback") = 0\n'
                          '2 openat(AT_FDCWD, "/etc/fonts/fonts.conf", O_RDONLY) = 9\n'
                          '3 openat(AT_FDCWD, "/usr/share/fonts/sans.ttf", O_RDONLY) = 10\n')
    def test_sans_worker_cannot_start_before_viewport(self):
        with self.assertRaises(AssertionError):
            font_access.audit(BASE+'3 prctl(PR_SET_NAME, "mdf-fallback") = 0\n'+DEFERRED)

if __name__=='__main__':unittest.main()
